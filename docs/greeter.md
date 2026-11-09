# Login screen: greetd + dms-greeter

greetd runs `/usr/local/bin/dms-greeter-launch` (see `root/etc/greetd/config.toml`)
as the `greeter` user, on VT1 (`greetd.service.d/vt1.conf` replaces getty@tty1).

| File | Role |
|---|---|
| `usr/local/bin/dms-greeter-launch` | Starts the greeter's own Hyprland with the hyprlang config `/etc/greetd/dms-hyprland.conf` (dms-greeter ≥ 2.1 writes Lua configs that Hyprland < 0.57 cannot read). Turns eDP-1 off when an external display is connected, decided from `/sys/class/drm`. Uses the patched UI only while it was built for the installed versions. `prlimit --core=1` skips apport on the greeter Hyprland's exit segfault (aquamarine#272). |
| `usr/local/libexec/greeter-monitor-watch` | Hotplug handling inside the greeter |
| `usr/local/lib/dms-greeter-auth/dms-greeter-auth-patch` | Fingerprint and password without waiting on each other: 3 s fingerprint windows, re-armed while the field is empty; typing parks at the password prompt |
| `usr/local/sbin/dms-greeter-ui-rebuild` + `etc/apt/apt.conf.d/99dms-greeter-ui-rebuild` | Rebuilds `/usr/local/share/dms-greeter-shell` (embedded UI + the auth patch) after every dpkg run. A failed patch falls back to the stock UI |
| `usr/local/libexec/greetd-skip-fprint` + `etc/pam.d/greetd` | `pam_exec` skips `pam_fprintd` for password sessions that the patched greeter flagged |
| `usr/local/bin/start-hyprland-quiet` + diverted `usr/share/wayland-sessions/hyprland.desktop` | The session sends its output to the journal (`hyprland-session`) instead of the VT, and runs `hypr-docked-sync` first. The uwsm entry is diverted to `.disabled` because uwsm is not installed |

`dms-update-check` warns when the patched UI isn't built for the installed
`dms`/`dms-greeter` versions, or when the installed launcher differs from this repo.

**Testing nested from a running session:**
`timeout 12 dms-greeter --command hyprland --cache-dir /var/cache/dms-greeter -C /etc/greetd/dms-hyprland.conf --debug`
