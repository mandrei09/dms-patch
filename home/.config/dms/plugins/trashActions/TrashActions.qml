import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services
import qs.Modals.Common

// `trash` switches the launcher to this plugin (like `ssh`, `qr`) and offers
// "Open Trash" and "Empty Trash"; words after it filter (`trash em`).
//
// Plugin items always close the launcher, so emptying asks in DMS's own
// ConfirmModal (themed like the rest of the shell; Cancel is preselected, and
// Enter, Escape or a click outside all cancel). gio handles the trash on every
// mounted drive, not just ~/.local/share/Trash.
Item {
    id: root

    property var pluginService: null
    property string trigger: "trash"

    signal itemsChanged

    readonly property string pluginId: "trashActions"

    // -1 = not counted yet
    property int itemCount: -1
    property real _countedAt: 0
    // set when "Empty Trash" was chosen: ask once the fresh count is in
    property bool _confirmPending: false

    // Same reason as sshHosts: keep launched apps out of dms.service's cgroup
    // so a DMS restart doesn't take them down.
    function scoped(argv) {
        return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--"].concat(argv);
    }

    function _what(n) {
        return n === 1 ? "1 item" : n + " items";
    }

    function _toast(msg, error) {
        if (typeof ToastService === "undefined")
            return;
        if (error)
            ToastService.showError("Trash", msg);
        else
            ToastService.showInfo("Trash", msg);
    }

    Component.onCompleted: count.running = true

    Process {
        id: count
        command: ["gio", "info", "-a", "trash::item-count", "trash:///"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = this.text.match(/trash::item-count:\s*(\d+)/);
                root.itemCount = m ? parseInt(m[1]) : -1;
                root._countedAt = Date.now();
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
                if (root._confirmPending) {
                    root._confirmPending = false;
                    root._askToEmpty();
                }
            }
        }
    }

    Process {
        id: emptier
        property int deleting: 0
        command: ["gio", "trash", "--empty"]
        onExited: code => {
            if (code === 0)
                root._toast("Trash emptied · deleted " + root._what(deleting), false);
            else
                root._toast("Could not empty the Trash", true);
            count.running = true;
        }
    }

    ConfirmModal {
        id: confirm
    }

    function _askToEmpty() {
        const n = itemCount;
        if (n === 0) {
            _toast("Trash is already empty", false);
            return;
        }
        confirm.showWithOptions({
            title: "Empty Trash?",
            message: "Permanently delete " + (n > 0 ? _what(n) : "everything") + " in the Trash? This cannot be undone.",
            confirmText: "Empty Trash",
            cancelText: "Cancel",
            danger: true,
            onConfirm: () => {
                if (emptier.running)
                    return;
                emptier.deleting = n;
                emptier.running = true;
            }
        });
    }

    function _countText() {
        if (itemCount < 0)
            return "";
        return itemCount === 0 ? "empty" : _what(itemCount);
    }

    function getItems(query) {
        if (Date.now() - _countedAt > 3000 && !count.running)
            count.running = true;

        const c = _countText();
        const items = [
            {
                name: "Open Trash",
                icon: itemCount > 0 ? "user-trash-full" : "user-trash",
                comment: "Show deleted files in Files" + (c ? " · " + c : ""),
                action: "open",
                enterLabel: "Open the Trash in Files",
                _preScored: 1000,
                categories: ["Files"]
            },
            {
                name: "Empty Trash",
                icon: "user-trash",
                comment: itemCount === 0 ? "Trash is already empty" : "Permanently delete everything in the Trash" + (c ? " · " + c : "") + " · asks first",
                action: "empty",
                enterLabel: "Empty the Trash (asks for confirmation)",
                _preScored: 999,
                categories: ["Files"]
            }
        ];
        const words = (query || "").toLowerCase().trim().split(/\s+/).filter(w => w);
        const hits = items.filter(it => words.every(w => it.name.toLowerCase().includes(w)));
        return hits.length ? hits : items;
    }

    function executeItem(item) {
        if (item?.action === "open") {
            Quickshell.execDetached(root.scoped(["nautilus", "--new-window", "trash:///"]));
        } else if (item?.action === "empty" && !emptier.running) {
            // Recount first so the dialog shows the current number; the dialog
            // opens when the count arrives, after the launcher has closed.
            _confirmPending = true;
            if (!count.running)
                count.running = true;
        }
    }
}
