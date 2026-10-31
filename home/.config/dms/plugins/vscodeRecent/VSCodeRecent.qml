import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Recently used VS Code folders, newest first: `vs` lists them, `vs shel back`
// filters (every word must match the name, path, host or profile).
//
// Data comes from recent.py next to this file -- see its docstring for why
// the registry vscodeLauncher (storage.json menubar data) finds nothing here.
// Opening a folder URI lets VS Code apply the profile associated with it.
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
    property string trigger: "vs"

    signal itemsChanged

    readonly property string helper: Qt.resolvedUrl("recent.py").toString().replace(/^file:\/\//, "")
    readonly property string home: Quickshell.env("HOME") || ""

    property var entries: []
    property real _loadedAt: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData("vscodeRecent", "trigger", "vs");
        reload.running = true;
    }

    Process {
        id: reload
        command: ["/usr/bin/python3", root.helper]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.entries = JSON.parse(this.text);
                } catch (e) {
                    console.warn("vscodeRecent: bad helper output:", e);
                    return;
                }
                root._loadedAt = Date.now();
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate("vscodeRecent");
            }
        }
    }

    function _ago(sec) {
        const d = Date.now() / 1000 - sec;
        if (d < 90)
            return "just now";
        if (d < 5400)
            return Math.round(d / 60) + " min ago";
        if (d < 129600)
            return Math.round(d / 3600) + " h ago";
        if (d < 86400 * 60)
            return Math.round(d / 86400) + " days ago";
        return Math.round(d / (86400 * 30.4)) + " months ago";
    }

    function _tilde(p) {
        return home && p.startsWith(home) ? "~" + p.substring(home.length) : p;
    }

    function getItems(query) {
        // Cheap enough to refresh whenever the list is opened afresh.
        if (Date.now() - _loadedAt > 3000 && !reload.running)
            reload.running = true;

        const words = (query || "").toLowerCase().split(/\s+/).filter(w => w.length > 0);
        const items = [];
        for (let i = 0; i < entries.length; i++) {
            const e = entries[i];
            const parent = e.path.replace(/\/[^/]*\/?$/, "");
            const parentName = parent.substring(parent.lastIndexOf("/") + 1);
            const hay = (e.path + " " + e.remote + " " + e.profile).toLowerCase();
            if (!words.every(w => hay.includes(w)))
                continue;
            const where = e.remote ? e.remote + " · " + e.path : _tilde(parent);
            items.push({
                name: !e.remote && e.path === home ? "~ (home)" : (parentName ? parentName + "/" : "") + e.name,
                icon: "material:" + (e.remote ? "cloud" : e.kind === "workspace" ? "workspaces" : "folder_open"),
                comment: where + (e.profile ? " · " + e.profile : "") + " · " + _ago(e.mtime),
                action: "open",
                enterLabel: "Open in VS Code" + (e.profile ? " (" + e.profile + " profile)" : ""),
                _uri: e.uri,
                _kind: e.kind,
                _preScored: 1000 - items.length,
                categories: ["VS Code Recent"]
            });
        }
        if (words.length === 0) {
            items.push({
                name: "New VS Code window",
                icon: "material:add",
                comment: "Default profile",
                action: "new",
                enterLabel: "Open a new VS Code window",
                _preScored: 1,
                categories: ["VS Code Recent"]
            });
        } else if (items.length === 0) {
            items.push({
                name: "No recent folder matches “" + query.trim() + "”",
                icon: "material:search_off",
                comment: "Matches against name, path, host and profile",
                action: "none",
                _preScored: 1,
                categories: ["VS Code Recent"]
            });
        }
        return items;
    }

    function executeItem(item) {
        if (!item)
            return;
        if (item.action === "new")
            Quickshell.execDetached(root.scoped(["code", "--new-window"]));
        else if (item.action === "open" && item._uri)
            Quickshell.execDetached(root.scoped(["code", item._kind === "workspace" ? "--file-uri" : "--folder-uri", item._uri]));
    }
}
