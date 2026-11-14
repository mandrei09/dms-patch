# dms-patch

Local customisations for [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS, now "Dux") on Hyprland: shell patches, launcher extensions, plugins, a patched
login screen, polkit/fingerprint glue, accent sync and two quickshell overlays.
Works on **Ubuntu/Debian** (DMS from `ppa:avengemedia/danklinux`) and **Arch**
(`dux-shell` from extra, greeter and dsearch from the AUR).

Personal configuration (DMS `settings.json`, monitors, presets, the Hyprland config)
is **not** here; it lives in a separate dotfiles repo. The user units here hook into
that repo's `hyprland-session.target`.

## Quick start

```sh
git clone https://github.com/mandrei09/dms-patch.git ~/.local/src/dms-patch
cd ~/.local/src/dms-patch
./install.sh --deps     # packages from deps/<distro>.txt (apt, or pacman + paru/yay)
./install.sh            # link home/ into $HOME
./install.sh --root     # copy root/ (+ root.<distro>/) into / via pkexec, diff + confirm per file
systemctl --user restart dms.service
./install.sh --check    # anything out of sync? exit 1 = yes
```

On a fresh Arch machine, the dotfiles repo's `bootstrap/arch.sh` runs all of this
for you.

| Mode | Does |
|---|---|
| `--deps` | Installs what is missing from `deps/debian.txt` or `deps/arch.txt`. AUR entries need paru or yay; it tells you how to get paru if neither is present |
| *(default)* `--user` | Symlinks `home/` into `$HOME`. Editing an installed file edits the repo, so `git status` shows every change. Real files in the way are moved to `*.bak-dms-patch-<stamp>` |
| `--root` | Copies the root files: root must never run user-writable files. It also marks the deps explicit/manual so autoremove keeps them, and on Debian sets the apt holds and diversions. Shows a diff before each replacement; `-y` accepts all |
| `--check` | Reports missing or foreign links, unlisted units, root files that differ, missing diversions. `dms-update-check` runs it too |
| `--uninstall` | Removes the `$HOME` links into this repo (root files stay) |

`-n` makes `--user`, `--root` and `--deps` a dry run. The distro comes from
`/etc/os-release`; set `DMS_PATCH_DISTRO=arch|debian` to override it.

## Layout

```
home/                 mirrors $HOME, symlinked
root/                 mirrors /, copied: files for both distros
root.debian/          Debian/Ubuntu only: PAM (Debian syntax), apt hook, diverted hyprland.desktop
root.arch/            Arch only: PAM (system-auth syntax), pacman hook, hyprland-dms.desktop
deps/debian.txt       packages (+ "hold" = kept on apt-mark hold)
deps/arch.txt         packages (+ "aur")
lib/pkg.sh            dpkg/pacman helpers for the user-side scripts
patches/              patches for third-party plugins (dockerManager)
docs/                 greeter.md, polkit-fprint-skip.md
```

Units are switched on by tracked `<target>.d/dms-patch.conf` drop-ins (`Wants=`),
not by `.wants` links. The `.wants` folders belong to the dotfiles repo, and both
repos share `~/.config/systemd/user`.

## What's in it

### Shell patches
DMS runs QML embedded in its binary, so editing `/usr/share/quickshell/dms` changes
nothing, and Arch doesn't even ship that folder. `dms.service.d/shell-dir.conf`
points `DMS_SHELL_DIR` at `~/.local/share/dms-shell`, and `dms-shell-sync` rebuilds
that tree on every start. It extracts the tree from the binary with `dux-extract-ui`
and then runs each patch on a scratch copy. A failing patch is logged, and that
feature runs stock.

