// ═══════════════════════════════════════════════════════════════════════
//  langswitcher — a Windows-style Super+Space input-language flyout
//
//  Super+Space is a HYPRLAND bind (`global, langswitcher:next`). Each press
//  switches every keyboard to the next layout at once (as Windows does --
//  no commit-on-release), and this overlay shows the list with the new
//  layout highlighted, then fades out once the presses stop.
//
//  Unlike altswitcher this never takes keyboard focus: there is nothing
//  to confirm, and grabbing focus would close menus or popups in the app
//  you are typing into. The flyout is click-through for the same reason.
//
//  The layout list comes from layouts.py (kb_layout + the xkb registry),
//  re-read on Hyprland config reloads. The active index is re-read from
//  `hyprctl devices` on every `activelayout` event, so switching from the
//  DMS bar widget keeps this in step too (without showing the flyout).
//
//  Colours are read live from DankMaterialShell's palette, as in
//  altswitcher.
// ═══════════════════════════════════════════════════════════════════════
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ── tunables ───────────────────────────────────────────────────────
    // Windows hides the flyout when Win is released. Without a keyboard
    // grab we cannot see that keyup, so a short idle timeout stands in.
    readonly property int hideMs: 900
    readonly property int animMs: 120
    readonly property int cardWidth: 380
    // Clear of the DMS bar, which sits on the top edge.
    readonly property int marginTop: 70
    readonly property int marginRight: 16

    // ── state ──────────────────────────────────────────────────────────
    property var layouts: []
    property int activeIndex: 0
    property bool shown: false

    function next() {
        if (root.layouts.length < 2)
            return;
        // Predict the result so the flyout paints on the same frame as the
        // keypress; the devices query below corrects it if we were wrong.
        root.activeIndex = (root.activeIndex + 1) % root.layouts.length;
        switchProc.running = true;
        root.shown = true;
        hideTimer.restart();
    }

    GlobalShortcut {
        appid: "langswitcher"
        name: "next"
        description: "Switch to the next keyboard layout and show the list"
        onPressed: root.next()
    }

    Timer {
        id: hideTimer
        interval: root.hideMs
        onTriggered: root.shown = false
    }

    Process {
        id: layoutsProc
        command: [Quickshell.shellDir + "/layouts.py"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.layouts = JSON.parse(text);
                } catch (e) {
                    console.warn("langswitcher: bad layouts.py output:", text);
                }
                activeProc.running = true;
            }
        }
    }

    Process {
        id: switchProc
        command: ["hyprctl", "switchxkblayout", "all", "next"]
        onExited: activeProc.running = true
    }

    Process {
        id: activeProc
        command: ["hyprctl", "-j", "devices"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const kbs = JSON.parse(text).keyboards || [];
                    const kb = kbs.find(k => k.main) || kbs[0];
                    if (kb && kb.active_layout_index !== undefined)
                        root.activeIndex = kb.active_layout_index;
                } catch (e) {}
            }
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                layoutsProc.running = true;
            else if (event.name === "activelayout" && !switchProc.running)
                activeProc.running = true;
        }
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

        readonly property string mode: {
            const txt = sessionFile.text();
            try {
                return txt && JSON.parse(txt).isLightMode ? "light" : "dark";
            } catch (e) {
                return "dark";
            }
        }

        readonly property var palette: {
            const txt = paletteFile.text();
            try {
                const j = txt ? JSON.parse(txt) : null;
                return j && j.colors ? j.colors[theme.mode] : null;
            } catch (e) {
                return null;
            }
        }

        function pick(key, fallback) {
            const p = theme.palette;
            return (p && p[key]) ? p[key] : fallback;
        }

        // Not `onSurface`: see the note in altswitcher -- an `on`+Capital
        // property name silently resolves to black.
        readonly property color bg: pick("surface_container", "#251d24")
        readonly property color textPrimary: pick("on_surface", "#eedee8")
        readonly property color textSecondary: pick("on_surface_variant", "#d5c1cf")
        readonly property color accent: pick("primary", "#ffaaf8")
        readonly property color accentText: pick("on_primary", "#5a0058")
        readonly property color stroke: pick("outline_variant", "#51424e")
    }

    // ── flyout ─────────────────────────────────────────────────────────
    PanelWindow {
        id: flyout

        screen: {
            const m = Hyprland.focusedMonitor;
            if (m) {
                for (const s of Quickshell.screens)
                    if (s.name === m.name)
                        return s;
            }
            return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        }

        // Stay mapped through the fade-out.
        visible: root.shown || card.opacity > 0
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "langswitcher"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // Click-through: an empty input region.
        mask: Region {}

        anchors {
            top: true
            right: true
        }
        margins {
            top: root.marginTop
            right: root.marginRight
        }
        implicitWidth: root.cardWidth
        implicitHeight: card.implicitHeight

        Rectangle {
            id: card
            width: parent.width
            implicitHeight: column.implicitHeight + 24
            radius: 22
            color: theme.bg
            border.width: 1
            border.color: theme.stroke
            opacity: root.shown ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic }
            }

            Column {
                id: column
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                Repeater {
                    model: root.layouts

                    Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool current: index === root.activeIndex

                        width: column.width
                        height: 56
                        radius: 14
                        color: current ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.18) : "transparent"
                        border.width: current ? 2 : 0
                        border.color: theme.accent

                        Rectangle {
                            id: badge
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 52
                            height: 34
                            radius: 9
                            color: row.current ? theme.accent : "transparent"
                            border.width: row.current ? 0 : 1
                            border.color: theme.stroke

                            Text {
                                anchors.centerIn: parent
                                text: row.modelData.code
                                color: row.current ? theme.accentText : theme.textSecondary
                                font.pixelSize: 15
                                font.weight: Font.Bold
                                font.letterSpacing: 0.5
                            }
                        }

                        Text {
                            anchors.left: badge.right
                            anchors.leftMargin: 14
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.name
                            elide: Text.ElideRight
                            color: row.current ? theme.textPrimary : theme.textSecondary
                            font.pixelSize: 16
                            font.weight: row.current ? Font.Medium : Font.Normal
                        }
                    }
                }
            }
        }
    }
}
