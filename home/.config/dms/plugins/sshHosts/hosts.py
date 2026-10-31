#!/usr/bin/python3
"""Print the SSH hosts from ~/.ssh/config as JSON.

Host aliases come from `Host` lines (following `Include`, globs and all);
wildcard patterns and negations are skipped since you can't connect to them.
Each alias is then resolved with `ssh -G`, so hostname/user/port are exactly
what `ssh ALIAS` would use, including Match blocks and defaults.
Git forges (github.com and friends, or User git) are marked so the launcher
can leave them out -- nobody opens a shell on them.
"""
import glob
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
SSH_DIR = os.path.join(HOME, ".ssh")
FORGES = re.compile(r"(^|\.)(github\.com|gitlab\.com|bitbucket\.org|ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com|codeberg\.org)$", re.I)


def config_files(path, seen):
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(SSH_DIR, path)
    for f in sorted(glob.glob(path)):
        if f in seen or not os.path.isfile(f):
            continue
        seen.add(f)
        yield f
        try:
            lines = open(f, errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines:
            m = re.match(r"\s*Include\s+(.+)", line, re.I)
            if m:
                for inc in m.group(1).split():
                    yield from config_files(inc, seen)


aliases = []
for f in config_files(os.path.join(SSH_DIR, "config"), set()):
    for line in open(f, errors="replace").read().splitlines():
        m = re.match(r"\s*Host\s+(.+)", line, re.I)
        if not m:
            continue
        for a in m.group(1).split():
            if any(c in a for c in "*?!") or a in aliases:
                continue
            aliases.append(a)

out = []
for a in aliases:
    info = {"alias": a, "hostname": a, "user": "", "port": "22"}
    try:
        g = subprocess.run(["ssh", "-G", a], capture_output=True, text=True, timeout=3).stdout
        for line in g.splitlines():
            k, _, v = line.partition(" ")
            if k in ("hostname", "user", "port"):
                info[k] = v
    except (OSError, subprocess.SubprocessError):
        pass
    info["forge"] = bool(FORGES.search(info["hostname"]) or info["user"] == "git")
    out.append(info)

json.dump(out, sys.stdout)
