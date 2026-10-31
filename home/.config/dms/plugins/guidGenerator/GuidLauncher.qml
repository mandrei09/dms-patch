import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// GUID/UUID generator for the DMS launcher.
//
//   guid        one fresh v4 in lower / UPPER / no-dash / {braces}, plus a v7
//   guid 10     a batch of 10, as lines (lower and UPPER) or a quoted SQL list
//
// Randomness comes from /dev/urandom via a small hex pool that refills in the
// background; Math.random is only a fallback for the first few milliseconds
// after startup, before the pool has been filled once.
Item {
    id: root

    property var pluginService: null
    property string trigger: "guid"

    signal itemsChanged

    readonly property int maxBatch: 500

    // Hex characters read from /dev/urandom, consumed from the front.
    property string _pool: ""
    // getItems() is re-run for the same query within a few ms (debounce
    // phases, list refreshes); a short memo stops the GUIDs flickering. It
    // expires so reopening the launcher later still offers fresh ones.
    property string _memoQuery: "\u0000"
    property var _memoItems: []
    property real _memoAt: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData("guidGenerator", "trigger", "guid");
        _refill();
    }

    Process {
        id: urandom
        // 4 KiB -> 8192 hex chars -> ~256 GUIDs per fill.
        command: ["od", "-An", "-v", "-tx1", "-N", "4096", "/dev/urandom"]
        stdout: StdioCollector {
            onStreamFinished: root._pool += this.text.replace(/[^0-9a-f]/g, "")
        }
    }

    function _refill() {
        if (!urandom.running)
            urandom.running = true;
    }

    function _hex(n) {
        let out = "";
        if (_pool.length >= n) {
            out = _pool.substring(0, n);
            _pool = _pool.substring(n);
        } else {
            for (let i = 0; i < n; i++)
                out += Math.floor(Math.random() * 16).toString(16);
        }
        if (_pool.length < 2048)
            _refill();
        return out;
    }

    function _dash(h) {
        return h.substring(0, 8) + "-" + h.substring(8, 12) + "-" + h.substring(12, 16) + "-" + h.substring(16, 20) + "-" + h.substring(20, 32);
    }

    // RFC 9562 variant bits: 10xx in the top of the 17th hex digit.
    function _variant(c) {
        return ((parseInt(c, 16) & 0x3) | 0x8).toString(16);
    }

    function uuid4() {
        const h = _hex(32);
        return _dash(h.substring(0, 12) + "4" + h.substring(13, 16) + _variant(h[16]) + h.substring(17));
    }

    // Time-ordered: 48-bit Unix ms timestamp, then random. Sorts by creation
    // time, which keeps B-tree indexes happy when used as a primary key.
    function uuid7() {
        let ts = Date.now().toString(16);
        while (ts.length < 12)
            ts = "0" + ts;
        const h = _hex(20);
        return _dash(ts + "7" + h.substring(0, 3) + _variant(h[3]) + h.substring(4));
    }

    function _item(name, comment, value, icon) {
        return {
            name: name,
            icon: "material:" + (icon || "fingerprint"),
            comment: comment,
            action: "copy:" + value,
            _value: value,
            categories: ["GUID Generator"]
        };
    }

    function _build(query) {
        const q = (query || "").trim().toLowerCase();

        if (q === "") {
            const g = uuid4();
            const v7 = uuid7();
            return [
                _item(g, "UUID v4 · lowercase", g),
                _item(g.toUpperCase(), "UUID v4 · UPPERCASE", g.toUpperCase()),
                _item(g.replace(/-/g, ""), "UUID v4 · no hyphens (\"N\")", g.replace(/-/g, "")),
                _item("{" + g + "}", "UUID v4 · braces (\"B\", registry / .NET)", "{" + g + "}"),
                _item(v7, "UUID v7 · time-ordered, good for primary keys", v7, "schedule")
            ];
        }

        const count = /^\d+$/.test(q) ? parseInt(q, 10) : NaN;
        if (count >= 1 && count <= maxBatch) {
            const list = [];
            for (let i = 0; i < count; i++)
                list.push(uuid4());
            const lines = list.join("\n");
            const upper = lines.toUpperCase();
            const sql = list.map(g => "'" + g + "'").join(", ");
            const more = count > 1 ? "  … +" + (count - 1) : "";
            return [
                _item(list[0] + more, count + " × UUID v4 · one per line", lines, "format_list_bulleted"),
                _item(list[0].toUpperCase() + more, count + " × UUID v4 · UPPERCASE, one per line", upper, "format_list_bulleted"),
                _item("'" + list[0] + "'" + (count > 1 ? ", …" : ""), count + " × UUID v4 · quoted, comma-separated (SQL IN list)", sql, "database")
            ];
        }

        return [
            {
                name: "Usage: guid  ·  guid <count>",
                icon: "material:info",
                comment: "Count must be 1–" + maxBatch,
                action: "none",
                categories: ["GUID Generator"]
            }
        ];
    }

    function getItems(query) {
        const now = Date.now();
        if (query === _memoQuery && now - _memoAt < 3000)
            return _memoItems;
        _memoQuery = query;
        _memoAt = now;
        // Pre-score in our own order: the launcher otherwise fuzzy-matches
        // each result against the typed count ("5") and drops GUIDs that
        // happen not to contain it.
        _memoItems = _build(query).map((it, i) => Object.assign(it, { _preScored: 1000 - i }));
        return _memoItems;
    }

    function getPasteText(item) {
        return item?._value ?? null;
    }

    function executeItem(item) {
        if (!item?._value)
            return;
        Quickshell.execDetached(["dms", "cl", "copy", item._value]);
        const lines = item._value.split("\n").length;
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("GUID Generator", lines > 1 ? "Copied " + lines + " GUIDs" : "Copied " + item._value);
        // Next open of the launcher should offer fresh ones.
        _memoQuery = "\u0000";
        _memoItems = [];
    }
}
