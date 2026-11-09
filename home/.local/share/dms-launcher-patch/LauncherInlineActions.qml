pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modals.DLauncherV2.Components

// The launcher's action menu drawn IN PLACE of the results list (Tab / Right
// arrow), instead of a dropdown. Mounted by dms-launcher-patch (#22) in both
// SpotlightLauncherContent and LauncherContent, where the results list hides
// while `menu.inlineMode` is set; copied into the shell tree on every run --
// edit THIS file: ~/.local/share/dms-launcher-patch/LauncherInlineActions.qml
//
// It is only a VIEW of the LauncherContextMenu object: entries, selection,
// activation and submenu drill-down all stay there (menuItems,
// selectedMenuIndex, activate(), handleKeyHook()), so the popup (still used
// for mouse right-click) and this page can never disagree. Rows are the same
// LauncherRow result lines use, grouped like a results section; keys are DMS
// DKeycaps (1-9, 0, A-Z), as in the popup.
Item {
    id: root

    property var menu: null
    property var item: null // the result the actions belong to (for the header)

    readonly property bool active: !!menu && menu.inlineMode
    visible: active

    // Leave the page when the selection moves under it or the menu closes.
    onItemChanged: if (active && menu.item !== item)
        close()

    function close() {
        if (menu)
            menu.inlineMode = false;
    }

    // Flat entries -> rows with grouping flags. Separators split groups.
    readonly property var rows: {
        const out = [];
        const m = menu ? menu.menuItems : [];
        let idx = 0;
        let pendingBreak = false;
        for (let i = 0; i < m.length; i++) {
            const e = m[i];
            if (e.type === "separator") {
                pendingBreak = out.length > 0;
                continue;
            }
            if (!menu.isSelectable(e))
                continue;
            if (pendingBreak && out.length)
                out[out.length - 1].last = true;
            out.push({
                entry: e,
                index: idx++,
                first: pendingBreak || out.length === 0,
                last: false,
                gapBefore: pendingBreak
            });
            pendingBreak = false;
        }
        if (out.length)
            out[out.length - 1].last = true;
        return out;
    }

    // Returns true when the key was ours. Called first by the launcher's key
    // handler while the page is up.
    function handleKey(event) {
        if (!active)
            return false;
        if (menu.handleKeyHook(event)) // Right opens a submenu; Left/Esc go back up out of one
            return true;
        switch (event.key) {
        case Qt.Key_Down:
            menu.selectNext();
            return true;
        case Qt.Key_Up:
            menu.selectPrevious();
            return true;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            menu.activateSelected();
            return true;
        case Qt.Key_Escape:
        case Qt.Key_Left:
        case Qt.Key_Tab:
        case Qt.Key_Backtab:
            close();
            return true;
        case Qt.Key_Right:
            return true;
        }
        if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            const ki = menu.itemIndexForKey(String(event.text || "").toLowerCase());
            if (ki >= 0 && ki < menu.visibleItemCount) {
                menu.keyboardNavigation = true;
                menu.selectedMenuIndex = ki;
                menu.activateSelected();
                return true;
            }
        }
        // Anything else (typing, Backspace...) means "back to searching".
        close();
        return false;
    }

    // ── header, styled like a results section header ─────────────────
    Item {
        id: header

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // Same band a results section header takes (title + resultsGap), so
        // every action row sits on exactly the pixels of the result line it
        // replaces -- switching pages must not shift anything.
        height: LauncherMetrics.sectionBand

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingS
            anchors.right: hint.left
            anchors.rightMargin: Theme.spacingS
            y: (LauncherMetrics.sectionHeight - height) / 2
            spacing: Theme.spacingS

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "bolt"
                size: Theme.iconSizeSmall
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width - Theme.iconSizeSmall - Theme.spacingS)
                text: "Actions" + (root.item?.name ? "  ·  " + root.item.name : "")
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Theme.fontWeightMedium
                color: Theme.primary
                elide: Text.ElideMiddle
            }
        }

        Row {
            id: hint

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            y: (LauncherMetrics.sectionHeight - height) / 2
            spacing: Theme.spacingXS

            DKeycap {
                anchors.verticalCenter: parent.verticalCenter
                text: "Esc"
                textColor: Theme.onSurfaceVariant
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "back"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.onSurfaceVariant
            }
        }
    }

    // ── the action rows ──────────────────────────────────────────────
    Flickable {
        id: flick

        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col

            width: flick.width
            spacing: LauncherMetrics.rowGap

            Repeater {
                id: rep

                model: root.rows

                delegate: Item {
                    id: rowWrap

                    required property var modelData
                    readonly property var entry: modelData.entry

                    width: col.width
                    // No extra gap at group breaks: rows stay on the result-line
                    // grid; groups still read through their rounded ends.
                    height: actionRow.height

                    // The very row component result lines use, so icon size,
                    // fonts, padding, colours and selection match exactly.
                    // Each action is fed in as a "dmenu" row item: that type
                    // shows no type chip/source badge, and `urgent` gives the
                    // error colour used for destructive entries.
                    LauncherRow {
                        id: actionRow

                        anchors.bottom: parent.bottom
                        width: parent.width
                        // One group for the whole page, like a results section:
                        // only the first and last rows get the round ends.
                        firstInGroup: rowWrap.modelData.index === 0
                        lastInGroup: rowWrap.modelData.index === root.rows.length - 1
                        externalHighlight: false
                        showDescription: false
                        isSelected: root.menu.selectedMenuIndex === rowWrap.modelData.index
                        enabled: rowWrap.entry.enabled !== false
                        item: ({
                                id: "action:" + rowWrap.modelData.index,
                                type: "dmenu",
                                name: rowWrap.entry.text || "",
                                subtitle: "",
                                // The app's own icon when the action opens one (VS Code,
                                // Neovim, Files...), else the material glyph.
                                icon: rowWrap.entry.appIconValue || rowWrap.entry.icon || "play_arrow",
                                iconType: rowWrap.entry.appIconValue ? "image" : "material",
                                data: {
                                    urgent: !!rowWrap.entry.isDestructive
                                },
                                _hRich: false
                            })

                        onClicked: {
                            root.menu.selectedMenuIndex = rowWrap.modelData.index;
                            root.menu.activateSelected();
                        }
                        onPointerMoved: root.menu.keyboardNavigation = false

                        DKeycap {
                            anchors.right: parent.right
                            anchors.rightMargin: LauncherMetrics.rowPadding
                            anchors.verticalCenter: parent.verticalCenter
                            visible: text.length > 0
                            text: root.menu.keyLabelFor(rowWrap.modelData.index)
                            textColor: actionRow.isSelected ? actionRow.contentColor : Theme.onSurfaceVariant
                        }
                    }
                }
            }
        }
    }

    // Keep the keyboard selection on screen.
    Connections {
        target: root.menu
        function onSelectedMenuIndexChanged() {
            Qt.callLater(() => {
                const r = rep.itemAt(root.menu.selectedMenuIndex);
                if (!r)
                    return;
                if (r.y < flick.contentY)
                    flick.contentY = Math.max(0, r.y);
                else if (r.y + r.height > flick.contentY + flick.height)
                    flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), r.y + r.height - flick.height);
            });
        }
        function onMenuItemsChanged() {
            flick.contentY = 0;
        }
    }
}
