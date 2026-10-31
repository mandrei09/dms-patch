import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// `rg text` searches file contents under the configured roots (default
// ~/Work) with ripgrep and lists matches; Enter opens VS Code at the line.
// `rg /regex/` switches from literal to regex. Case is smart (lowercase query
// = case-insensitive). ripgrep honours .gitignore, so bin/obj/node_modules
// and friends are skipped without a list of our own.
//
// Searches run asynchronously, debounced, and a newer query kills the older
// run; the launcher is told to refresh when results land.
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
    property string trigger: "rg"

    signal itemsChanged

    readonly property string pluginId: "rgSearch"
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property int maxResults: 60

    // Plugin setting "roots": list of directories; "~" is expanded.
    property var roots: [home + "/Work"]

    property string _pendingQuery: ""
    property string _runningQuery: ""
    property string _doneQuery: "\u0000"
    property var _results: []
    property string _error: ""

    Component.onCompleted: {
        if (pluginService) {
            trigger = pluginService.loadPluginData(pluginId, "trigger", "rg");
            const r = pluginService.loadPluginData(pluginId, "roots", null);
            if (Array.isArray(r) && r.length > 0)
                roots = r.map(p => String(p).replace(/^~(?=\/|$)/, home));
        }
    }

    Timer {
        id: debounce
        interval: 220
        onTriggered: root._start(root._pendingQuery)
    }

    Process {
        id: rg
        stdout: StdioCollector {
            onStreamFinished: root._finish(this.text)
        }
    }

    function _start(q) {
        if (rg.running)
            rg.running = false;
        const isRegex = q.length > 2 && q.startsWith("/") && q.endsWith("/");
        const pattern = isRegex ? q.slice(1, -1) : q;
        // Query and roots go in as positional parameters, never spliced into
        // the script, so nothing typed is interpreted by the shell. head caps
        // the volume; rg's own -m caps matches per file.
        // DMS's environment has no Homebrew on PATH, so look the binary up
        // explicitly; VS Code's bundled copy is the last resort.
        const script = 'q="$1"; mode="$2"; shift 2; RG=; for c in /usr/bin/rg /home/linuxbrew/.linuxbrew/bin/rg /usr/share/code/resources/app/node_modules.asar.unpacked/@vscode/ripgrep-universal/bin/linux-x64/rg; do [ -x "$c" ] && RG=$c && break; done; [ -n "$RG" ] || exit 0; "$RG" --vimgrep --smart-case $mode --max-columns 300 --max-columns-preview --max-count 4 --max-filesize 2M --no-messages -e "$q" -- "$@" | head -n ' + maxResults;
        rg.command = ["sh", "-c", script, "sh", pattern, isRegex ? "--engine=default" : "--fixed-strings"].concat(roots);
        _runningQuery = q;
        rg.running = true;
    }

    function _finish(text) {
        const rows = [];
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/^(.*?):(\d+):(\d+):(.*)$/);
            if (m)
                rows.push({ path: m[1], line: +m[2], col: +m[3], text: m[4] });
        }
        _results = rows;
        _doneQuery = _runningQuery;
        if (pluginService)
            pluginService.requestLauncherUpdate(pluginId);
    }

    function _rel(p) {
        for (const r of roots) {
            if (p.startsWith(r + "/")) {
                const base = r.substring(r.lastIndexOf("/") + 1);
                return base + "/" + p.substring(r.length + 1);
            }
        }
        return home && p.startsWith(home) ? "~" + p.substring(home.length) : p;
    }

    function _hint(name, comment, icon) {
        return [{ name: name, comment: comment, icon: "material:" + icon, action: "none", _preScored: 1000, categories: ["Search in Files"] }];
    }

    function getItems(query) {
        const q = (query || "").trim();
        if (q.length < 3)
            return _hint("Type at least 3 characters", "Searches " + roots.map(_rel).join(", ") + " · /regex/ for a pattern", "manage_search");

        if (q !== _doneQuery) {
            if (q !== _pendingQuery || (!debounce.running && !rg.running) || _runningQuery !== q) {
                _pendingQuery = q;
                debounce.restart();
            }
            return _hint("Searching for “" + q + "”…", roots.map(_rel).join(", "), "hourglass_empty");
        }

        if (_results.length === 0)
            return _hint("No matches for “" + q + "”", "In " + roots.map(_rel).join(", ") + " (.gitignored files skipped)", "search_off");

        return _results.map((r, i) => ({
                    // Rows don't elide, so a long line wraps into its
                    // neighbours; keep the snippet to one visual line.
                    name: _snippet(r.text, r.col),
                    icon: "material:description",
                    comment: _rel(r.path) + ":" + r.line,
                    action: "open",
                    enterLabel: "Open in VS Code at line " + r.line,
                    _path: r.path,
                    _line: r.line,
                    _col: r.col,
                    _text: r.text,
                    _preScored: 1000 - i,
                    categories: ["Search in Files"]
                }));
    }

    // Up to ~56 chars (one row line), windowed around the match so it stays visible.
    function _snippet(text, col) {
        const t = text.replace(/\t/g, " ");
        const lead = t.length - t.replace(/^\s+/, "").length;
        let start = Math.max(lead, col - 1 - 16);
        let out = t.substring(start, start + 56).replace(/\s+/g, " ").trim();
        if (start > lead)
            out = "…" + out;
        if (start + 56 < t.replace(/\s+$/, "").length)
            out += "…";
        return out || "(blank line)";
    }

    function executeItem(item) {
        if (item?.action !== "open")
            return;
        Quickshell.execDetached(root.scoped(["code", "--goto", item._path + ":" + item._line + ":" + item._col]));
    }

    function _copy(text, what) {
        Quickshell.execDetached(["dms", "cl", "copy", text]);
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("Search in Files", "Copied " + what);
    }

    function getContextMenuActions(item) {
        if (item?.action !== "open")
            return [];
        const dir = item._path.substring(0, item._path.lastIndexOf("/"));
        return [
            {
                icon: "folder_open",
                text: "Open containing folder",
                closeLauncher: true,
                action: () => Quickshell.execDetached(root.scoped(["xdg-open", dir]))
            },
            {
                icon: "content_copy",
                text: "Copy path:line",
                closeLauncher: true,
                action: () => root._copy(item._path + ":" + item._line, "path")
            },
            {
                icon: "format_quote",
                text: "Copy matching line",
                closeLauncher: true,
                action: () => root._copy(item._text.trim(), "line")
            }
        ];
    }
}
