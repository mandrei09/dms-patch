#!/usr/bin/python3
"""Print VS Code's recently used folders/workspaces as JSON, newest first.

VS Code keeps one directory per opened folder under User/workspaceStorage,
holding a workspace.json that names the folder; the directory is touched
whenever that folder is in use, so its mtime is a reliable "last used". This
is used instead of `history.recentlyOpenedPathsList` (absent on this install)
or storage.json's `lastKnownMenubarData` (only written with the native menu
bar). Profile names come from storage.json's profileAssociations.
"""
import json
import os
import sys
from urllib.parse import unquote, urlparse

base = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.config/Code")
wsdir = os.path.join(base, "User", "workspaceStorage")

profiles = {}
names = {}
try:
    with open(os.path.join(base, "User", "globalStorage", "storage.json")) as f:
        st = json.load(f)
    profiles = st.get("profileAssociations", {}).get("workspaces", {})
    names = {p.get("location"): p.get("name") for p in st.get("userDataProfiles", [])}
except (OSError, ValueError):
    pass

out = []
seen = set()
try:
    entries = os.listdir(wsdir)
except OSError:
    entries = []
for d in entries:
    p = os.path.join(wsdir, d)
    try:
        with open(os.path.join(p, "workspace.json")) as f:
            ws = json.load(f)
        mtime = os.stat(p).st_mtime
    except (OSError, ValueError):
        continue
    uri = ws.get("folder") or ws.get("workspace")
    if not uri or uri in seen:
        continue
    seen.add(uri)
    u = urlparse(uri)
    local = u.scheme == "file"
    path = unquote(u.path)
    if local and not os.path.exists(path):
        continue
    remote = "" if local else unquote(u.netloc).replace("ssh-remote+", "ssh: ")
    prof = profiles.get(uri, "")
    prof = "" if prof in ("", "__default__profile__") else names.get(prof, prof)
    out.append({
        "uri": uri,
        "kind": "workspace" if "workspace" in ws else "folder",
        "name": os.path.basename(path.rstrip("/")) or path,
        "path": path,
        "remote": remote,
        "profile": prof,
        "mtime": mtime,
    })

out.sort(key=lambda e: -e["mtime"])
json.dump(out, sys.stdout)
