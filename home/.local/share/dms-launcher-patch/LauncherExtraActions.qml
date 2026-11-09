import QtQuick
import Quickshell
import qs.Common
import qs.Services

// Extra entries for the launcher's action menu (right-click / Menu / Right
// arrow), mounted inside LauncherContextMenu.qml by dms-launcher-patch and
// copied into the shell tree on every run -- edit THIS file, not the copy.
// Shared by spotlight and the full (Super) launcher, which use the same menu.
//
// Entries carry `extra: {kind, ...}` and an `action` that hands it to
// activate(). Anything that needs the filesystem, Gio or hyprctl comes from
// ~/.local/bin/dms-launcher-action: `menu ...` (JSON, fetched when the menu
// opens; the menu grows a moment later) and `do ACTION ...`.
//
// Submenus (Open with…, Focus window…, Launch on workspace…) drill down in
// place: the menu's items are swapped for the submenu's plus a Back entry,
// and Left / Escape go back up instead of closing.
QtObject {
    id: extra

    property var menu: null
    property var info: null
    property var subMenu: null
    property string _want: ""

    readonly property var _archiveExt: [".zip", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".tzst", ".7z", ".rar", ".gz", ".xz", ".bz2", ".zst", ".jar", ".deb", ".rpm", ".iso"]

    function fetch(item) {
        info = null;
        subMenu = null;
        let cmd = null;
        if (item?.type === "file" && item.data?.path)
            cmd = ["dms-launcher-action", "menu", "file", item.data.path];
        else if (item?.type === "app" && !item.isCore && item.data)
            cmd = ["dms-launcher-action", "menu", "app", String(item.data.id || ""), String(item.data.startupClass || ""), String(item.data.execString || "")];
        if (!cmd) {
            _want = "";
            return;
        }
        const key = cmd.join("\u0001");
        _want = key;
        Proc.runCommand("launcher-extra-actions", cmd, function (stdout) {
            if (extra._want !== key)
                return;
            try {
                extra.info = JSON.parse(String(stdout || "{}"));
            } catch (e) {
                extra.info = {};
            }
        }, 1, 4000);
    }

    function _matches(item) {
        return !!info && (info.path === undefined || info.path === item?.data?.path);
    }

    // DMS 2.0's DContextMenu runs `action` and then hides unless `keepOpen`;
    // drilling into or out of a submenu must leave the menu up.
    function _entry(icon, text, x) {
        return {
            type: "item",
            icon: icon,
            text: text,
            extra: x,
            keepOpen: x.kind === "submenu" || x.kind === "back",
            action: () => extra.activate(x)
        };
    }

    function _do(action, args) {
        return { kind: "do", action: action, args: args };
    }

    function _sep(items) {
        if (items.length && items[items.length - 1].type !== "separator")
            items.push({ type: "separator" });
    }

    function _base(path) {
        return path.substring(path.lastIndexOf("/") + 1);
    }

    // ── files and folders: appended after the stock actions ─────────────
    function fileItems(item) {
        const items = [{ type: "separator" }];
        const path = item?.data?.path || "";
        if (!path)
            return [];
        const isDir = !!item.data.is_dir;
        const i = _matches(item) ? info : null;

        items.push(_entry("find_in_page", "Show in Files", _do("show-in-files", [path])));
        items.push(_entry("code", "Open in VS Code", _do("vscode", [path])));
        // "Neovim" comes from the item's own actions (patch 20), which feed both
        // this menu and the Tab bar -- adding it here too listed it twice.
        if (isDir) {
            items.push(_entry("splitscreen", "Open in tmux", _do("tmux", [path])));
        } else if (i?.openWith?.length) {
            const sub = i.openWith.map(a => Object.assign(_entry(a.default ? "check" : "apps", a.name + (a.default ? "  (default)" : ""), _do("open-with", [a.id, path])), { appIconValue: resolveAppIcon("desktop:" + a.id) }));
            items.push(_entry("apps", "Open with…", { kind: "submenu", title: "Open with", items: sub }));
        }

        _sep(items);
        items.push(_entry("text_fields", "Copy name", { kind: "copy", text: _base(path) }));
        items.push(_entry("file_copy", isDir ? "Copy folder" : "Copy file", _do("copy-file", [path])));
        if (!isDir && i?.text)
            items.push(_entry("content_paste_go", "Copy contents", _do("copy-contents", [path])));

        if (isDir && i?.git?.web) {
            _sep(items);
            const web = i.git.web;
            const host = web.indexOf("github.com") >= 0 ? "GitHub" : web.indexOf("gitlab") >= 0 ? "GitLab" : web.indexOf("dev.azure.com") >= 0 ? "Azure DevOps" : web.indexOf("bitbucket") >= 0 ? "Bitbucket" : "";
            items.push(_entry("open_in_browser", host ? "Open on " + host : "Open remote in browser", _do("git-web", [path])));
            items.push(_entry("link", "Copy remote URL", { kind: "copy", text: i.git.remote }));
        }

        _sep(items);
        const low = path.toLowerCase();
        if (!isDir && _archiveExt.some(e => low.endsWith(e)))
            items.push(_entry("unarchive", "Extract here", _do("extract", [path])));
        if (!isDir)
            items.push(_entry("delete", "Move to Trash", _do("trash", [path])));
        if (items[items.length - 1].type === "separator")
            items.pop();
        return items;
    }

    // ── apps: running-window controls + entry/command helpers ──────────
    function appendAppItems(items, item) {
        const d = item?.data;
        if (!d)
            return;
        const wins = info?.windows || [];
        if (wins.length) {
            _sep(items);
            if (wins.length === 1) {
                items.push(_entry("pip", "Focus window", _do("focus", [wins[0].address])));
            } else {
                const sub = wins.map(w => Object.assign(_entry("pip", (w.title || "Untitled") + "  ·  ws " + w.workspace, _do("focus", [w.address])), { appIconValue: resolveAppIcon("@app", item) }));
                items.push(_entry("pip", "Focus window… (" + wins.length + ")", { kind: "submenu", title: "Focus window", items: sub }));
            }
            const args = [String(d.id || ""), String(d.startupClass || ""), String(d.execString || "")];
            items.push(_entry("close", wins.length === 1 ? "Quit" : "Quit (" + wins.length + " windows)", _do("quit", args)));
            items.push(_entry("dangerous", "Force quit" + (info.processes ? " (" + info.processes + " processes)" : ""), _do("force-quit", args)));
        }
        _sep(items);
        if (info?.desktop)
            items.push(_entry("edit_document", "Open .desktop file", _do("edit", [info.desktop])));
        if (d.execString)
            items.push(_entry("content_copy", "Copy launch command", { kind: "copy", text: String(d.execString) }));
        // One Uninstall for every install source (apt, Flatpak, Snap,
        // Homebrew, AppImage, /opt, home folder, web apps). The plan comes
        // from `dms-launcher-action uninstall-plan` and is confirmed in DMS's
        // own dialog (patch 24) before anything is removed.
        const un = _entry("delete_forever", "Uninstall…", { kind: "uninstall", id: String(d.id || ""), name: String(item?.name || d.name || "") });
        un.isDestructive = true;
        items.push(un);
    }

    function appendLaunchItems(items, item) {
        const sub = (info?.workspaces || []).map(w => _entry("workspaces", "Workspace " + w.name + (w.windows ? "  ·  " + w.windows + (w.windows === 1 ? " window" : " windows") : ""), { kind: "launchOnWs", ws: String(w.id) }));
        sub.push(_entry("add", "New empty workspace", { kind: "launchOnWs", ws: "empty" }));
        items.push(_entry("workspaces", "Launch on workspace…", { kind: "submenu", title: "Launch on workspace", items: sub }));
    }

    // ── app icons for actions that open a specific app ──────────────────
    // spec: "@app" (the result's own icon), "desktop:<id>", an absolute
    // path, or a theme icon name; "a|b|c" = first that resolves. Returns an
    // AppIconRenderer value ("svg:/path" for files, theme name otherwise).
    readonly property string _iconDir: (Quickshell.env("HOME") || "") + "/.local/share/dms-launcher-patch/file-icons/"
    function resolveAppIcon(spec, item) {
        const alts = String(spec || "").split("|");
        for (const a of alts) {
            let v = "";
            if (a === "@app")
                v = (item ?? menu?.item)?.icon || "";
            else if (a.startsWith("desktop:"))
                v = DesktopEntries.heuristicLookup(a.substring(8).replace(/\.desktop$/, ""))?.icon || "";
            else if (a.startsWith("fileicon:"))
                v = _iconDir + a.substring(9);
            else
                v = a;
            if (!v)
                continue;
            return v.startsWith("/") ? "svg:" + v : v;
        }
        return "";
    }

    // ── submenu drill-down ──────────────────────────────────────────────
    function subMenuItems() {
        return [_entry("arrow_back", subMenu.title, { kind: "back" }), { type: "separator" }].concat(subMenu.items);
    }

    function back() {
        subMenu = null;
        menu.selectedMenuIndex = 0;
        menu.ensureSelectedVisible();
    }

    // Right arrow on a submenu entry opens it; anything else is not ours.
    function openSelectedSubmenu() {
        const m = menu.menuItems;
        let n = 0;
        for (let k = 0; k < m.length; k++) {
            if (m[k].type !== "item")
                continue;
            if (n++ === menu.selectedMenuIndex) {
                if (m[k].extra?.kind === "submenu") {
                    activate(m[k].extra);
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    function activate(x) {
        if (!x || !menu)
            return;
        if (x.kind === "submenu") {
            subMenu = { title: x.title, items: x.items };
            menu.keyboardNavigation = true;
            menu.selectedMenuIndex = 0;
            menu.ensureSelectedVisible();
            return;
        }
        if (x.kind === "back") {
            back();
            return;
        }
        if (x.kind === "copy") {
            menu.controller?.copyToClipboard(x.text);
        } else if (x.kind === "do") {
            Quickshell.execDetached(["dms-launcher-action", "do", x.action].concat(x.args || []));
        } else if (x.kind === "uninstall") {
            const appId = x.id, appName = x.name;
            Proc.runCommand("launcher-uninstall-plan", ["dms-launcher-action", "uninstall-plan", appId], function (stdout) {
                let plan = null;
                try {
                    plan = JSON.parse(String(stdout || "{}"));
                } catch (e) {
                    plan = { error: "Could not work out how it was installed." };
                }
                if (plan.error || !plan.steps?.length) {
                    ToastService.showError("Can't uninstall " + appName, plan.error || "Nothing to remove.");
                    return;
                }
                AppSearchService.requestUninstallAny(appId, appName, plan);
            }, 1, 25000);
        } else if (x.kind === "launchOnWs") {
            // Switch first, then launch through DMS as usual -- the window
            // opens on whatever workspace is active when it maps.
            const entry = menu.desktopEntry;
            Proc.runCommand("launcher-extra-ws", ["dms-launcher-action", "do", "workspace", x.ws], function () {
                if (!entry)
                    return;
                SessionService.launchDesktopEntry(entry);
                AppUsageHistoryData.addAppUsage(entry);
            }, 1, 3000);
        }
        menu.controller?.itemExecuted();
        menu.hide();
    }
}
