// ═══════════════════════════════════════════════════════════════════════
//  snip — a Windows 11 Snipping Tool (Win+Shift+S) clone for Hyprland
//
//  Super+Shift+S (`global, snip:open`) freezes the focused monitor and
//  lays a dimmed copy of it over the screen with a mode toolbar on top:
//  Rectangle (the default), Freeform, Window and Fullscreen. A snip is cut
//  from the FROZEN image, so menus and tooltips that close when focus moves
//  are still in it, exactly like on Windows.
//
//  The overlay only selects. crop.py cuts the snip out of the frozen capture
//  (physical pixels, alpha mask for freeform), `snip-done save` copies it to
//  the clipboard and keeps it in ~/Pictures/Screenshots, and a card in the
//  corner offers Edit (Satty) and Copy text (OCR) -- Windows' snip toast.
//  The card is ours, not a notification: DMS closes a notification when its
//  popup times out, after which its actions reach nobody.
//  Text mode selects a rectangle the same way and goes straight to OCR.
//
//  Colours are read live from DankMaterialShell's generated palette, as in
//  the altswitcher overlay next door.
// ═══════════════════════════════════════════════════════════════════════
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/snip"
    readonly property string here: Quickshell.env("HOME") + "/.config/quickshell/snip"
    readonly property real dimOpacity: 0.45
    // Shorter drags than this are treated as a stray click, not a snip.
    readonly property int minSize: 4

    // ── state ──────────────────────────────────────────────────────────
    // `busy` covers the whole snip, from freezing the screen until the
    // overlay is gone; `ready` is when the frozen image is painted.
    property bool busy: false
    property bool ready: false
    property string mode: "rect"            // rect | free | window | full | text
    property string screenName: ""
    property var mon: null                  // hyprctl monitor object
    property var windows: []                // hit-test order, topmost first
    property int shot: 0
    property string frozen: ""
    property bool frozenOk: false           // grim finished writing `frozen`

    // Current selection in overlay (logical) coordinates.
    property real selX: 0
    property real selY: 0
    property real selW: 0
    property real selH: 0
    property var points: []
    property bool dragging: false
    property real startX: 0
    property real startY: 0

    function open() {
        if (root.busy)
            return;
        root.busy = true;
        root.ready = false;
        root.frozenOk = false;
        root.mode = "rect";
        root.clearSelection();
        root.shot += 1;
        root.frozen = root.runDir + "/frozen-" + root.shot + ".png";
        // The focused monitor comes from hyprctl, not Hyprland.focusedMonitor:
        // that is still null for a while after the service starts.
        freeze.command = ["sh", "-c",
            'mkdir -p "$2" && rm -f "$2"/frozen-*.png; m=$(hyprctl -j monitors) || exit 1; '
            + 'grim -o "$(printf %s "$m" | jq -r ".[] | select(.focused) | .name")" "$1" || exit 1; '
            + 'printf \'{"monitors":%s,"clients":%s}\' "$m" "$(hyprctl -j clients)"',
            "snip", root.frozen, root.runDir];
        freeze.running = true;
    }

    function cancel() {
        root.pendingFull = false;
        root.busy = false;
        root.ready = false;
        root.frozenOk = false;
        root.clearSelection();
    }

    function clearSelection() {
        root.selX = 0;
        root.selY = 0;
        root.selW = 0;
        root.selH = 0;
        root.points = [];
        root.dragging = false;
    }

    // Snipping Tool's z-order guess: a visible special workspace sits on
    // top, then fullscreen, then floating, then tiled; within each, the most
    // recently focused first. Hidden group tabs are skipped.
    function loadWindows(monitors, clients) {
        const m = monitors.find(x => x.focused);
        if (!m)
            return false;
        root.mon = m;
        root.screenName = m.name;
        const ws = m.activeWorkspace ? m.activeWorkspace.id : -1;
        const sp = m.specialWorkspace ? m.specialWorkspace.id : 0;
        const list = clients.filter(c => c.mapped && !c.hidden && c.monitor === m.id
            && (c.workspace.id === ws || (sp !== 0 && c.workspace.id === sp)));
        const key = c => [(sp !== 0 && c.workspace.id === sp) ? 0 : 1, c.fullscreen ? 0 : 1,
            c.floating ? 0 : 1, c.focusHistoryID];
        list.sort((a, b) => {
            const ka = key(a), kb = key(b);
            for (let i = 0; i < ka.length; i++)
                if (ka[i] !== kb[i])
                    return ka[i] - kb[i];
            return 0;
        });
        root.windows = list.map(c => ({
            x: c.at[0] - m.x,
            y: c.at[1] - m.y,
            w: c.size[0],
            h: c.size[1]
        }));
        return true;
    }

    function windowAt(px, py) {
        for (const w of root.windows)
            if (px >= w.x && px < w.x + w.w && py >= w.y && py < w.y + w.h)
                return w;
        return null;
    }

    function setMode(m) {
        root.clearSelection();
        root.mode = m;
        if (m === "full")
            root.capture(0, 0, overlay.width, overlay.height, []);
    }

    function capture(x, y, w, h, pts) {
        // Clamp to the screen; window rects can hang off its edges.
        const x0 = Math.max(0, x), y0 = Math.max(0, y);
        const x1 = Math.min(overlay.width, x + w), y1 = Math.min(overlay.height, y + h);
        if (x1 - x0 < root.minSize || y1 - y0 < root.minSize)
            return;
        const out = root.runDir + "/snip-" + Date.now() + ".png";
        crop.out = out;
        crop.text = root.mode === "text";
        crop.command = ["/usr/bin/python3", "-I", root.here + "/crop.py", root.frozen, out,
            String(root.mon.scale), String(x0), String(y0), String(x1 - x0), String(y1 - y0),
            pts.map(p => p.x.toFixed(1) + "," + p.y.toFixed(1)).join(" ")];
        root.ready = false;            // hide now; the crop works on the file
        crop.running = true;
    }

    // ── processes ──────────────────────────────────────────────────────
    Process {
        id: freeze
        stdout: StdioCollector {
            id: freezeOut
        }
        onExited: code => {
            if (code !== 0) {
                console.warn("snip: freezing the screen failed (" + code + ")");
                root.cancel();
                return;
            }
            try {
                const j = JSON.parse(freezeOut.text);
                if (root.loadWindows(j.monitors, j.clients))
                    root.frozenOk = true;
                else
                    root.cancel();
            } catch (e) {
                console.warn("snip: bad hyprctl output: " + e);
                root.cancel();
            }
        }
    }

    Process {
        id: crop
        property string out: ""
        property bool text: false
        onExited: code => {
            if (code !== 0)
                console.warn("snip: crop failed (" + code + ")");
            else if (crop.text)
                root.helper(["text", crop.out, "rm"]);
            else {
                save.command = [root.doneScript, "save", crop.out];
                save.running = true;
            }
            root.cancel();
        }
    }

    Process {
        id: save
        stdout: StdioCollector {
            id: saveOut
        }
        onExited: code => {
            if (code === 0 && saveOut.text.trim())
                toast.show(saveOut.text.trim());
        }
    }

    readonly property string doneScript: Quickshell.env("HOME") + "/.local/bin/snip-done"

    // Its own scope, so a Satty window outlives a restart of this service.
    function helper(args) {
        Quickshell.execDetached(["systemd-run", "--user", "--scope", "--quiet", root.doneScript].concat(args));
    }

    // `qs -c snip ipc call snip full` snips the whole screen with no UI.
    property bool pendingFull: false

    IpcHandler {
        target: "snip"
        function open(): void { root.open(); }
        function full(): void { root.pendingFull = true; root.open(); }
        function cancel(): void { root.cancel(); }
    }

    GlobalShortcut {
        appid: "snip"
        name: "open"
        description: "Snipping Tool: start a snip"
        onPressed: root.open()
    }

    // ── theme, read live from DankMaterialShell ────────────────────────
    FileView {
        id: paletteFile
        path: Quickshell.env("HOME") + "/.cache/accent/palette.json"
        watchChanges: true
        onFileChanged: reload()
    }

    FileView {
        id: sessionFile
        path: Quickshell.env("HOME") + "/.local/state/dms/session.json"
        watchChanges: true
        onFileChanged: reload()
    }

    // A private copy of DMS's icon font: pointing into the DMS tree broke the
    // toolbar icons when DMS 2.0 renamed DankCommon -> DCommon.
    FontLoader {
        id: iconFont
        source: "file://" + Quickshell.env("HOME") + "/.local/share/fonts/MaterialSymbolsRounded-snip.ttf"
    }

    QtObject {
        id: theme

        readonly property var palette: {
            const txt = paletteFile.text();
            if (!txt)
                return null;
            try {
                const j = JSON.parse(txt);
                return j.colors ? j.colors[theme.mode] : null;
            } catch (e) {
                return null;
            }
        }

        readonly property string mode: {
            const txt = sessionFile.text();
            if (!txt)
                return "dark";
            try {
                return JSON.parse(txt).isLightMode ? "light" : "dark";
            } catch (e) {
                return "dark";
            }
        }

        function pick(key, fallback) {
            const p = theme.palette;
            return (p && p[key]) ? p[key] : fallback;
        }

        // Not named after the Material keys: a property called `onSurface`
        // collides with signal-handler syntax (see altswitcher).
        readonly property color bg: pick("surface_container", "#251d24")
        readonly property color textPrimary: pick("on_surface", "#eedee8")
        readonly property color accent: pick("primary", "#ffaaf8")
        readonly property color accentText: pick("on_primary", "#000000")
        readonly property color stroke: pick("outline_variant", "#51424e")
    }

    // ── overlay ────────────────────────────────────────────────────────
    PanelWindow {
        id: overlay

        screen: {
            for (const s of Quickshell.screens)
                if (s.name === root.screenName)
                    return s;
            return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        }

        // Mapped once the screen is frozen, but painted only when the frozen
        // image has loaded: an Image in an unmapped window never loads.
        visible: root.busy && root.frozenOk
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "snip"
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Item {
            id: stage
            anchors.fill: parent
            opacity: root.ready ? 1 : 0
            focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape)
                    root.cancel();
                else if (event.key === Qt.Key_1)
                    root.setMode("rect");
                else if (event.key === Qt.Key_2)
                    root.setMode("free");
                else if (event.key === Qt.Key_3)
                    root.setMode("window");
                else if (event.key === Qt.Key_4)
                    root.setMode("full");
                else if (event.key === Qt.Key_5 || event.key === Qt.Key_T)
                    root.setMode("text");
                event.accepted = true;
            }

            Image {
                anchors.fill: parent
                source: root.busy && root.frozenOk ? "file://" + root.frozen : ""
                cache: false
                asynchronous: false
                smooth: true
                onStatusChanged: {
                    if (status === Image.Ready && root.busy) {
                        root.ready = true;
                        stage.forceActiveFocus();
                        if (root.pendingFull) {
                            root.pendingFull = false;
                            root.setMode("full");
                        }
                    } else if (status === Image.Error && root.busy) {
                        root.cancel();
                    }
                }
            }

            // Dim everything except the hole (the current rectangle or the
            // hovered window). Freeform dims fully and draws its outline.
            Item {
                id: hole
                readonly property bool on: root.mode !== "free" && root.selW > 0 && root.selH > 0
                x: on ? root.selX : 0
                y: on ? root.selY : 0
                width: on ? root.selW : 0
                height: on ? root.selH : 0
            }
            Rectangle {
                color: "black"; opacity: root.dimOpacity
                x: 0; y: 0; width: parent.width; height: hole.y
            }
            Rectangle {
                color: "black"; opacity: root.dimOpacity
                x: 0; y: hole.y + hole.height; width: parent.width; height: parent.height - y
            }
            Rectangle {
                color: "black"; opacity: root.dimOpacity
                x: 0; y: hole.y; width: hole.x; height: hole.height
            }
            Rectangle {
                color: "black"; opacity: root.dimOpacity
                x: hole.x + hole.width; y: hole.y; width: parent.width - x; height: hole.height
            }
            Rectangle {
                visible: hole.on
                x: hole.x - 1; y: hole.y - 1
                width: hole.width + 2; height: hole.height + 2
                color: "transparent"
                border.color: theme.accent
                border.width: 2
            }

            Canvas {
                id: path
                anchors.fill: parent
                visible: root.mode === "free"
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const p = root.points;
                    if (p.length < 2)
                        return;
                    ctx.strokeStyle = theme.accent;
                    ctx.lineWidth = 2;
                    ctx.lineJoin = "round";
                    ctx.beginPath();
                    ctx.moveTo(p[0].x, p[0].y);
                    for (let i = 1; i < p.length; i++)
                        ctx.lineTo(p[i].x, p[i].y);
                    ctx.stroke();
                }
                Connections {
                    target: root
                    function onPointsChanged() { path.requestPaint(); }
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.mode === "window" ? Qt.PointingHandCursor : Qt.CrossCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        root.cancel();
                        return;
                    }
                    if (root.mode === "rect" || root.mode === "text" || root.mode === "free") {
                        root.dragging = true;
                        root.startX = mouse.x;
                        root.startY = mouse.y;
                        root.selW = 0;
                        root.selH = 0;
                        root.points = [Qt.point(mouse.x, mouse.y)];
                    }
                }

                onPositionChanged: mouse => {
                    if (root.mode === "window") {
                        const w = root.windowAt(mouse.x, mouse.y);
                        root.selX = w ? w.x : 0;
                        root.selY = w ? w.y : 0;
                        root.selW = w ? w.w : 0;
                        root.selH = w ? w.h : 0;
                    } else if (root.dragging && (root.mode === "rect" || root.mode === "text")) {
                        root.selX = Math.min(root.startX, mouse.x);
                        root.selY = Math.min(root.startY, mouse.y);
                        root.selW = Math.abs(mouse.x - root.startX);
                        root.selH = Math.abs(mouse.y - root.startY);
                    } else if (root.dragging && root.mode === "free") {
                        root.points = root.points.concat([Qt.point(mouse.x, mouse.y)]);
                    }
                }

                onReleased: mouse => {
                    if (mouse.button !== Qt.LeftButton || !root.dragging)
                        return;
                    root.dragging = false;
                    if (root.mode === "rect" || root.mode === "text") {
                        root.capture(root.selX, root.selY, root.selW, root.selH, []);
                        if (root.ready)          // too small: start over
                            root.clearSelection();
                    } else if (root.mode === "free") {
                        const p = root.points;
                        if (p.length < 3) {
                            root.clearSelection();
                            return;
                        }
                        const xs = p.map(q => q.x), ys = p.map(q => q.y);
                        const x0 = Math.min(...xs), y0 = Math.min(...ys);
                        root.capture(x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0, p);
                        if (root.ready)
                            root.clearSelection();
                    }
                }

                onClicked: mouse => {
                    if (mouse.button === Qt.LeftButton && root.mode === "window" && root.selW > 0)
                        root.capture(root.selX, root.selY, root.selW, root.selH, []);
                }
            }

            // ── toolbar ────────────────────────────────────────────────
            Rectangle {
                id: toolbar
                anchors.horizontalCenter: parent.horizontalCenter
                y: 20
                width: tools.width + 12
                height: tools.height + 12
                radius: 14
                color: theme.bg
                border.color: theme.stroke
                border.width: 1

                Row {
                    id: tools
                    anchors.centerIn: parent
                    spacing: 4

                    Repeater {
                        model: [
                            { mode: "rect", icon: "crop_square", label: "Rectangle" },
                            { mode: "free", icon: "gesture", label: "Freeform" },
                            { mode: "window", icon: "select_window", label: "Window" },
                            { mode: "full", icon: "fullscreen", label: "Fullscreen" },
                            { mode: "text", icon: "document_scanner", label: "Text" }
                        ]

                        delegate: Rectangle {
                            id: btn
                            required property var modelData
                            readonly property bool current: root.mode === modelData.mode
                            width: 92
                            height: 54
                            radius: 10
                            color: current ? theme.accent
                                 : hover.containsMouse ? Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.1)
                                 : "transparent"

                            Column {
                                anchors.centerIn: parent
                                spacing: 2
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: btn.modelData.icon
                                    font.family: iconFont.name
                                    font.pixelSize: 24
                                    color: btn.current ? theme.accentText : theme.textPrimary
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: btn.modelData.label
                                    font.pixelSize: 12
                                    color: btn.current ? theme.accentText : theme.textPrimary
                                }
                            }

                            MouseArea {
                                id: hover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.ArrowCursor
                                onClicked: root.setMode(btn.modelData.mode)
                            }
                        }
                    }

                    Rectangle {
                        width: 1
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        color: theme.stroke
                    }

                    Rectangle {
                        width: 54
                        height: 54
                        radius: 10
                        color: closeHover.containsMouse ? Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.1) : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "close"
                            font.family: iconFont.name
                            font.pixelSize: 24
                            color: theme.textPrimary
                        }
                        MouseArea {
                            id: closeHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.ArrowCursor
                            onClicked: root.cancel()
                        }
                    }
                }
            }
        }
    }

    // ── the card after a snip ──────────────────────────────────────────
    PanelWindow {
        id: toast

        property string file: ""
        property bool open: false

        function show(f) {
            toast.file = f;
            toast.open = true;
            hideTimer.restart();
        }

        function act(what) {
            toast.open = false;
            if (what !== "close")
                root.helper([what, toast.file]);
        }

        screen: overlay.screen
        visible: open
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "snip-toast"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            bottom: true
            right: true
        }
        margins {
            bottom: 56
            right: 16
        }
        implicitWidth: 340
        implicitHeight: card.height

        Timer {
            id: hideTimer
            interval: 8000
            onTriggered: {
                if (cardHover.containsMouse)
                    restart();
                else
                    toast.open = false;
            }
        }

        Rectangle {
            id: card
            width: parent.width
            height: content.height + 24
            radius: 14
            color: theme.bg
            border.color: theme.stroke
            border.width: 1

            MouseArea {
                id: cardHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Clicking the card itself edits, as on Windows.
                onClicked: toast.act("edit")
            }

            Column {
                id: content
                x: 12
                y: 12
                width: parent.width - 24
                spacing: 10

                Row {
                    spacing: 10
                    width: parent.width

                    Image {
                        id: thumb
                        width: 120
                        height: 72
                        source: toast.file ? "file://" + toast.file : ""
                        cache: false
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: 240
                    }

                    Column {
                        width: parent.width - thumb.width - closeBtn.width - 20
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Text {
                            width: parent.width
                            text: "Snip copied to clipboard"
                            color: theme.textPrimary
                            font.pixelSize: 14
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            width: parent.width
                            text: "Saved to Screenshots. Click to edit."
                            color: theme.textPrimary
                            opacity: 0.75
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                    }

                    Text {
                        id: closeBtn
                        text: "close"
                        font.family: iconFont.name
                        font.pixelSize: 20
                        color: theme.textPrimary
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: toast.act("close")
                        }
                    }
                }

                Row {
                    spacing: 8
                    Repeater {
                        model: [
                            { what: "edit", icon: "edit", label: "Edit" },
                            { what: "text", icon: "document_scanner", label: "Copy text" }
                        ]
                        delegate: Rectangle {
                            id: action
                            required property var modelData
                            width: actionRow.width + 24
                            height: 34
                            radius: 17
                            color: actionHover.containsMouse ? theme.accent
                                 : Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.08)
                            Row {
                                id: actionRow
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: action.modelData.icon
                                    font.family: iconFont.name
                                    font.pixelSize: 18
                                    color: actionHover.containsMouse ? theme.accentText : theme.textPrimary
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: action.modelData.label
                                    font.pixelSize: 13
                                    color: actionHover.containsMouse ? theme.accentText : theme.textPrimary
                                }
                            }
                            MouseArea {
                                id: actionHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: toast.act(action.modelData.what)
                            }
                        }
                    }
                }
            }
        }
    }
}
