# dms-patch: notes for Claude sessions

- This repo is the ONLY home for custom DMS-ecosystem code: patches, launcher
  extensions, plugins, greeter/polkit root files, accent sync, quickshell overlays.
  Never leave such files loose in `~/Documents`, `~/.local/share` or `~/dotfiles`.
  Personal config (settings.json, monitors, presets, Hyprland config) stays in
  `~/dotfiles`.
- Files under `home/` are symlinked into `$HOME`, so editing `~/.local/bin/<x>` edits
  the repo. New files must be created HERE, then run `./install.sh`.
- Files under `root/` are copies. Edit them here, then run `./install.sh --root`
  (needs pkexec; ask the user to run it when no polkit agent is reachable). Never edit
  `/usr/local` or `/etc` in place.
- Supports Debian/Ubuntu AND Arch: distro-specific root files go in root.debian/ or
  root.arch/, packages in BOTH deps/ lists, package queries through lib/pkg.sh.
- After adding something, also update the `dms-shell-sync` patch loop,
  `dms-update-check` (`OWN_FILES_RE`, scan lists), `deps/*.txt` and README.md as needed.
  Run `./install.sh --check` and commit.
- The repo is PUBLIC. No hostnames, IPs, emails, tokens or private paths in files or
  commit messages. Use `$HOME`, not `/home/<user>`.
