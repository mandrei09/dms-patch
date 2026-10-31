import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// `ssh` lists the hosts from ~/.ssh/config, most recently used first;
// `ssh prod` filters; `ssh user@box` offers to connect to anything not in the
// config. Enter opens a terminal via xdg-terminal-exec (-> Ghostty new window);
// right-click / Right arrow for VS Code Remote-SSH and copy actions.
//
// Replaces the registry sshConnections plugin, which kept its own host list in
// plugin settings instead of reading ~/.ssh/config.
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
    property string trigger: "ssh"

    signal itemsChanged

    readonly property string pluginId: "sshHosts"
    readonly property string helper: Qt.resolvedUrl("hosts.py").toString().replace(/^file:\/\//, "")

    property var hosts: []
    property var recent: []
    property real _loadedAt: 0

    Component.onCompleted: {
        if (pluginService) {
            trigger = pluginService.loadPluginData(pluginId, "trigger", "ssh");
            recent = pluginService.loadPluginData(pluginId, "recent", []) || [];
        }
        reload.running = true;
    }

    Process {
        id: reload
        command: ["/usr/bin/python3", root.helper]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.hosts = JSON.parse(this.text).filter(h => !h.forge);
                } catch (e) {
                    console.warn("sshHosts: bad helper output:", e);
                    return;
                }
                root._loadedAt = Date.now();
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
            }
        }
    }

    function _describe(h) {
        const target = (h.user ? h.user + "@" : "") + h.hostname + (h.port && h.port !== "22" ? ":" + h.port : "");
        return target === h.alias ? "" : target;
    }

    function getItems(query) {
        if (Date.now() - _loadedAt > 5000 && !reload.running)
            reload.running = true;

        const q = (query || "").trim();
        const words = q.toLowerCase().split(/\s+/).filter(w => w);
        const rank = a => {
            const i = recent.indexOf(a);
            return i === -1 ? 1000 : i;
        };
        const sorted = hosts.slice().sort((a, b) => rank(a.alias) - rank(b.alias));

        const items = [];
        for (const h of sorted) {
            const hay = (h.alias + " " + h.hostname + " " + h.user).toLowerCase();
            if (!words.every(w => hay.includes(w)))
                continue;
            const desc = _describe(h);
            items.push({
                name: h.alias,
                icon: "material:dns",
                comment: (desc ? desc + " · " : "") + (recent.indexOf(h.alias) === 0 ? "last used" : "from ~/.ssh/config"),
                action: "ssh",
                enterLabel: "Open an SSH session in a terminal",
                _target: h.alias,
                _preScored: 1000 - items.length,
                categories: ["SSH Hosts"]
            });
        }

        // Something typed that isn't a configured host: offer it verbatim if it
        // looks like [user@]host[:port]. ssh itself parses it; no shell involved.
        if (q && !hosts.some(h => h.alias === q) && /^([\w.-]+@)?[\w.-]+(:\d+)?$/.test(q)) {
            const m = q.match(/^(.*?)(?::(\d+))?$/);
            items.push({
                name: "Connect to " + q,
                icon: "material:login",
                comment: "Not in ~/.ssh/config",
                action: "ssh",
                enterLabel: "Open an SSH session in a terminal",
                _target: m[1],
                _port: m[2] || "",
                _preScored: 1000 - items.length,
                categories: ["SSH Hosts"]
            });
        }

        if (items.length === 0)
            items.push({
                name: hosts.length ? "No host matches “" + q + "”" : "No hosts in ~/.ssh/config",
                icon: "material:search_off",
                comment: "Type user@host to connect anyway",
                action: "none",
                _preScored: 1,
                categories: ["SSH Hosts"]
            });
        return items;
    }

    function _remember(target) {
        const r = [target].concat(recent.filter(a => a !== target)).slice(0, 20);
        recent = r;
        if (pluginService)
            pluginService.savePluginData(pluginId, "recent", r);
    }

    function _sshArgs(item) {
        const args = ["ssh"];
        if (item._port)
            args.push("-p", item._port);
        args.push(item._target);
        return args;
    }

    function executeItem(item) {
        if (item?.action !== "ssh" || !item._target)
            return;
        _remember(item._target);
        Quickshell.execDetached(root.scoped(["xdg-terminal-exec"].concat(_sshArgs(item))));
    }

    function _copy(text) {
        Quickshell.execDetached(["dms", "cl", "copy", text]);
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("SSH Hosts", "Copied " + text);
    }

    function getContextMenuActions(item) {
        if (item?.action !== "ssh" || !item._target)
            return [];
        return [
            {
                icon: "code",
                text: "Open in VS Code (Remote-SSH)",
                closeLauncher: true,
                action: () => {
                    root._remember(item._target);
                    Quickshell.execDetached(root.scoped(["code", "--remote", "ssh-remote+" + item._target]));
                }
            },
            {
                icon: "content_copy",
                text: "Copy ssh command",
                closeLauncher: true,
                action: () => root._copy(root._sshArgs(item).join(" "))
            }
        ];
    }
}
