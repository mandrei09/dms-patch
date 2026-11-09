# dms-patch

Local customisations for [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS) on Hyprland, Ubuntu: shell patches, launcher extensions, plugins, the login
screen, polkit/fingerprint glue, accent sync and two quickshell overlays.

Personal configuration (`settings.json`, monitors, workspace presets, Hyprland config)
is not here. It lives in the separate dotfiles repo, which this repo expects next to it
for `hyprland-session.target`.

## Install

```sh
git clone git@github.com:mandrei09/dms-patch.git ~/dms-patch
cd ~/dms-patch
./install.sh            # links home/ into $HOME, enables the user units
./install.sh --root     # copies root/ into / via pkexec (diff + confirm per file)
systemctl --user restart dms.service
./install.sh --check    # anything out of sync? (exit 1 = yes)
```

`home/` is **symlinked**, so editing an installed file edits the repo and shows up in
`git status`. `root/` is **copied**, because root must never run user-writable files.
Re-run `--root` after changing anything under `root/`. Both modes are idempotent; `-n`
does a dry run. If a target is a real file, `install.sh` moves it to
`*.bak-dms-patch-<stamp>` before linking.

Dependencies are listed in [`deps.txt`](deps.txt). `--root` sets the apt holds, and
`dms-update-check` checks that the rest is installed and marked manual.

## What's in it

### Shell patches (`home/.local/bin`)
DMS runs QML embedded in its binary, so patches cannot touch `/usr/share/quickshell/dms`.
`dms.service.d/shell-dir.conf` points `DMS_SHELL_DIR` at `~/.local/share/dms-shell`, and
`dms-shell-sync` rebuilds that tree from the binary (`dux-extract-ui`) on every start,
then runs each patch. A failing patch is logged, and that feature runs stock.

| Patch | Effect |
|---|---|
| `dms-tray-patch` | Tray collapsed by default; `hiddenTrayIds` becomes a pin list |
| `dms-launcher-patch` | Spotlight: Preview, details pane, word triggers, plugin pre-scoring, extra menu actions, learned ranking, file-type icons (assets in `home/.local/share/dms-launcher-patch`) |
| `dms-procs-patch` | Process list fetches all processes, not the top 100 by CPU |
| `dms-workspace-dedup-patch` | No duplicate workspaces after the boot-time monitor race |
| `dms-notif-icon-patch` | Notification icons |
| `dms-lock-notif-filter-patch` | Lock screen shows only critical notifications and those from apps in `~/.config/dms/lock-notifications-allow` |
| `dms-hyprconf-input-patch` | Mouse/touchpad settings written as hyprlang (`hypr/dms/input.conf`) |
| `dms-polkit-fprint-skip-patch` | Typing in the polkit dialog skips the fingerprint step ([docs](docs/polkit-fprint-skip.md)) |

Helpers: `dms-launcher-action`, `dms-file-details`, `dms-app-details` (launcher
actions and details), `dsearch-ignore-sync` (keeps build folders out of the dsearch
index), `dms-update-check` + `dms-update-guard.{path,timer}` (one notification when
an update breaks something), `dms-upgrade` + `dms-upgrade-root` (test the patches
against new held packages, then install them), `dms-greeter-launch-check`.

### Launcher plugins (`home/.config/dms/plugins`)
`workspacePresets` (`wp`), `trashActions`, `sshHosts`, `vscodeRecent`, `rgSearch`,
`dockerLauncher`, `guidGenerator`, and the dev tools `devB64`/`devJwt`/`devTs`/`devUrl`
(shared code in `_devtools-common`). `patches/dockerManager.patch` adapts the
third-party dockerManager plugin to Docker 29 event fields and DMS 2.0 imports;
`install.sh` applies it when the plugin is present.

### Login screen and polkit (`root/`)
greetd + patched dms-greeter: see [docs/greeter.md](docs/greeter.md).
Polkit fingerprint skip: see [docs/polkit-fprint-skip.md](docs/polkit-fprint-skip.md).

### Accent sync
DMS is the accent source. `hypr-accent.path` watches it, `accent-resolve.py` resolves
the palette into `~/.cache/accent/palette.json`, and `hypr-accent` fans it out to
Hyprland and the `*-accent` scripts (ghostty, kitty, gtk, tmux, starship, satty, yazi,
pulsar).

### Overlays (`home/.config/quickshell`)
- `altswitcher` is the Alt+Tab switcher with live thumbnails.
- `snip` is the Super+Shift+S snipping overlay, with satty editing and OCR (`snip-done`).

## Adding something new
1. Put the file under `home/` or `root/` at the path it should have once installed.
2. Patch scripts: add them to the loop in `dms-shell-sync`. Files they touch: add
   them to `OWN_FILES_RE` in `dms-update-check`. New packages: add them to `deps.txt`.
3. `./install.sh` (and `--root` if needed), then `./install.sh --check`.
4. Commit.
