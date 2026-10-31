#!/usr/bin/python3 -I
"""Print Hyprland's configured keyboard layouts as JSON for the overlay.

[{"code": "EN", "name": "English (US)"}, ...] in kb_layout order, with the
human names taken from the xkb registry so they match what the DMS bar and
GNOME Settings show. Run once at startup and again on every config reload,
never per keypress -- the overlay must not wait on Python to appear.
"""
import json
import subprocess
import xml.etree.ElementTree as ET


def option(name):
    out = subprocess.run(["hyprctl", "-j", "getoption", name],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out).get("str", "")
    except ValueError:
        return ""


def split(value):
    # Hyprland reports an unset string option as "[[EMPTY]]".
    if value == "[[EMPTY]]":
        value = ""
    return [p.strip() for p in value.split(",")]


layouts = split(option("input:kb_layout"))
variants = split(option("input:kb_variant"))
variants += [""] * (len(layouts) - len(variants))

registry = {}
root = ET.parse("/usr/share/X11/xkb/rules/evdev.xml").getroot()
for layout in root.iter("layout"):
    item = layout.find("configItem")
    lname = item.findtext("name")
    short = item.findtext("shortDescription") or lname
    registry[(lname, "")] = (short, item.findtext("description"))
    for variant in layout.iter("variant"):
        vitem = variant.find("configItem")
        registry[(lname, vitem.findtext("name"))] = (
            vitem.findtext("shortDescription") or short,
            vitem.findtext("description"))

result = []
for lay, var in zip(layouts, variants):
    if not lay:
        continue
    short, desc = registry.get((lay, var), (lay, f"{lay} {var}".strip()))
    result.append({"code": short.upper(), "name": desc})

print(json.dumps(result))
