pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets

// Right-hand details pane for the DMS spotlight launcher.
//
// Every result type renders through ONE sheet: a header (icon + name), then
// rows built by a per-type function. Rows are plain objects:
//   { section: "Title" }                         section heading
//   { label, value, url?, mono?, labelWidth? }   key/value line; url -> link
//   { text, format?: "plain"|"html"|"markdown", mono? }   full-width block
//   { image: "file:///..." }                     full-width picture
// A row may combine `section` with any of the others. Plugins supply their own
// rows as `details` on the item; files, apps, clipboard entries and everything
// else get rows built here. Links: http(s)/file open externally and close the
// launcher; "dms:preview" opens the GNOME Sushi previewer on the file.
//
// Slow facts come from helpers run asynchronously and debounced, discarding
// stale answers: ~/.local/bin/dms-file-details (size, mtime, excerpt),
// ~/.local/bin/dms-app-details (source, windows, memory), `dms cl get`
// (full clipboard text).
//
// Source: ~/.local/share/dms-launcher-patch/LauncherDetailsPane.qml, copied
// into the DMS_SHELL_DIR tree by ~/.local/bin/dms-launcher-patch on every
// DMS start (via dms-shell-sync) -- edit the source, not the copy.
Rectangle {
    id: root

    // The currently selected launcher item, of any type.
    property var item: null

    // Asks the launcher to close (after opening a link or the previewer).
    signal requestClose

    readonly property var _data: item?.data ?? null
    readonly property string _type: item?.type ?? ""

    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.35)
    radius: Theme.cornerRadius
    border.color: Theme.outlineLight
    border.width: Theme.layerOutlineWidth
    clip: true

    // ── the one row list the sheet renders ───────────────────────────
    readonly property var rows: {
        if (!item)
            return [{ text: "Arrow through results to see details here.", format: "plain" }];
        if (Array.isArray(_data?.details) && _data.details.length > 0)
            return _data.details;
        switch (_type) {
        case "file":
            return _fileRows();
        case "app":
            return item.isCore ? _genericRows() : _appRows();
        case "clipboard":
            return _clipRows();
        case "plugin_browse":
            return _browseRows();
        default:
            return _genericRows();
        }
    }

    // ── shared helpers ───────────────────────────────────────────────
    function _esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function _ago(ms) {
        const d = (Date.now() - ms) / 1000;
        if (d < 90)
            return "just now";
        if (d < 5400)
            return Math.round(d / 60) + " min ago";
        if (d < 129600)
            return Math.round(d / 3600) + " h ago";
        return Math.round(d / 86400) + " days ago";
    }

    function _tilde(p) {
        const h = Quickshell.env("HOME") || "";
        return h && p && p.startsWith(h) ? "~" + p.substring(h.length) : p;
    }

    function humanSize(bytes) {
        const b = Number(bytes);
        if (!isFinite(b))
            return "";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let v = b;
        let i = 0;
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024;
            i++;
        }
        return (i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i];
    }

    // Names of the extra actions a result offers (right-click / Right arrow).
    function _moreActions() {
        const names = (item?.actions || []).map(a => a.name).filter(n => n);
        if (_type === "plugin" && item.pluginId) {
            const inst = PluginService.pluginInstances[item.pluginId];
            if (inst && typeof inst.getContextMenuActions === "function") {
                try {
                    const acts = inst.getContextMenuActions(_data) || [];
                    for (const a of acts)
                        if (a.text || a.name)
                            names.push(a.text || a.name);
                } catch (e) {}
            }
        }
        return names;
    }

    // ══ files ════════════════════════════════════════════════════════
    readonly property bool isFileItem: _type === "file"
    readonly property string path: isFileItem ? String(_data?.path ?? "") : ""
    readonly property bool isDir: isFileItem && !!_data?.is_dir
    readonly property bool isImage: mimeText.startsWith("image/")
    // `file --mime-type` reports .md as text/plain, so the extension is the
    // only reliable signal for markdown.
    readonly property bool isMarkdown: {
        const p = root.path.toLowerCase();
        return p.endsWith(".md") || p.endsWith(".markdown") || root.mimeText === "text/markdown";
    }

    property bool fileLoaded: false
    property string sizeText: ""
    property string mtimeText: ""
    property string permText: ""
    property string kindText: ""
    property string mimeText: ""
    property string entriesText: ""
    property string headText: ""
    property string thumbPath: ""
    property string pagesText: ""
    // Folders: disk usage is measured separately (du can take seconds on a
    // big tree) so the rest of the sheet does not wait for it.
    property string duText: ""
    property string gitBranch: ""
    property string gitRemote: ""
    property bool headIsHtml: false
    // "code" | "markdown" from dms-file-details (PREVIEW=): both arrive as
    // Dark Modern RichText from ~/.local/share/dms-launcher-patch/highlight.py.
    property string previewMode: ""
    property string _wantPath: ""

    // The excerpt is always VS Code Dark Modern (highlight.py), matching the
    // spacebar previewer, so it sits in an editor-coloured box whatever the
    // shell theme is. Non-empty = ask the helper for highlighted HTML.
    readonly property string pygmentsStyle: "darkmodern"
    readonly property color editorBg: "#1f1f1f"
    readonly property color editorBorder: "#2b2b2b"
    readonly property color editorFg: "#cccccc"

    onPathChanged: reloadFile()
    onPygmentsStyleChanged: reloadFile()
    Component.onCompleted: reloadFile()

    // Hand the file to GNOME Sushi -- the same previewer Nautilus opens on
    // spacebar, and the same call the launcher's "Preview" action makes.
    function openFullPreview() {
        if (!path)
            return;
        Quickshell.execDetached({
            "command": ["gdbus", "call", "--session", "--dest", "org.gnome.NautilusPreviewer", "--object-path", "/org/gnome/NautilusPreviewer", "--method", "org.gnome.NautilusPreviewer2.ShowFile", "file://" + path, "", "true", ""]
        });
        requestClose();
    }

    function reloadFile() {
        fileLoaded = false;
        sizeText = "";
        mtimeText = "";
        permText = "";
        kindText = "";
        mimeText = "";
        entriesText = "";
        headText = "";
        headIsHtml = false;
        previewMode = "";
        thumbPath = "";
        pagesText = "";
        duText = "";
        gitBranch = "";
        gitRemote = "";

        if (!path) {
            _wantPath = "";
            return;
        }

        _wantPath = path;
        const want = path;
        Proc.runCommand("launcher-details-pane", ["dms-file-details", want, root.pygmentsStyle], function (stdout, exitCode) {
            // A newer selection may have landed while this was in flight.
            if (root._wantPath !== want)
                return;

            const lines = String(stdout || "").split("\n");
            const head = [];
            let inHead = false;

            for (let i = 0; i < lines.length; i++) {
                const ln = lines[i];
                if (inHead) {
                    head.push(ln);
                    continue;
                }
                if (ln === "HEAD<<" || ln === "HTML<<") {
                    inHead = true;
                    root.headIsHtml = (ln === "HTML<<");
                    continue;
                }
                const eq = ln.indexOf("=");
                if (eq <= 0)
                    continue;
                const k = ln.substring(0, eq);
                const v = ln.substring(eq + 1);
                if (k === "SIZE")
                    root.sizeText = root.humanSize(v);
                else if (k === "MTIME")
                    root.mtimeText = Qt.formatDateTime(new Date(Number(v) * 1000), "yyyy-MM-dd hh:mm");
                else if (k === "PERM")
                    root.permText = v;
                else if (k === "KIND")
                    root.kindText = v;
                else if (k === "MIME")
                    root.mimeText = v;
                else if (k === "THUMB")
                    root.thumbPath = v;
                else if (k === "PREVIEW")
                    root.previewMode = v;
                else if (k === "PAGES")
                    root.pagesText = v === "1" ? "1 page" : v + " pages";
                else if (k === "ENTRIES")
                    root.entriesText = v.trim() + " items";
                else if (k === "GITBRANCH")
                    root.gitBranch = v;
                else if (k === "GITREMOTE")
                    root.gitRemote = v;
            }
            root.headText = head.join("\n").replace(/\s+$/, "");
            root.fileLoaded = true;
            // Started from here rather than up front: when the selection
            // changes, onPathChanged fires before `isDir` re-evaluates, so
            // checking isDir there saw the PREVIOUS item's value.
            if (root.kindText === "directory")
                root.measureDir(want);
        }, 120, 3000);
    }

    function measureDir(want) {
        duText = "Calculating…";
        Proc.runCommand("launcher-details-du", ["du", "-sk", "--", want], function (stdout, exitCode) {
            if (root._wantPath !== want)
                return;
            const kib = parseInt(String(stdout || "").split("\t")[0]);
            root.duText = isNaN(kib) ? "Unavailable" : root.humanSize(kib * 1024) + (exitCode !== 0 ? " (some folders unreadable)" : "");
        }, 1, 20000);
    }

    function _fileRows() {
        const r = [];
        const dir = path.substring(0, path.lastIndexOf("/")) || "/";
        r.push({ section: isDir ? "Folder" : "File", label: "Location", value: _tilde(dir), url: "file://" + dir, mono: true, labelWidth: 70 });
        if (!fileLoaded) {
            r.push({ label: "", value: "Loading…" });
            return r;
        }
        // Everything short goes in a two-column grid (label above value), so
        // the facts take two or three lines and the preview gets the room.
        const g = [];
        if (isDir ? entriesText : sizeText)
            g.push({ label: isDir ? "Contains" : "Size", value: isDir ? entriesText : sizeText });
        if (mtimeText)
            g.push({ label: "Modified", value: mtimeText });
        if (duText)
            g.push({ label: "Disk usage", value: duText });
        if (pagesText)
            g.push({ label: "Pages", value: pagesText });
        if (mimeText)
            g.push({ label: "Type", value: mimeText, mono: true });
        if (permText)
            g.push({ label: "Access", value: permText, mono: true });
        // "regular file" / "directory" just repeat the chip; say anything else.
        if (kindText && kindText !== "regular file" && kindText !== "directory")
            g.push({ label: "Kind", value: kindText });
        if (g.length)
            r.push({ grid: g });
        if (gitBranch || gitRemote) {
            r.push({ section: "Git" });
            if (gitBranch)
                r.push({ label: "Branch", value: gitBranch, mono: true, labelWidth: 70 });
            if (gitRemote)
                r.push({ label: "Remote", value: gitRemote, mono: true, labelWidth: 70 });
        }

        if (isImage)
            r.push({ section: "Preview", image: "file://" + path });
        else if (thumbPath)
            r.push({ section: "Preview", image: "file://" + thumbPath });
        if (headText) {
            const html = headIsHtml;
            r.push({
                section: isImage ? "" : "Preview",
                text: headText,
                format: html ? "html" : "plain",
                // Editor-styled box (Dark Modern), monospace unless it is a
                // rendered markdown document.
                editor: true,
                mono: !(html && previewMode === "markdown")
            });
        }
        if (!isDir && !(isImage || thumbPath || headText))
            r.push({ section: "Preview", label: "", value: "Open full preview", url: "dms:preview" });
        return r;
    }

    // ══ apps: DesktopEntry fields + dms-app-details ══════════════════
    readonly property bool isAppItem: _type === "app" && !item?.isCore && !!_data
    readonly property string _appId: isAppItem ? String(_data.id || "") : ""
    property var appExtra: null
    property string _wantApp: ""

    on_AppIdChanged: reloadApp()

    function reloadApp() {
        appExtra = null;
        _wantApp = _appId;
        if (!_appId)
            return;
        const want = _appId;
        Proc.runCommand("launcher-app-details", ["dms-app-details", want, String(_data.startupClass || ""), String(_data.execString || "")], function (stdout) {
            if (root._wantApp !== want)
                return;
            try {
                root.appExtra = JSON.parse(String(stdout || "{}"));
            } catch (e) {
                root.appExtra = {};
            }
        }, 120, 4000);
    }

    function _appRows() {
        const a = _data;
        const x = appExtra;
        const rows = [];
        const list = v => Array.isArray(v) ? v.filter(s => s).join(", ") : String(v || "");

        if (a.genericName && a.genericName !== a.name)
            rows.push({ section: "App", label: "Kind", value: a.genericName });
        if (a.comment)
            rows.push({ section: rows.length ? "" : "App", label: "About", value: a.comment });
        if (list(a.categories))
            rows.push({ section: rows.length ? "" : "App", label: "Categories", value: list(a.categories).split(/[;,]\s*/).filter(c => c).join(", ") });

        // Windows (live, from Hyprland).
        if (x === null) {
            rows.push({ section: "Running", label: "", value: "Checking…" });
        } else if ((x.windows || []).length === 0) {
            rows.push({ section: "Running", label: "Status", value: "Not running" });
        } else {
            x.windows.forEach((w, i) => rows.push({
                        section: i === 0 ? "Running · " + x.windows.length + " window" + (x.windows.length === 1 ? "" : "s") : "",
                        label: w.workspace.startsWith("special:") ? "hidden" : "ws " + w.workspace,
                        value: (w.title || "(untitled)") + (w.workspace.startsWith("special:") ? "  (" + w.workspace.substring(8) + ")" : "")
                    }));
            if (x.memory)
                rows.push({ label: "Memory", value: x.memory + (x.processes > 1 ? " across " + x.processes + " processes" : "") });
        }

        // How it launches. Field codes (%U) and flatpak's @@u ... @@
        // file-forwarding markers are plumbing, not part of what you'd type.
        const cmd = String(a.execString || (a.command || []).join(" ")).replace(/\s*@@u?(?=\s|$)/g, "").replace(/\s+%[a-zA-Z]\b/g, "").trim();
        rows.push({ section: "Launch", label: "Command", value: cmd, mono: true });
        if (a.runInTerminal)
            rows.push({ label: "Terminal", value: "runs in a terminal" });
        if (a.workingDirectory)
            rows.push({ label: "Directory", value: _tilde(a.workingDirectory), mono: true });
        const acts = (a.actions || []).map(ac => ac.name).filter(n => n);
        if (acts.length)
            rows.push({ label: "Actions", value: acts.join(", ") + "  (right-click)" });
        if (a.startupClass)
            rows.push({ label: "WM class", value: a.startupClass, mono: true });

        // Where it comes from.
        const src = x?.source;
        if (src) {
            const what = src.kind + (src.name ? " · " + src.name : "") + (src.version ? " " + src.version : "") + (src.origin ? " (" + src.origin + ")" : "");
            rows.push({ section: "Installed", label: "Source", value: what });
            if (src.size)
                rows.push({ label: "Size", value: src.size });
        }
        if (x?.desktop) {
            const dir = x.desktop.substring(0, x.desktop.lastIndexOf("/"));
            rows.push({ section: src ? "" : "Installed", label: "Desktop file", value: _tilde(x.desktop), url: "file://" + dir, mono: true });
            if (x.shadows)
                rows.push({ label: "Overrides", value: _tilde(x.shadows), mono: true });
        }
        rows.push({ label: "ID", value: a.id, mono: true });

        // Launch history, as DMS records it for ranking.
        const rank = AppUsageHistoryData.appUsageRanking || {};
        const u = rank[a.id] || rank[String(a.id).replace(/\.desktop$/, "")];
        rows.push({ section: "Usage", label: "Launched", value: u ? u.usageCount + " time" + (u.usageCount === 1 ? "" : "s") + " from the launcher" : "never from the launcher" });
        if (u?.lastUsed)
            rows.push({ label: "Last", value: _ago(u.lastUsed) });
        return rows;
    }

    // ══ clipboard entries ════════════════════════════════════════════
    readonly property string _clipId: _type === "clipboard" && !_data?.isImage ? String(_data?.id ?? "") : ""
    property string clipText: ""
    property bool clipTruncated: false
    property string _wantClip: ""
    readonly property int _clipMax: 6000

    on_ClipIdChanged: reloadClip()

    // The history keeps a short preview; `dms cl get` has the whole entry,
    // base64-encoded. Decode in the shell so UTF-8 survives.
    function reloadClip() {
        clipText = "";
        clipTruncated = false;
        _wantClip = _clipId;
        if (!_clipId)
            return;
        const want = _clipId;
        Proc.runCommand("launcher-clip-details", ["sh", "-c", "dms cl get \"$1\" | base64 -d 2>/dev/null | head -c " + (_clipMax + 1), "sh", want], function (stdout) {
            if (root._wantClip !== want)
                return;
            const t = String(stdout || "");
            root.clipTruncated = t.length > root._clipMax;
            root.clipText = root.clipTruncated ? t.substring(0, root._clipMax) : t;
        }, 120, 3000);
    }

    function _clipRows() {
        const e = _data || {};
        const r = [];
        r.push({ section: "Clipboard", label: "Type", value: (e.isImage ? "Image" : "Text") + (e.mimeType ? " · " + e.mimeType : ""), mono: false });
        if (e.size !== undefined)
            r.push({ label: "Size", value: humanSize(e.size) });
        if (e.timestamp) {
            const t = Date.parse(e.timestamp);
            if (!isNaN(t))
                r.push({ label: "Copied", value: Qt.formatDateTime(new Date(t), "yyyy-MM-dd hh:mm") + " (" + _ago(t) + ")" });
        }
        r.push({ label: "Pinned", value: e.pinned ? "yes" : "no" });
        if (item.primaryAction?.name)
            r.push({ label: "Enter", value: item.primaryAction.name });
        if (!e.isImage) {
            const body = clipText || String(e.preview || "");
            r.push({ section: "Content" + (clipTruncated ? " (first " + _clipMax + " characters)" : ""), text: body, format: "plain", mono: true });
        }
        return r;
    }

    // ══ plugin browser rows ("?" / the Plugins tab) ══════════════════
    function _browseRows() {
        const d = _data || {};
        const p = d.plugin || {};
        const r = [];
        r.push({ section: "Plugin", label: "Name", value: p.name || d.pluginId });
        if (p.description || p.comment)
            r.push({ label: "About", value: p.description || p.comment });
        r.push({ label: "Trigger", value: item.subtitle || "" });
        if (p.author)
            r.push({ label: "Author", value: p.author });
        if (p.version)
            r.push({ label: "Version", value: p.version });
        r.push({ label: "Kind", value: d.isBuiltIn ? "built into DMS" : "third-party / local plugin" });
        r.push({ label: "ID", value: d.pluginId || "", mono: true });
        return r;
    }

    // ══ everything else: plugins without details, DMS built-ins ══════
    function _genericRows() {
        const r = [];
        let kind = "Result";
        if (_type === "plugin") {
            const lp = item.pluginId ? (PluginService.getLauncherPlugin(item.pluginId) || PluginService.availablePlugins?.[item.pluginId]) : null;
            kind = (lp?.name || item.pluginId || "Plugin");
        } else if (_type === "app" && item.isCore) {
            kind = "DMS built-in";
        } else if (item.source || item.badgeLabel) {
            kind = item.source || item.badgeLabel;
        }
        r.push({ section: kind, label: "About", value: item.subtitle || "—" });
        if (_type === "plugin" && item.pluginId) {
            const trig = PluginService.getPluginTrigger(item.pluginId);
            if (trig)
                r.push({ label: "Trigger", value: trig.trim(), mono: true });
        }
        // "Select" is DMS's generic label for plugin rows; prefer the
        // plugin's own `enterLabel`, else infer "Copy" for rows carrying a
        // `_value`, else leave the line out rather than say nothing useful.
        const pa = item.primaryAction?.name || "";
        const enter = _data?.enterLabel || (pa === "Select" ? (_data?._value !== undefined ? "Copy to clipboard" : "") : pa);
        if (enter)
            r.push({ label: "Enter", value: enter });
        const more = _moreActions();
        if (more.length)
            r.push({ label: "More", value: more.join(", ") + "  (right-click)" });

        // Local plugins keep the exact thing Enter copies in `_value`; show
        // it whole (a pretty-printed JWT payload, a batch of GUIDs, ...).
        const v = _data?._value;
        if (typeof v === "string" && v.length > 0 && v !== item.name)
            r.push({ section: "Value", text: v.length > 6000 ? v.substring(0, 6000) + "\n…" : v, format: "plain", mono: true });
        return r;
    }

    // ══ the sheet ════════════════════════════════════════════════════
    // Styled after DMS's own Settings cards: a hero header, then one card
    // per section (primary icon + title, muted labels, full-contrast values).

    // Flat rows -> [{ title, rows }]. A row with a `section` opens a new
    // card; `section: ""` (or none) continues the current one.
    readonly property var groups: {
        const g = [];
        let cur = null;
        const src = item ? rows : [];
        for (let i = 0; i < src.length; i++) {
            const r = src[i];
            if (r.section || !cur) {
                cur = { title: r.section || "", rows: [] };
                g.push(cur);
            }
            if (r.label !== undefined || r.value !== undefined || r.text !== undefined || r.image || r.grid)
                cur.rows.push(r);
        }
        return g.filter(x => x.rows.length > 0);
    }

    readonly property string kindLabel: {
        if (!item)
            return "";
        if ((item.badgeLabel ?? "").length > 0)
            return item.badgeLabel;
        switch (_type) {
        case "app":
            return item.isCore ? "DMS built-in" : "Application";
        case "file":
            return isDir ? "Folder" : "File";
        case "clipboard":
            return "Clipboard";
        case "plugin_browse":
            return "Plugin";
        case "plugin": {
            const lp = item.pluginId ? (PluginService.getLauncherPlugin(item.pluginId) || PluginService.availablePlugins?.[item.pluginId]) : null;
            return lp?.name || "Plugin";
        }
        default:
            return item.source || "";
        }
    }

    function sectionIcon(title) {
        // "Running · 1 window" -> "running"
        const t = String(title || "").split(/ [·•(–-] /)[0].trim().toLowerCase();
        const map = {
            app: "apps", application: "apps", about: "info",
            running: "play_circle", state: "monitor_heart", status: "monitor_heart",
            launch: "rocket_launch", installed: "inventory_2", usage: "history",
            file: "description", folder: "folder", preview: "visibility", content: "article",
            clipboard: "content_paste", value: "data_object", plugin: "extension",
            container: "deployed_code", project: "stacks", ports: "lan", port: "lan",
            networks: "hub", network: "hub", mounts: "hard_drive", volumes: "hard_drive",
            image: "image", title: "title", ssh: "terminal", host: "dns", connection: "dns",
            git: "commit", "dms built-in": "widgets"
        };
        return map[t] || "info";
    }

    // Empty state.
    Column {
        anchors.centerIn: parent
        width: parent.width - Theme.spacingL * 2
        spacing: Theme.spacingS
        visible: !root.item
        opacity: 0.7

        DIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "manage_search"
            size: 44
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Select a result to see its details"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.Wrap
        }
    }

    DFlickable {
        id: sheetFlick

        anchors.fill: parent
        anchors.margins: Theme.spacingS
        contentWidth: width
        contentHeight: sheetCol.implicitHeight
        clip: true
        visible: !!root.item

        Column {
            id: sheetCol

            width: sheetFlick.width
            spacing: Theme.spacingS

            // ── compact header, every result type: icon left, full name
            // right (the result list elides long names; here they wrap
            // whole), kind chip below; files add a Full preview pill.
            Item {
                visible: !!root.item
                width: parent.width
                height: visible ? Math.max(48, fileHeadCol.implicitHeight) + Theme.spacingS * 2 : 0

                Rectangle {
                    id: fileHeadIcon

                    x: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48
                    height: 48
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.12)
                    border.color: Theme.withAlpha(Theme.primary, 0.18)
                    border.width: 1

                    // Same icon resolution as the result rows: app icons,
                    // material glyphs, unicode, composite.
                    AppIconRenderer {
                        anchors.centerIn: parent
                        width: 32
                        height: 32
                        iconSize: 32
                        iconValue: {
                            const it = root.item;
                            if (!it)
                                return "material:search";
                            if (it.iconType === "material" || it.iconType === "nerd")
                                return "material:" + (it.icon || "info");
                            if (it.iconType === "unicode")
                                return "unicode:" + (it.icon || "");
                            if (it.iconType === "composite")
                                return it.iconFull || "";
                            return it.icon || "";
                        }
                        iconColor: Theme.primary
                        fallbackText: (root.item?.name?.length > 0) ? root.item.name.charAt(0).toUpperCase() : "?"
                        materialIconSizeAdjustment: 4
                    }
                }

                Column {
                    id: fileHeadCol

                    anchors.left: fileHeadIcon.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    StyledText {
                        width: parent.width
                        text: root.item?.name ?? ""
                        font.pixelSize: Theme.fontSizeMedium + 1
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 3
                        elide: Text.ElideMiddle
                    }

                    Row {
                        spacing: Theme.spacingXS

                        Rectangle {
                            visible: root.kindLabel.length > 0
                            height: 22
                            width: fileKindLabel.implicitWidth + Theme.spacingM * 2
                            radius: height / 2
                            color: Theme.withAlpha(Theme.primary, 0.14)

                            StyledText {
                                id: fileKindLabel

                                anchors.centerIn: parent
                                text: root.kindLabel
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Theme.primary
                            }
                        }

                        Rectangle {
                            visible: root.isFileItem && !root.isDir
                            height: 22
                            width: filePrevRow.implicitWidth + Theme.spacingM * 2
                            radius: height / 2
                            color: filePrevArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.surfaceText, 0.06)
                            border.color: Theme.outlineMedium
                            border.width: 1

                            Row {
                                id: filePrevRow

                                anchors.centerIn: parent
                                spacing: Theme.spacingXXS

                                DIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "open_in_full"
                                    size: 13
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Full preview"
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceText
                                }
                            }

                            MouseArea {
                                id: filePrevArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openFullPreview()
                            }
                        }
                    }
                }
            }

            // ── old centred hero header: retired 2026-11-03, the compact
            // header above now serves every type (kept for easy revert).
            Item {
                visible: false
                width: parent.width
                height: heroCol.implicitHeight + Theme.spacingM * 2

                Column {
                    id: heroCol

                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingL * 2
                    spacing: Theme.spacingS

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 72
                        height: 72
                        radius: Theme.cornerRadius * 1.5
                        color: Theme.withAlpha(Theme.primary, 0.12)
                        border.color: Theme.withAlpha(Theme.primary, 0.18)
                        border.width: 1

                        AppIconRenderer {
                            anchors.centerIn: parent
                            width: 48
                            height: 48
                            iconSize: 48
                            iconValue: {
                                const it = root.item;
                                if (!it)
                                    return "material:search";
                                if (it.iconType === "material" || it.iconType === "nerd")
                                    return "material:" + (it.icon || "info");
                                if (it.iconType === "unicode")
                                    return "unicode:" + (it.icon || "");
                                if (it.iconType === "composite")
                                    return it.iconFull || "";
                                return it.icon || "";
                            }
                            fallbackText: (root.item?.name?.length > 0) ? root.item.name.charAt(0).toUpperCase() : "?"
                            materialIconSizeAdjustment: 8
                        }
                    }

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: root.item?.name ?? ""
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        // Break at spaces; Qt still breaks a single long
                        // token (a path, a hash) anywhere when it must.
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    // Kind chip + full-preview pill, centred together.
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.spacingXS
                        visible: root.kindLabel.length > 0 || (root.isFileItem && !root.isDir)

                        Rectangle {
                            id: kindChip

                            visible: root.kindLabel.length > 0
                            height: 24
                            width: kindChipLabel.implicitWidth + Theme.spacingM * 2
                            radius: height / 2
                            color: Theme.withAlpha(Theme.primary, 0.14)

                            StyledText {
                                id: kindChipLabel

                                anchors.centerIn: parent
                                text: root.kindLabel
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Theme.primary
                            }
                        }

                        Rectangle {
                            id: previewButton

                            // Sushi previews files, not directories.
                            visible: root.isFileItem && !root.isDir
                            height: 24
                            width: previewRow.implicitWidth + Theme.spacingM * 2
                            radius: height / 2
                            color: previewArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.surfaceText, 0.06)
                            border.color: Theme.outlineMedium
                            border.width: 1

                            Row {
                                id: previewRow

                                anchors.centerIn: parent
                                spacing: Theme.spacingXXS

                                DIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "open_in_full"
                                    size: 14
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Preview"
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceText
                                }
                            }

                            MouseArea {
                                id: previewArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openFullPreview()
                            }
                        }
                    }
                }
            }

            // ── one card per section ─────────────────────────────────
            Repeater {
                model: root.groups

                delegate: Rectangle {
                    id: card

                    required property var modelData

                    width: sheetCol.width
                    height: cardCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.floatingWindowNestedSurface
                    border.color: Theme.outlineMedium
                    border.width: Theme.layerOutlineWidth

                    Column {
                        id: cardCol

                        x: Theme.spacingM
                        y: Theme.spacingM
                        width: parent.width - Theme.spacingM * 2
                        spacing: Theme.spacingXS + 2

                        Row {
                            visible: !!card.modelData.title
                            spacing: Theme.spacingS
                            bottomPadding: 2

                            DIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: root.sectionIcon(card.modelData.title)
                                size: 18
                                color: Theme.primary
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: card.modelData.title || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }
                        }

                        Repeater {
                            model: card.modelData.rows

                            delegate: Item {
                                id: row

                                required property var modelData
                                readonly property bool isBlock: modelData.text !== undefined
                                readonly property bool isImage: !!modelData.image
                                // A link with no label is an action, drawn as a button.
                                readonly property bool isGrid: !!modelData.grid && modelData.grid.length > 0
                                readonly property bool isAction: !isGrid && !isBlock && !isImage && !!modelData.url && !modelData.label
                                readonly property bool isPair: !isGrid && !isBlock && !isImage && !isAction
                                readonly property int labelW: modelData.label ? (modelData.labelWidth || 92) : 0

                                width: cardCol.width
                                height: isGrid ? factGrid.implicitHeight : isBlock ? blockBox.height : isImage ? picBox.height : isAction ? actionBtn.height : pairRow.implicitHeight

                                // Short facts, two per line, label above value.
                                Grid {
                                    id: factGrid

                                    visible: row.isGrid
                                    width: parent.width
                                    columns: 2
                                    columnSpacing: Theme.spacingM
                                    rowSpacing: Theme.spacingS

                                    Repeater {
                                        model: row.isGrid ? row.modelData.grid : []

                                        delegate: Column {
                                            id: fact

                                            required property var modelData

                                            width: (factGrid.width - factGrid.columnSpacing) / 2
                                            spacing: 1

                                            StyledText {
                                                width: parent.width
                                                text: fact.modelData.label || ""
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: String(fact.modelData.value ?? "")
                                                isMonospace: !!fact.modelData.mono
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                                wrapMode: Text.WrapAnywhere
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }

                                // Key / value.
                                Row {
                                    id: pairRow

                                    visible: row.isPair
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    StyledText {
                                        width: row.labelW
                                        visible: !!row.modelData.label
                                        text: row.modelData.label || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        width: parent.width - (row.labelW ? row.labelW + Theme.spacingS : 0)
                                        text: row.modelData.url ? "<a href=\"" + root._esc(row.modelData.url) + "\" style=\"text-decoration:none\">" + root._esc(row.modelData.value ?? "") + "</a>" : String(row.modelData.value ?? "")
                                        textFormat: row.modelData.url ? Text.RichText : Text.PlainText
                                        linkColor: Theme.primary
                                        isMonospace: !!row.modelData.mono
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: row.modelData.label === "" ? Theme.surfaceVariantText : Theme.surfaceText
                                        wrapMode: Text.WrapAnywhere
                                        onLinkActivated: link => root._openLink(link)

                                        HoverHandler {
                                            enabled: !!row.modelData.url
                                            cursorShape: Qt.PointingHandCursor
                                        }
                                    }
                                }

                                // Label-less link -> pill button.
                                Rectangle {
                                    id: actionBtn

                                    visible: row.isAction
                                    height: 30
                                    width: Math.min(parent.width, actionRow.implicitWidth + Theme.spacingL * 2)
                                    radius: height / 2
                                    color: actionArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.primary, 0.12)

                                    Row {
                                        id: actionRow

                                        anchors.centerIn: parent
                                        spacing: Theme.spacingXS

                                        DIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: row.modelData.url === "dms:preview" ? "open_in_full" : "open_in_new"
                                            size: 16
                                            color: Theme.primary
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: String(row.modelData.value ?? "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                        }
                                    }

                                    MouseArea {
                                        id: actionArea

                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root._openLink(row.modelData.url)
                                    }
                                }

                                // Full-width text block (excerpt, clipboard text, value).
                                Rectangle {
                                    id: blockBox

                                    visible: row.isBlock
                                    width: parent.width
                                    height: visible ? blockText.implicitHeight + Theme.spacingS * 2 : 0
                                    radius: Math.max(4, Theme.cornerRadius - 4)
                                    color: row.modelData.editor ? root.editorBg : Theme.withAlpha(Theme.surfaceContainerHighest, 0.55)
                                    border.color: row.modelData.editor ? root.editorBorder : Theme.outlineLight
                                    border.width: 1

                                    StyledText {
                                        id: blockText

                                        x: Theme.spacingS
                                        y: Theme.spacingS
                                        width: parent.width - Theme.spacingS * 2
                                        text: String(row.modelData.text ?? "")
                                        textFormat: row.modelData.format === "markdown" ? Text.MarkdownText : (row.modelData.format === "html" ? Text.RichText : Text.PlainText)
                                        isMonospace: !!row.modelData.mono
                                        font.pixelSize: (row.modelData.format === "markdown" || (row.modelData.editor && !row.modelData.mono)) ? Theme.fontSizeSmall : Theme.fontSizeSmall - 1
                                        color: row.modelData.editor ? root.editorFg : Theme.withAlpha(Theme.surfaceText, 0.85)
                                        linkColor: row.modelData.editor ? "#4daafc" : Theme.primary
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideNone
                                        onLinkActivated: link => root._openLink(link)
                                    }
                                }

                                // Full-width picture.
                                Rectangle {
                                    id: picBox

                                    visible: row.isImage
                                    width: parent.width
                                    // From the picture's own aspect ratio -- deriving it
                                    // from paintedHeight fed back into itself and shrank.
                                    height: visible ? Math.min(240, pic.implicitWidth > 0 ? width * pic.implicitHeight / pic.implicitWidth : 120) : 0
                                    radius: Math.max(4, Theme.cornerRadius - 4)
                                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.55)
                                    clip: true

                                    Image {
                                        id: pic

                                        anchors.fill: parent
                                        source: row.modelData.image || ""
                                        asynchronous: true
                                        cache: false
                                        smooth: true
                                        sourceSize.width: 480
                                        sourceSize.height: 480
                                        fillMode: Image.PreserveAspectFit
                                        horizontalAlignment: Image.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    function _openLink(link) {
        if (link === "dms:preview") {
            openFullPreview();
            return;
        }
        Qt.openUrlExternally(link);
        requestClose();
    }
}
