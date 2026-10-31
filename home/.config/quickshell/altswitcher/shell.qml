// ═══════════════════════════════════════════════════════════════════════
//  altswitcher — a GNOME-style Alt+Tab overlay for Hyprland
//
//  Hyprland's own `cyclenext` switches focus the instant the key is hit,
//  with no visual list. This replaces that with an overlay showing every
//  window on EVERY workspace (special ones excluded) in most-recently-used
//  order -- committing jumps to that window's workspace -- so a hold
//  of Alt and repeated Tab walks the list before committing.
//
//  How the key handling is split, which is the only subtle part:
//    * Tab / Shift+Tab are HYPRLAND binds (`global, altswitcher:next`).
//      Compositor binds are processed before the key reaches any client
//      and are consumed, so the overlay never sees Tab -- no double step.
//    * Alt RELEASE is handled by the OVERLAY. A `bindr` on a bare modifier
//      is suppressed by Hyprland once another bind has fired during the
//      hold (that is what makes tap-Super-alone work), so it cannot be
//      relied on here. Instead the layer surface takes exclusive keyboard
//      focus and watches for the Alt keyup itself. Modifiers are always
//      forwarded to the focused surface, bound or not.
//    * Escape / Enter / arrows are also the overlay's, since Hyprland has
//      no binds for them to swallow.
//
//  Colours are read live from DankMaterialShell's generated palette, so
//  this follows the desktop accent and the light/dark toggle with no
//  duplicated theme data.
// ═══════════════════════════════════════════════════════════════════════
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    // ── tunables ───────────────────────────────────────────────────────
    // Each tile is a live thumbnail of the window (ScreencopyView over
    // Hyprland's toplevel-export, which also works for windows on other,
    // unrendered workspaces) with the app icon as a badge in the corner.
    readonly property int thumbWidth: 240
    readonly property int thumbHeight: 150
    readonly property int tilePad: 8
    readonly property int badgeSize: 36
    readonly property int tileGap: 8
    readonly property int tileWidth: thumbWidth + tilePad * 2
    readonly property int tileHeight: thumbHeight + tilePad * 2
    // Fixed, deliberately. Sizing the card to its contents made it jump on
    // every Tab as titles of different lengths came up. Tiles centre inside
    // this width and wrap past four per row; titles elide.
    readonly property int maxColumns: 4
    readonly property int cardWidth: maxColumns * (tileWidth + tileGap) - tileGap + 32
    readonly property real scrimOpacity: 0.35
    readonly property int animMs: 130
    // A quick tap of Alt+Tab -- the "flip to the last window" case -- should
    // not flash a modal on screen. The overlay is mapped (and grabbing the
    // keyboard) from the first press, but stays fully transparent until the
    // hold outlasts this, so a fast tap commits with nothing drawn at all.
    readonly property int showDelayMs: 100
    // Guard against being left with an exclusive keyboard grab if the Alt
    // keyup is ever missed. Never reached in normal use; without it a missed
    // release would swallow every keystroke that is not a Hyprland bind.
    readonly property int watchdogMs: 15000

    // ── state ──────────────────────────────────────────────────────────
    // `active` means the switcher owns the keyboard; `shown` means it is also
    // painted. They are deliberately separate -- see showDelayMs.
    property bool active: false
    property bool shown: false
    property int index: 0
    // Most-recently-used addresses, freshest first. Maintained from
    // Hyprland events rather than re-read per keypress so that opening the
    // switcher costs nothing.
    property var mru: []
    // Snapshot taken when the switcher opens. Frozen for the lifetime of
    // one Alt hold: a window list that reorders under the cursor while you
    // are tabbing through it is unusable.
    property var entries: []
    property string restoreAddress: ""

    function norm(a) {
        return String(a || "").replace(/^0x/, "").toLowerCase();
    }

    function touch(addr) {
        const a = norm(addr);
        if (!a || a === "0")
            return;
        const next = root.mru.filter(x => x !== a);
        next.unshift(a);
        root.mru = next;
    }

    function forget(addr) {
        const a = norm(addr);
        root.mru = root.mru.filter(x => x !== a);
    }

    function rank(addr) {
        const i = root.mru.indexOf(norm(addr));
        return i < 0 ? 9999 : i;
    }

    // Seed the MRU from Hyprland's own focusHistoryID (0 = focused) so the
    // very first Alt+Tab of a session is already in the right order.
    function seedMru() {
        const seen = [];
        for (const t of Hyprland.toplevels.values) {
            const o = t.lastIpcObject;
            if (!o)
                continue;
            seen.push({
                a: root.norm(t.address),
                h: o.focusHistoryID === undefined ? 9999 : o.focusHistoryID
            });
        }
        seen.sort((x, y) => x.h - y.h);
        root.mru = seen.map(x => x.a);
    }

    function iconFor(cls) {
        if (!cls)
            return Quickshell.iconPath("application-x-executable", true);
        let e = DesktopEntries.heuristicLookup(cls);
        if (!e && cls.indexOf(".") >= 0)
            e = DesktopEntries.heuristicLookup(cls.split(".").pop());
        for (const name of [e ? e.icon : "", cls, cls.toLowerCase()]) {
            if (!name)
                continue;
            const p = Quickshell.iconPath(name, true);
            if (p)
                return p;
        }
        return Quickshell.iconPath("application-x-executable", true);
    }

    function appNameFor(cls) {
        if (!cls)
            return "";
        let e = DesktopEntries.heuristicLookup(cls);
        if (!e && cls.indexOf(".") >= 0)
            e = DesktopEntries.heuristicLookup(cls.split(".").pop());
        return e ? e.name : cls;
    }

    // Windows on all regular workspaces, MRU-ordered. Special workspaces are
    // skipped: special:keepalive holds a hidden Nautilus that must never be
    // focused, and special:desktop is Super+D's stash.
    function snapshot() {
        const live = [];
        for (const t of Hyprland.toplevels.values) {
            if (!t.workspace || String(t.workspace.name).startsWith("special:"))
                continue;
            const o = t.lastIpcObject;
            if (o && o.mapped === false)
                continue;
            live.push(t);
        }
        live.sort((a, b) => root.rank(a.address) - root.rank(b.address));
        return live.map(t => {
            const cls = t.lastIpcObject ? t.lastIpcObject.class : "";
            return {
                address: t.address,
                // Ptyxis and friends pad titles with a trailing space, which
                // throws the centring off by a few pixels.
                title: (t.title || root.appNameFor(cls) || "Untitled").trim(),
                appName: root.appNameFor(cls),
                wsName: String(t.workspace.name),
                // The wl_foreign_toplevel handle ScreencopyView captures.
                wl: t.wayland,
                icon: root.iconFor(cls)
            };
        });
    }

    // ── open / step / commit ───────────────────────────────────────────
    function step(delta) {
        if (!root.active) {
            const list = root.snapshot();
            if (list.length < 2)
                return;
            root.entries = list;
            root.restoreAddress = list[0].address;
            // Classic behaviour: one Alt+Tab and release lands on the
            // previously focused window, not the current one.
            root.index = delta > 0 ? 1 : list.length - 1;
            root.active = true;
            showTimer.restart();
            watchdog.restart();
            return;
        }
        const n = root.entries.length;
        if (n === 0)
            return;
        root.index = ((root.index + delta) % n + n) % n;
        // A second Tab means you are browsing rather than flipping, so stop
        // waiting and show the list now.
        showTimer.stop();
        root.shown = true;
        watchdog.restart();
    }

    function close() {
        showTimer.stop();
        watchdog.stop();
        root.active = false;
        root.shown = false;
        root.entries = [];
    }

    function focusAddress(addr) {
        if (!addr)
            return;
        Hyprland.dispatch("focuswindow address:0x" + root.norm(addr));
        Hyprland.dispatch("alterzorder top,address:0x" + root.norm(addr));
    }

    function commit() {
        if (!root.active)
            return;
        const e = root.entries[root.index];
        root.close();
        if (!e)
            return;
        // The snapshot is frozen for the duration of the hold, so a window
        // closed in the meantime would leave a dead address here.
        for (const t of Hyprland.toplevels.values) {
            if (t.address === e.address) {
                root.focusAddress(e.address);
                return;
            }
        }
    }

    function cancel() {
        if (!root.active)
            return;
        const back = root.restoreAddress;
        root.close();
        root.focusAddress(back);
    }

    // ── Hyprland wiring ────────────────────────────────────────────────
    // The Connections block is also what forces Quickshell's lazily
    // initialised Hyprland/DesktopEntries singletons to start populating.
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            switch (event.name) {
            case "activewindowv2":
                root.touch(event.data);
                break;
            case "closewindow":
                root.forget(event.data);
                break;
            case "openwindow":
                // lastIpcObject (which carries the window class we need for
                // the icon) is only filled in by an explicit refresh.
                Hyprland.refreshToplevels();
                root.touch(String(event.data).split(",")[0]);
                break;
            }
        }
    }

    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {}
    }

    Component.onCompleted: {
        Hyprland.refreshToplevels();
        Hyprland.refreshWorkspaces();
        seedTimer.start();
    }

    // refreshToplevels() is async; give it a beat before reading history.
    Timer {
        id: seedTimer
        interval: 800
        onTriggered: root.seedMru()
    }

    Timer {
        id: showTimer
        interval: root.showDelayMs
        onTriggered: if (root.active) root.shown = true
    }

    Timer {
        id: watchdog
        interval: root.watchdogMs
        // Cancel rather than commit: after this long the hold is not a real
        // interaction, so putting focus back where it was is the safer guess.
        onTriggered: root.cancel()
    }

    GlobalShortcut {
        appid: "altswitcher"
        name: "next"
        description: "Alt+Tab window switcher: next window"
        onPressed: root.step(1)
    }

    GlobalShortcut {
        appid: "altswitcher"
        name: "prev"
        description: "Alt+Tab window switcher: previous window"
        onPressed: root.step(-1)
    }

    // Safety net for the case where the overlay never sees the Alt keyup
    // (no keyboard grab, a stuck modifier). Harmless when idle.
    GlobalShortcut {
        appid: "altswitcher"
        name: "commit"
        description: "Alt+Tab window switcher: confirm selection"
        onPressed: root.commit()
    }

    GlobalShortcut {
        appid: "altswitcher"
        name: "cancel"
        description: "Alt+Tab window switcher: dismiss"
        onPressed: root.cancel()
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

        // Do NOT name these after the Material keys they come from. A QML
        // property whose name begins with `on` followed by a capital letter
        // collides with the signal-handler syntax: `onSurface` silently
        // resolved to #000000 -- a black window title on a black card -- with
        // no warning, while `onSurfaceVariant` beside it worked fine.
        readonly property color bg: pick("surface_container", "#251d24")
        readonly property color textPrimary: pick("on_surface", "#eedee8")
        readonly property color textSecondary: pick("on_surface_variant", "#d5c1cf")
        readonly property color accent: pick("primary", "#ffaaf8")
        readonly property color stroke: pick("outline_variant", "#51424e")
    }

    // ── overlay ────────────────────────────────────────────────────────
    PanelWindow {
        id: overlay

        // Follow the focused output rather than the primary one, so the
        // switcher appears where you are looking on a multi-head setup.
        screen: {
            const m = Hyprland.focusedMonitor;
            if (m) {
                for (const s of Quickshell.screens)
                    if (s.name === m.name)
                        return s;
            }
            return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        }

        visible: root.active
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "altswitcher"
        // Exclusive is what delivers the Alt keyup to us. Without it the
        // release goes to whatever app is focused and the overlay hangs
        // open until the fallback shortcut fires.
        WlrLayershell.keyboardFocus: root.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, root.scrimOpacity)
            opacity: root.shown ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.animMs
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.cancel()
            }
        }

        FocusScope {
            id: keys
            anchors.fill: parent
            focus: true

            // Grab focus every time the overlay maps, not just on load.
            Connections {
                target: root
                function onActiveChanged() {
                    if (root.active)
                        keys.forceActiveFocus();
                }
            }

            Keys.onReleased: event => {
                // Alt_L and Alt_R both arrive as Qt.Key_Alt. Qt.Key_Meta is
                // included so a Super-based rebind keeps working unchanged.
                if (event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) {
                    root.commit();
                    event.accepted = true;
                }
            }

            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Escape:
                    root.cancel();
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    root.commit();
                    break;
                case Qt.Key_Right:
                case Qt.Key_Down:
                    root.step(1);
                    break;
                case Qt.Key_Left:
                case Qt.Key_Up:
                    root.step(-1);
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            Item {
                id: card
                anchors.centerIn: parent
                width: panel.width
                height: panel.height

                opacity: root.shown ? 1 : 0
                scale: root.shown ? 1 : 0.94
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.animMs
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on scale {
                    NumberAnimation {
                        duration: root.animMs
                        easing.type: Easing.OutCubic
                    }
                }

                Rectangle {
                    id: panel
                    radius: 22
                    color: theme.bg
                    border.width: 1
                    border.color: theme.stroke

                    readonly property int pad: 16
                    // Clamped only so the card cannot outgrow a small output.
                    readonly property int contentWidth: Math.min(root.cardWidth, Math.round((overlay.screen ? overlay.screen.width : 1920) * 0.9)) - pad * 2

                    width: contentWidth + pad * 2
                    height: content.implicitHeight + pad * 2

                    Column {
                        id: content
                        anchors.centerIn: parent
                        width: panel.contentWidth
                        spacing: 6

                        Flow {
                            id: flow
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(panel.contentWidth, root.entries.length * (root.tileWidth + root.tileGap) - root.tileGap)
                            spacing: root.tileGap

                            Repeater {
                                model: root.entries

                                delegate: Item {
                                    required property int index
                                    required property var modelData

                                    width: root.tileWidth
                                    height: root.tileHeight

                                    readonly property bool selected: index === root.index

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 16
                                        visible: parent.selected
                                        color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.18)
                                        border.width: 2
                                        border.color: theme.accent
                                    }

                                    Item {
                                        id: thumbBox
                                        anchors.centerIn: parent
                                        width: root.thumbWidth
                                        height: root.thumbHeight
                                        // Unselected entries recede slightly
                                        // so the highlight reads at a glance.
                                        opacity: parent.selected ? 1 : 0.7
                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: 90
                                            }
                                        }

                                        // Shown until the first frame lands,
                                        // and for anything that cannot be
                                        // captured.
                                        IconImage {
                                            anchors.centerIn: parent
                                            width: 64
                                            height: 64
                                            implicitSize: 64
                                            source: modelData.icon
                                            visible: !shot.hasContent
                                        }

                                        ScreencopyView {
                                            id: shot
                                            anchors.centerIn: parent
                                            // Only capture once the overlay is
                                            // actually painted, so a quick
                                            // Alt+Tab flip costs no captures.
                                            captureSource: root.shown ? modelData.wl : null
                                            live: root.shown
                                            // Fit the window's aspect ratio
                                            // inside the thumbnail box.
                                            readonly property real ar: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : root.thumbWidth / root.thumbHeight
                                            width: Math.min(root.thumbWidth, root.thumbHeight * ar)
                                            height: Math.min(root.thumbHeight, root.thumbWidth / ar)
                                            visible: hasContent
                                            layer.enabled: true
                                            layer.effect: MultiEffect {
                                                maskEnabled: true
                                                maskSource: thumbMask
                                                maskThresholdMin: 0.5
                                                maskSpreadAtMin: 1.0
                                            }
                                        }

                                        Rectangle {
                                            id: thumbMask
                                            width: shot.width
                                            height: shot.height
                                            radius: 10
                                            visible: false
                                            layer.enabled: true
                                        }

                                        IconImage {
                                            visible: shot.hasContent
                                            anchors.right: shot.right
                                            anchors.bottom: shot.bottom
                                            anchors.margins: -4
                                            width: root.badgeSize
                                            height: root.badgeSize
                                            implicitSize: root.badgeSize
                                            source: modelData.icon
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onEntered: root.index = index
                                        onClicked: {
                                            root.index = index;
                                            root.commit();
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            id: label
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            color: theme.textPrimary
                            font.pixelSize: 16
                            font.weight: Font.Medium
                            text: root.entries[root.index] ? root.entries[root.index].title : ""
                        }

                        Text {
                            id: sub
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            color: theme.textSecondary
                            font.pixelSize: 12
                            text: root.entries[root.index] ? (root.entries[root.index].appName + "  ·  Workspace " + root.entries[root.index].wsName) : ""
                        }
                    }
                }

                MultiEffect {
                    source: panel
                    anchors.fill: panel
                    shadowEnabled: true
                    shadowColor: Qt.rgba(0, 0, 0, 0.55)
                    shadowBlur: 0.7
                    shadowVerticalOffset: 6
                    z: -1
                }
            }
        }
    }
}
