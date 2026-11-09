#!/usr/bin/env python3
"""Workspace presets for Hyprland: lay out a set of apps across workspaces.

    wp.py list          JSON of the presets (for the DMS `wp` launcher plugin)
    wp.py apply NAME    lay preset NAME out

Presets live in ~/.config/dms/workspace-presets.json. Each app
has a `cmd` and a `class` regex (plus an optional `title` regex), matched
case-insensitively against `hyprctl clients`.

Workspaces are filled in order: switch to the workspace, then bring in its
apps one at a time (an already-open matching window is moved in, a missing
one is launched there and waited for), grouping them as they arrive, then
move on. Focus returns to where it was at the end.

New windows are found by polling for an unseen address that matches, NOT by
pid: VS Code, Brave and Spotify hand the request to an already-running
process, so the window never belongs to the pid we spawned. Launches go through
`systemd-run --scope` so the apps don't live in the caller's cgroup (a DMS
restart would kill them otherwise).
"""

import json
import os
import re
import subprocess
import sys
import time

CONFIG = os.path.expanduser("~/.config/dms/workspace-presets.json")
DEFAULT_TIMEOUT = 20


def hypr_json(what):
    out = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True).stdout
    try:
        return json.loads(out or "null")
    except json.JSONDecodeError:
        return None


DEBUG = os.environ.get("WP_DEBUG")


def dispatch(*args):
    if DEBUG:
        with open(DEBUG, "a") as f:
            f.write(f"{time.monotonic():.2f} {' '.join(args)}\n")
    subprocess.run(["hyprctl", "dispatch", *args], capture_output=True)


def clients():
    return [c for c in hypr_json("clients") or [] if c.get("mapped", True)]


def notify(body, urgency="normal"):
    subprocess.run(["notify-send", "-a", "Workspace presets", "-u", urgency,
                    "-i", "view-grid-symbolic", "Workspace preset", body])


def load():
    with open(CONFIG) as f:
        return json.load(f).get("presets", [])


def matches(app, c):
    if not re.search(app["class"], c.get("class") or "", re.I):
        return False
    return not app.get("title") or re.search(app["title"], c.get("title") or "", re.I)


def spawn(cmd):
    # $HOME / ~ in presets, so workspace-presets.json has no per-user paths
    cmd = [os.path.expanduser(os.path.expandvars(a)) for a in cmd]
    subprocess.Popen(["systemd-run", "--user", "--scope", "--collect", "--quiet", "--", *cmd],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def wait_for_new(app, seen, claimed):
    """Poll until a window matching app appears that wasn't there before.

    Floating windows are skipped and a hit must survive a short settle: pgAdmin
    maps a splash window first, and grouping that left the real window alone.
    """
    start = time.monotonic()
    while time.monotonic() - start < app.get("timeout", DEFAULT_TIMEOUT):
        time.sleep(0.25)
        hit = next((c for c in clients() if c["address"] not in seen and c["address"] not in claimed
                    and not c.get("floating") and matches(app, c)), None)
        if not hit:
            continue
        # Settle: Electron resizes itself right after mapping, splashes vanish.
        time.sleep(0.6)
        if hit["address"] in by_addr():
            return hit["address"]
        seen.add(hit["address"])
    return None


def fill_workspace(ws, claimed, missing):
    """Switch to ws, then bring in its apps one by one, grouping as they arrive."""
    dispatch("workspace", str(ws["id"]))
    wanted_group = ws.get("group")
    addrs = []
    for app in ws["apps"]:
        current = clients()
        hit = next((c for c in current if c["address"] not in claimed
                    and not c.get("floating") and matches(app, c)), None)
        if hit:
            addr = hit["address"]
            # Moving a grouped window drags its whole group along: detach it first.
            ungroup_if_foreign(addr, ws["apps"] if wanted_group else [])
            if by_addr().get(addr, {}).get("workspace", {}).get("id") != ws["id"]:
                dispatch("movetoworkspacesilent", f"{ws['id']},address:{addr}")
        else:
            spawn(app["cmd"])
            addr = wait_for_new(app, {c["address"] for c in current}, claimed)
            if not addr:
                missing.append(app.get("name", app["cmd"][0]))
                continue
            if by_addr().get(addr, {}).get("workspace", {}).get("id") != ws["id"]:
                dispatch("movetoworkspacesilent", f"{ws['id']},address:{addr}")
        claimed.add(addr)
        addrs.append(addr)
        if wanted_group and len(addrs) > 1:
            group(addrs)


def by_addr():
    return {c["address"]: c for c in clients()}


def direction(src, dst):
    """Direction from window src towards window dst, for moveintogroup."""
    sx, sy = src["at"][0] + src["size"][0] / 2, src["at"][1] + src["size"][1] / 2
    dx, dy = dst["at"][0] + dst["size"][0] / 2, dst["at"][1] + dst["size"][1] / 2
    if abs(dx - sx) >= abs(dy - sy):
        return "r" if dx > sx else "l"
    return "d" if dy > sy else "u"


def ungroup_if_foreign(addr, apps):
    """Pull addr out of its group if any tab belongs to none of `apps`."""
    win = by_addr()
    c = win.get(addr)
    if not c or not c.get("grouped"):
        return
    if all(m in win and any(matches(a, win[m]) for a in apps) for m in c["grouped"]):
        return
    dispatch("focuswindow", "address:" + addr)
    dispatch("moveoutofgroup")


def group(addrs):
    wanted = set(addrs)
    leader = addrs[0]
    if not by_addr().get(leader, {}).get("grouped"):
        dispatch("focuswindow", "address:" + leader)
        dispatch("togglegroup")
    for addr in addrs[1:]:
        for _ in range(3):  # a neighbour in the way can take one step
            win = by_addr()
            lead, me = win.get(leader), win.get(addr)
            if not lead or not me or addr in (lead.get("grouped") or []):
                break
            dispatch("focuswindow", "address:" + addr)
            dispatch("moveintogroup", direction(me, lead))
            time.sleep(0.05)
    # Leave the group showing its first tab.
    if set(by_addr().get(leader, {}).get("grouped") or []) >= wanted:
        dispatch("focuswindow", "address:" + leader)


def apply(name):
    preset = next((p for p in load() if p["name"].lower() == name.lower()), None)
    if not preset:
        notify(f"No preset named “{name}”", "critical")
        return 1

    active = hypr_json("activewindow") or {}
    active_ws = (hypr_json("activeworkspace") or {}).get("id")

    claimed = set()
    missing = []
    for ws in preset["workspaces"]:
        fill_workspace(ws, claimed, missing)

    if active.get("address") and active["address"] in by_addr():
        dispatch("focuswindow", "address:" + active["address"])
    elif active_ws is not None:
        dispatch("workspace", str(active_ws))

    if missing:
        notify(f"{preset['name']}: no window appeared for " + ", ".join(missing), "critical")
    else:
        notify(f"{preset['name']} is ready")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        try:
            print(json.dumps(load()))
        except (OSError, json.JSONDecodeError) as e:
            print(json.dumps([{"name": "Config error", "error": str(e), "workspaces": []}]))
        return 0
    if len(argv) >= 3 and argv[1] == "apply":
        return apply(" ".join(argv[2:]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