| Patch | Effect |
|---|---|
| `dms-tray-patch` | Tray collapsed by default; `hiddenTrayIds` becomes a pin list |
| `dms-launcher-patch` | Spotlight: Preview, details pane, word triggers, plugin pre-scoring, extra menu actions (incl. Uninstall for apt/pacman/Flatpak/Snap/Homebrew/AppImage), learned ranking, file-type icons. Assets in `home/.local/share/dms-launcher-patch` |
| `dms-procs-patch` | Process list fetches all processes, not the top 100 by CPU |
| `dms-workspace-dedup-patch` | No duplicate workspaces after the boot-time monitor race |
| `dms-notif-icon-patch` | Notification icons |
| `dms-lock-notif-filter-patch` | Lock screen shows only critical notifications and those from apps in `~/.config/dms/lock-notifications-allow` |
| `dms-hyprconf-input-patch` | Mouse/touchpad settings written as hyprlang `hypr/dms/input.conf`. Only needed while Hyprland < 0.57 (Ubuntu); 0.57+ reads DMS's Lua directly |
| `dms-polkit-fprint-skip-patch` | Typing in the polkit dialog skips the fingerprint step ([docs](docs/polkit-fprint-skip.md)) |
| `dms-hypr-legacy-dispatch-patch` | Workspace/window clicks work on a hyprlang (pre-Lua, <0.55) Hyprland: DMS 2.1 only sends Lua dispatches |

**Helpers:**
- `dms-launcher-action`, `dms-file-details`, `dms-app-details`: launcher actions and the details pane.
- `dsearch-ignore-sync`: keeps git-ignored build folders out of the dsearch index.
- `dms-update-check` with `dms-update-guard.{path,timer}`: one critical notification
  when a package change breaks something. It dry-runs every patch after each apt or
  pacman transaction.
- `dms-upgrade` and `dms-upgrade-root` (Debian): test the patches against new held
  packages, then install them.
- `dms-greeter-launch-check`.

### Launcher plugins (`home/.config/dms/plugins`)
- `workspacePresets` (`wp`), `trashActions`, `sshHosts`, `vscodeRecent`, `rgSearch`,
  `dockerLauncher`, `guidGenerator`.
- Dev tools `devB64`, `devJwt`, `devTs` and `devUrl`, with shared code in `_devtools-common`.
- `patches/dockerManager.patch` adapts the third-party dockerManager plugin to
  Docker 29 events and DMS 2.0 imports.

### Login screen and polkit
greetd + patched dms-greeter, fingerprint and password without waiting on each
other: see [docs/greeter.md](docs/greeter.md). Typing skips the fingerprint step
in polkit prompts: see [docs/polkit-fprint-skip.md](docs/polkit-fprint-skip.md).
On Arch, pick the **Hyprland (DMS)** session once at the login screen.

### Accent sync
DMS is the accent source. `hypr-accent.path` watches it, `accent-resolve.py` writes
`~/.cache/accent/palette.json`, and `hypr-accent` fans it out to Hyprland and the
`*-accent` scripts (ghostty, kitty, gtk, tmux, starship, satty, yazi, pulsar,
gnome: nearest GNOME `accent-color` plus Yaru icon/GTK theme variant,
launcher-icons: the DMS launcher's generic folder/file icons).

### Overlays (`home/.config/quickshell`)
- `altswitcher`: Alt+Tab with live thumbnails.
- `snip`: Super+Shift+S snipping overlay with satty editing and OCR (`snip-done`).

## Distro differences

| | Ubuntu/Debian | Arch |
|---|---|---|
| DMS packages | `dms`, `dms-greeter`, `danksearch`, `dgop`, `quickshell` (PPA) | `dux-shell`, `dux-gop`, `quickshell` (extra); `dux-greeter-bin`, `dux-search-bin` (AUR) |
| Updates | held; `dms-upgrade` tests the patches first | no holds; the guard dry-runs the patches after every pacman run |
| Greeter UI rebuild | apt `DPkg::Post-Invoke` hook | pacman hook on `usr/bin/dms*` |
| Session file | package `hyprland.desktop` diverted | own `hyprland-dms.desktop` (pacman doesn't own it) |
| PAM | `@include common-*` | `include system-auth` / `system-local-login` |
| Hyprland | 0.53: hyprlang, greeter compositor started by `dms-greeter-launch` | ≥ 0.57: Lua only, launcher hands off to dms-greeter |

## Adding something

1. Put the file under `home/`, `root/` or `root.<distro>/` at the path it should
   have once installed.
2. Patch scripts: add them to the loop in `dms-shell-sync`. Files they touch: add
   them to `OWN_FILES_RE` in `dms-update-check`. Packages: add them to **both**
   `deps/` lists. New units: add them to `<target>.d/dms-patch.conf`; `--check`
   flags any you forget.
3. `./install.sh` (plus `--root` if needed), then `./install.sh --check`.
4. Commit and push. The repo is public, so keep hostnames, emails and tokens out of it.
