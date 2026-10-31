import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Workspace presets: `wp` lists them, Enter lays one out across workspaces.
//
// All the window work happens in wp.py next to this file (also usable from a
// terminal: `wp.py apply Shelves`); presets are edited in
// ~/.config/dms/workspace-presets.json.
Item {
    id: root

    // Run a launched app in its own transient systemd scope. A bare execDetached
    // leaves it in dms.service's cgroup, so restarting DMS kills it.
    function scoped(argv) {
        return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--"].concat(argv);
    }

    property var pluginService: null
    property string trigger: "wp"

    signal itemsChanged

    readonly property string helper: Qt.resolvedUrl("wp.py").toString().replace(/^file:\/\//, "")
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string configFile: home + "/.config/dms/workspace-presets.json"

    property var presets: []
    property real _loadedAt: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData("workspacePresets", "trigger", "wp");
        reload.running = true;
    }

    Process {
        id: reload
        command: ["/usr/bin/python3", root.helper, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.presets = JSON.parse(this.text);
                } catch (e) {
                    console.warn("workspacePresets: bad helper output:", e);
                    return;
                }
                root._loadedAt = Date.now();
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate("workspacePresets");
            }
        }
    }

    function _appNames(ws) {
        return (ws.apps || []).map(a => a.name || a.cmd[0]);
    }

    function _details(p) {
        const rows = [];
        for (const ws of p.workspaces || []) {
            rows.push({
                section: "Workspace " + ws.id + (ws.group ? " · grouped" : "")
            });
            for (const a of ws.apps || [])
                rows.push({
                    label: a.name || a.cmd[0],
                    value: a.cmd.join(" "),
                    mono: true
                });
        }
        rows.push({
            section: "Config"
        });
        rows.push({
            label: "File",
            value: "~/.config/dms/workspace-presets.json",
            mono: true
        });
        return rows;
    }

    function getItems(query) {
        // Pick up edits to the JSON whenever the list is opened afresh.
        if (Date.now() - _loadedAt > 3000 && !reload.running)
            reload.running = true;

        const words = (query || "").toLowerCase().split(/\s+/).filter(w => w.length > 0);
        const items = [];
        for (const p of presets) {
            const summary = (p.workspaces || []).map(ws => ws.id + ": " + _appNames(ws).join(ws.group ? " + " : ", ")).join("   ");
            const hay = (p.name + " " + (p.description || "") + " " + summary).toLowerCase();
            if (!words.every(w => hay.includes(w)))
                continue;
            items.push({
                name: p.name,
                icon: "material:" + (p.error ? "error" : (p.icon || "view_quilt")),
                comment: p.error ? p.error : summary,
                action: p.error ? "none" : "apply",
                enterLabel: "Lay out " + p.name,
                details: p.error ? [] : _details(p),
                _preset: p.name,
                _preScored: 1000 - items.length,
                categories: ["Workspace Presets"]
            });
        }
        if (items.length === 0)
            items.push({
                name: words.length ? "No preset matches “" + query.trim() + "”" : "No presets configured",
                icon: "material:search_off",
                comment: "Edit ~/.config/dms/workspace-presets.json",
                action: "edit",
                _preScored: 1,
                categories: ["Workspace Presets"]
            });
        return items;
    }

    function getContextMenuActions(item) {
        return [
            {
                icon: "edit",
                text: "Edit presets file",
                closeLauncher: true,
                action: () => Quickshell.execDetached(root.scoped(["code", root.configFile]))
            }
        ];
    }

    function executeItem(item) {
        if (!item)
            return;
        if (item.action === "apply" && item._preset)
            Quickshell.execDetached(root.scoped(["/usr/bin/python3", root.helper, "apply", item._preset]));
        else if (item.action === "edit")
            Quickshell.execDetached(root.scoped(["code", root.configFile]));
    }
}
