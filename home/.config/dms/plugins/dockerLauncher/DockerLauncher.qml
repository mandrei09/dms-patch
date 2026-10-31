import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// `dk` lists compose projects and containers (running first); `dk redis`
// filters. Enter starts what is stopped and stops what is running -- the row
// says which. Right-click / Right arrow: restart, logs, shell, copy.
//
// Compose projects act through `docker compose -p NAME ...`, which works from
// the containers' labels alone (no compose files needed) and respects
// depends_on, so "start all" brings postgres up before the services on it.
// Every action runs as its own Process so completion and failure come back as
// a toast, and the list refreshes itself afterwards.
Item {
    id: root

    // Run a launched app in its own transient systemd scope. A bare execDetached
    // leaves it in dms.service's cgroup, so restarting DMS kills it -- VS Code
    // only moves its main process out by itself, its zygote/GPU/renderer
    // children stay behind and the window dies with them.
    function scoped(argv) {
        return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--"].concat(argv);
    }

    property var pluginService: null
    property string trigger: "dk"

    signal itemsChanged

    readonly property string pluginId: "dockerLauncher"

    property var containers: []
    property var inspected: ({})    // name -> docker inspect object
    property var busy: ({})         // name -> "starting…" etc., until refreshed
    property string _error: ""
    property real _loadedAt: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData(pluginId, "trigger", "dk");
        refresh();
    }

    Process {
        id: ps
        command: ["docker", "ps", "-a", "--format", "{{json .}}"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = [];
                for (const line of this.text.split("\n")) {
                    if (!line.trim())
                        continue;
                    try {
                        const c = JSON.parse(line);
                        const proj = (c.Labels || "").match(/(?:^|,)com\.docker\.compose\.project=([^,]*)/);
                        list.push({
                            name: c.Names,
                            id: c.ID,
                            image: c.Image,
                            state: c.State,
                            status: c.Status,
                            ports: c.Ports || "",
                            project: proj ? proj[1] : ""
                        });
                    } catch (e) {}
                }
                root.containers = list;
                root._loadedAt = Date.now();
                root.busy = ({});
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
                // One inspect call for everything feeds the details pane.
                if (list.length > 0 && !inspect.running) {
                    inspect.command = ["docker", "inspect"].concat(list.map(c => c.id));
                    inspect.running = true;
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: root._error = this.text.trim()
        }
    }

    Process {
        id: inspect
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const map = {};
                    for (const c of JSON.parse(this.text))
                        map[c.Name.replace(/^\//, "")] = c;
                    root.inspected = map;
                } catch (e) {
                    return;
                }
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
            }
        }
    }

    // ── details pane ─────────────────────────────────────────────────
    readonly property string home: Quickshell.env("HOME") || ""
    // Ports that are certainly not HTTP get no link; TLS-ish ones get https.
    readonly property var _nonHttp: [21, 22, 25, 53, 1433, 1521, 2181, 3306, 4369, 5432, 5672, 6379, 6380, 9092, 9093, 11211, 25672, 27017, 29092]
    readonly property var _tls: [443, 8443, 9443]

    function _tilde(p) {
        return home && p && p.startsWith(home) ? "~" + p.substring(home.length) : p;
    }

    function _when(iso) {
        if (!iso || iso.startsWith("0001-"))
            return "";
        const t = Date.parse(iso.replace(/(\.\d{3})\d+/, "$1"));
        if (isNaN(t))
            return "";
        const d = (Date.now() - t) / 1000;
        const ago = d < 90 ? "just now" : d < 5400 ? Math.round(d / 60) + " min ago" : d < 129600 ? Math.round(d / 3600) + " h ago" : Math.round(d / 86400) + " days ago";
        const dt = new Date(t);
        const pad = n => (n < 10 ? "0" : "") + n;
        return dt.getFullYear() + "-" + pad(dt.getMonth() + 1) + "-" + pad(dt.getDate()) + " " + pad(dt.getHours()) + ":" + pad(dt.getMinutes()) + " (" + ago + ")";
    }

    function _portRows(ins, running) {
        const rows = [];
        const bindings = ins.HostConfig?.PortBindings || {};
        const exposed = Object.keys(ins.Config?.ExposedPorts || {});
        const keys = Object.keys(bindings).concat(exposed.filter(k => !(k in bindings)));
        keys.sort((a, b) => parseInt(a) - parseInt(b));
        for (const k of keys) {
            const [cport, proto] = k.split("/");
            const hosts = (bindings[k] || []).map(b => b.HostPort).filter((v, i, a) => v && a.indexOf(v) === i);
            if (hosts.length === 0) {
                rows.push({ label: k, value: "internal only (not published)" });
                continue;
            }
            for (const hp of hosts) {
                const n = parseInt(cport);
                const web = proto === "tcp" && _nonHttp.indexOf(n) === -1;
                const scheme = _tls.indexOf(n) !== -1 ? "https" : "http";
                rows.push({
                    label: k,
                    value: "localhost:" + hp + (web ? "  ↗" : ""),
                    url: web && running ? scheme + "://localhost:" + hp : "",
                    mono: true
                });
            }
        }
        return rows;
    }

    function _containerDetails(c) {
        const ins = inspected[c.name];
        const rows = [];
        if (!ins) {
            rows.push({ label: "Status", value: c.status });
            rows.push({ label: "Image", value: c.image, mono: true });
            if (c.ports)
                rows.push({ label: "Ports", value: c.ports, mono: true });
            return rows;
        }
        const st = ins.State || {};
        const running = st.Status === "running";
        rows.push({ section: "State", label: "Status", value: st.Status + (running ? "" : " (exit " + st.ExitCode + ")") });
        if (st.Health?.Status)
            rows.push({ label: "Health", value: st.Health.Status });
        if (running)
            rows.push({ label: "Started", value: _when(st.StartedAt) });
        else if (_when(st.FinishedAt))
            rows.push({ label: "Stopped", value: _when(st.FinishedAt) });
        rows.push({ label: "Restart", value: ins.HostConfig?.RestartPolicy?.Name || "no" });

        const ports = _portRows(ins, running);
        if (ports.length) {
            ports[0].section = "Ports";
            rows.push(...ports);
        }

        const nets = ins.NetworkSettings?.Networks || {};
        const netNames = Object.keys(nets);
        netNames.forEach((n, i) => rows.push({ section: i === 0 ? "Networks" : "", label: n, value: nets[n].IPAddress || (running ? "—" : "(stopped)"), mono: true, labelWidth: 190 }));

        (ins.Mounts || []).forEach((m, i) => {
            const src = m.Type === "volume" ? (m.Name || m.Source) : _tilde(m.Source);
            rows.push({
                section: i === 0 ? "Volumes" : "",
                label: m.Type + (m.RW ? "" : " (ro)"),
                value: src + " → " + m.Destination,
                url: m.Type === "bind" ? "file://" + m.Source : "",
                mono: true
            });
        });

        const labels = ins.Config?.Labels || {};
        rows.push({ section: "Container", label: "Image", value: ins.Config?.Image || c.image, mono: true });
        rows.push({ label: "ID", value: (ins.Id || "").substring(0, 12), mono: true });
        const cmd = [].concat(ins.Config?.Entrypoint || [], ins.Config?.Cmd || []).join(" ");
        if (cmd)
            rows.push({ label: "Command", value: cmd, mono: true });
        if (labels["com.docker.compose.service"])
            rows.push({ label: "Service", value: labels["com.docker.compose.service"] + " (" + labels["com.docker.compose.project"] + ")" });
        const wd = labels["com.docker.compose.project.working_dir"];
        if (wd)
            rows.push({ label: "Compose dir", value: _tilde(wd), url: "file://" + wd });
        rows.push({ label: "Env vars", value: String((ins.Config?.Env || []).length) });
        rows.push({ label: "Created", value: _when(ins.Created) });
        return rows;
    }

    function _projectDetails(name) {
        const rows = [];
        const members = containers.filter(c => c.project === name).sort((a, b) => (a.state === "running" ? 0 : 1) - (b.state === "running" ? 0 : 1) || a.name.localeCompare(b.name));
        members.forEach((c, i) => {
            const ins = inspected[c.name];
            const hp = ins ? Object.values(ins.HostConfig?.PortBindings || {}).reduce((acc, v) => acc.concat(v || []), []).map(b => b.HostPort).filter((v, j, a) => v && a.indexOf(v) === j) : [];
            const health = ins?.State?.Health?.Status;
            rows.push({
                section: i === 0 ? "Services" : "",
                label: c.name,
                value: c.state + (health ? " · " + health : "") + (hp.length ? " · :" + hp.join(", :") : ""),
                labelWidth: 150
            });
        });
        const any = members.map(c => inspected[c.name]).find(x => x);
        const wd = any?.Config?.Labels?.["com.docker.compose.project.working_dir"];
        if (wd)
            rows.push({ section: "Project", label: "Compose dir", value: _tilde(wd), url: "file://" + wd });
        const files = any?.Config?.Labels?.["com.docker.compose.project.config_files"];
        if (files)
            rows.push({ label: "Files", value: files.split(",").map(f => f.substring(f.lastIndexOf("/") + 1)).join(", ") });
        return rows;
    }

    function refresh() {
        if (!ps.running)
            ps.running = true;
    }

    // One-shot runner per action: completion drives a toast and a refresh.
    Component {
        id: runnerComp
        Process {
            id: runner
            property string label: ""
            stderr: StdioCollector {
                id: errOut
            }
            onExited: code => {
                if (typeof ToastService !== "undefined") {
                    if (code === 0)
                        ToastService.showInfo("Docker", runner.label + " — done");
                    else
                        ToastService.showError("Docker", runner.label + " failed: " + errOut.text.trim().split("\n").pop());
                }
                root.refresh();
                runner.destroy();
            }
        }
    }

    function _run(args, label, busyKeys, busyText) {
        const b = Object.assign({}, busy);
        for (const k of busyKeys)
            b[k] = busyText;
        busy = b;
        const p = runnerComp.createObject(root, {
            command: args,
            label: label
        });
        p.running = true;
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("Docker", label + "…");
        if (pluginService)
            pluginService.requestLauncherUpdate(pluginId);
    }

    function _terminal(args) {
        Quickshell.execDetached(root.scoped(["xdg-terminal-exec"].concat(args)));
    }

    function _projects() {
        const map = {};
        for (const c of containers) {
            if (!c.project)
                continue;
            const p = map[c.project] || (map[c.project] = { name: c.project, total: 0, running: 0 });
            p.total++;
            if (c.state === "running")
                p.running++;
        }
        return Object.values(map).sort((a, b) => a.name.localeCompare(b.name));
    }

    readonly property var _stateIcon: ({
            "running": "play_circle",
            "exited": "stop_circle",
            "paused": "pause_circle",
            "restarting": "autorenew",
            "created": "radio_button_unchecked",
            "dead": "error"
        })

    function getItems(query) {
        if (Date.now() - _loadedAt > 2000)
            refresh();

        if (_error && containers.length === 0)
            return [{ name: "Docker is not reachable", comment: _error, icon: "material:error", action: "none", _preScored: 1000, categories: ["Docker"] }];

        const words = (query || "").toLowerCase().split(/\s+/).filter(w => w);
        const match = s => words.every(w => s.toLowerCase().includes(w));
        const items = [];

        for (const p of _projects()) {
            if (!match(p.name + " compose project"))
                continue;
            const allUp = p.running === p.total;
            const b = busy["project:" + p.name];
            items.push({
                name: p.name + " — " + (allUp ? "stop all" : "start all"),
                icon: "material:" + (allUp ? "stop" : "play_arrow"),
                comment: b ? b : "Compose project · " + p.running + "/" + p.total + " running · Enter: " + (allUp ? "stop" : "start") + " all",
                action: allUp ? "project-stop" : "project-start",
                _project: p.name,
                details: _projectDetails(p.name),
                _preScored: 1000 - items.length,
                categories: ["Docker"]
            });
        }

        const sorted = containers.slice().sort((a, b) => (a.state === "running" ? 0 : 1) - (b.state === "running" ? 0 : 1) || a.name.localeCompare(b.name));
        for (const c of sorted) {
            if (!match(c.name + " " + c.image + " " + c.project))
                continue;
            const up = c.state === "running";
            const b = busy[c.name];
            items.push({
                name: c.name,
                icon: "material:" + (_stateIcon[c.state] || "deployed_code"),
                comment: b ? b : c.status + (c.project ? " · " + c.project : "") + " · " + c.image + " · Enter: " + (up ? "stop" : "start"),
                action: up ? "stop" : "start",
                _name: c.name,
                details: _containerDetails(c),
                _id: c.id,
                _up: up,
                _project: c.project,
                _preScored: 1000 - items.length,
                categories: ["Docker"]
            });
        }

        if (items.length === 0)
            items.push({ name: containers.length ? "No container matches" : "No containers", comment: "docker ps -a", icon: "material:search_off", action: "none", _preScored: 1, categories: ["Docker"] });
        return items;
    }

    function executeItem(item) {
        switch (item?.action) {
        case "start":
            _run(["docker", "start", item._name], "Starting " + item._name, [item._name], "starting…");
            break;
        case "stop":
            _run(["docker", "stop", item._name], "Stopping " + item._name, [item._name], "stopping…");
            break;
        case "project-start":
            _run(["docker", "compose", "-p", item._project, "start"], "Starting " + item._project, ["project:" + item._project], "starting all…");
            break;
        case "project-stop":
            _run(["docker", "compose", "-p", item._project, "stop"], "Stopping " + item._project, ["project:" + item._project], "stopping all…");
            break;
        }
    }

    function _copy(text) {
        Quickshell.execDetached(["dms", "cl", "copy", text]);
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("Docker", "Copied " + text);
    }

    function getContextMenuActions(item) {
        if (!item)
            return [];
        if (item._project && item.action && item.action.startsWith("project-")) {
            const p = item._project;
            return [
                { icon: "play_arrow", text: "Start all", closeLauncher: false, action: () => root._run(["docker", "compose", "-p", p, "start"], "Starting " + p, ["project:" + p], "starting all…") },
                { icon: "stop", text: "Stop all", closeLauncher: false, action: () => root._run(["docker", "compose", "-p", p, "stop"], "Stopping " + p, ["project:" + p], "stopping all…") },
                { icon: "restart_alt", text: "Restart all", closeLauncher: false, action: () => root._run(["docker", "compose", "-p", p, "restart"], "Restarting " + p, ["project:" + p], "restarting all…") },
                { icon: "article", text: "Follow logs (all services)", closeLauncher: true, action: () => root._terminal(["docker", "compose", "-p", p, "logs", "-f", "--tail", "100"]) }
            ];
        }
        if (!item._name)
            return [];
        const n = item._name;
        const acts = [];
        if (item._up) {
            acts.push({ icon: "restart_alt", text: "Restart", closeLauncher: false, action: () => root._run(["docker", "restart", n], "Restarting " + n, [n], "restarting…") });
            acts.push({ icon: "terminal", text: "Open shell", closeLauncher: true, action: () => root._terminal(["docker", "exec", "-it", n, "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]) });
        }
        acts.push({ icon: "article", text: "Follow logs", closeLauncher: true, action: () => root._terminal(["docker", "logs", "-f", "--tail", "200", n]) });
        acts.push({ icon: "content_copy", text: "Copy name", closeLauncher: true, action: () => root._copy(n) });
        acts.push({ icon: "tag", text: "Copy ID", closeLauncher: true, action: () => root._copy(item._id) });
        return acts;
    }
}
