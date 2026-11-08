import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// `trash` switches the launcher to this plugin (like `ssh`, `qr`) and offers
// "Open Trash" and "Empty Trash"; words after it filter (`trash em`).
//
// Plugin items always close the launcher, so the confirmation for emptying is
// a zenity dialog rather than a second launcher step. gio handles the trash on
// every mounted drive, not just ~/.local/share/Trash.
Item {
    id: root

    property var pluginService: null
    property string trigger: "trash"

    signal itemsChanged

    readonly property string pluginId: "trashActions"

    // -1 = not counted yet
    property int itemCount: -1
    property real _countedAt: 0

    // Same reason as sshHosts: keep launched apps out of dms.service's cgroup
    // so a DMS restart doesn't take them down.
    function scoped(argv) {
        return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--"].concat(argv);
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
            }
        }
    }

    // Asks first, empties only on "Empty Trash", then reports and recounts.
    Process {
        id: emptier
        command: ["sh", "-c", `
            n=$(gio info -a trash::item-count trash:/// | sed -n 's/.*item-count: *//p')
            if [ "\${n:-0}" = 0 ]; then
                notify-send -a Trash -i user-trash "Trash is already empty"
                exit 0
            fi
            if [ "$n" = 1 ]; then what="1 item"; else what="$n items"; fi
            zenity --question --title="Empty Trash" --icon=user-trash-full \\
                --text="Permanently delete $what in the Trash?\\n\\nThis cannot be undone." \\
                --ok-label="Empty Trash" --cancel-label="Cancel" --default-cancel || exit 0
            if gio trash --empty; then
                notify-send -a Trash -i user-trash "Trash emptied" "Deleted $what"
            else
                notify-send -a Trash -u critical -i dialog-error "Could not empty the Trash"
            fi
        `]
        onExited: count.running = true
    }

    function _countText() {
        if (itemCount < 0)
            return "";
        return itemCount === 0 ? "empty" : itemCount === 1 ? "1 item" : itemCount + " items";
    }

    function getItems(query) {
        if (Date.now() - _countedAt > 3000 && !count.running)
            count.running = true;

        const c = _countText();
        const items = [
            {
                name: "Open Trash",
                icon: "material:delete",
                comment: "Show deleted files in Files" + (c ? " · " + c : ""),
                action: "open",
                enterLabel: "Open the Trash in Files",
                _preScored: 1000,
                categories: ["Files"]
            },
            {
                name: "Empty Trash",
                icon: "material:delete_forever",
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
        if (item?.action === "open")
            Quickshell.execDetached(root.scoped(["nautilus", "--new-window", "trash:///"]));
        else if (item?.action === "empty" && !emptier.running)
            emptier.running = true;
    }
}
