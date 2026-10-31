import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services
import "tools.js" as Tools

// Shared body of the b64 / url / jwt / ts launcher plugins. Each plugin's own
// component is a two-liner that sets `tool` and `pluginId`; DMS allows one
// trigger per plugin, hence four plugins around one implementation.
//
// Typed text is transformed directly. With nothing typed, the clipboard is
// used instead -- copy a token, type `jwt`, read it. The clipboard is re-read
// each time the query goes empty, asynchronously, and the launcher is asked to
// refresh once it arrives.
Item {
    id: root

    property var pluginService: null
    property string pluginId: ""
    property string tool: ""
    property string trigger: tool
    property string title: tool

    signal itemsChanged

    readonly property int maxClip: 20000

    property string _clip: ""
    property real _clipAt: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData(pluginId, "trigger", tool);
    }

    Process {
        id: paste
        command: ["wl-paste", "--no-newline", "--type", "text"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = this.text.length > root.maxClip ? "" : this.text;
                const changed = t !== root._clip;
                root._clip = t;
                root._clipAt = Date.now();
                if (changed && root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
            }
        }
    }

    function _run(input) {
        switch (tool) {
        case "b64":
            return Tools.b64(input);
        case "url":
            return Tools.url(input);
        case "jwt":
            return Tools.jwt(input, Date.now());
        case "ts":
            return Tools.ts(input, Date.now());
        }
        return [];
    }

    function _oneLine(s) {
        s = String(s).replace(/\r?\n/g, " ⏎ ");
        return s.length > 300 ? s.substring(0, 300) + " …" : s;
    }

    function _toItems(rows, suffix) {
        return rows.map((r, i) => ({
                    name: _oneLine(r.name),
                    icon: "material:" + (r.icon || "build"),
                    comment: r.comment + (suffix || ""),
                    action: "copy",
                    _value: r.value,
                    _preScored: 1000 - i,
                    categories: [title]
                }));
    }

    function _hint(text) {
        return [
            {
                name: text,
                icon: "material:info",
                comment: title,
                action: "none",
                _preScored: 1000,
                categories: [title]
            }
        ];
    }

    readonly property var _usage: ({
            "b64": "Type text or base64 (b64 aGVsbG8=), or copy some and type b64",
            "url": "Type text or a URL (url a b&c), or copy one and type url",
            "jwt": "Paste a token (jwt eyJhbGci…), or copy one and type jwt",
            "ts": "ts 1758895200 · ts 2026-09-26 17:00 · ts now"
        })

    function getItems(query) {
        const q = (query || "").trim();
        if (q.length > 0) {
            const rows = _run(q);
            return rows.length > 0 ? _toItems(rows) : _hint(tool === "jwt" ? "Not a JWT (expected header.payload.signature)" : _usage[tool]);
        }

        // Empty query: refresh the clipboard (at most every 700 ms, so the
        // refresh this triggers doesn't loop), and show what we have now.
        if (Date.now() - _clipAt > 700 && !paste.running)
            paste.running = true;

        const clip = _clip.trim();
        const fromClip = clip ? _run(clip) : [];
        if (tool === "ts") {
            // No input means "now"; a timestamp on the clipboard comes first.
            const now = _toItems(Tools.ts("", Date.now()));
            return fromClip.length > 0 && /^\d{9,19}$/.test(clip) ? _toItems(fromClip, " · from clipboard").concat(now.map((it, i) => Object.assign(it, { _preScored: 500 - i }))) : now;
        }
        if (fromClip.length > 0)
            return _toItems(fromClip, " · from clipboard");
        return _hint(_usage[tool]);
    }

    function getPasteText(item) {
        return item?._value ?? null;
    }

    function executeItem(item) {
        if (item?._value === undefined || item._value === null)
            return;
        Quickshell.execDetached(["dms", "cl", "copy", String(item._value)]);
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, "Copied " + _oneLine(item._value).substring(0, 80));
    }
}
