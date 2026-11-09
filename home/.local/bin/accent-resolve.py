#!/usr/bin/python3 -I
"""accent-resolve.py [--print|--json] -- the desktop accent.

The single source of truth for every *-accent script (hypr-accent,
ghostty/tmux/yazi/pulsar-accent, gtk-accent, satty-accent) and the quickshell
overlays: DankMaterialShell's live palette, ~/.cache/dms/
dms-colors.json. DMS rewrites that file whatever its theme type (dynamic
wallpaper colours, a preset, or a custom theme), so whatever is picked in DMS
Settings -> Theme & Colors is what the whole system uses.

--print  the system accent as #rrggbb (see with_accent)
--json   that mode's full Material palette as JSON
--all    both modes, shaped like dms-colors.json
--gtk    the GTK theme's accent only (seed for the gnome-accent DMS theme)

Falls back to the GTK theme's theme_selected_bg_color if DMS has never run.
Replaced Ulauncher's sync-accent.py, which went away with Ulauncher on
2026-10-18 and silently broke the whole chain.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
DMS_COLORS = HOME / ".cache/dms/dms-colors.json"
DMS_SESSION = HOME / ".local/state/dms/session.json"
DMS_SETTINGS = HOME / ".config/dms/settings.json"
FALLBACK = "#af48af"


# DMS custom-theme keys -> the matugen keys dms-colors.json (and every
# consumer here) uses.
CUSTOM_KEYS = {
    "primary": "primary", "primaryText": "on_primary",
    "primaryContainer": "primary_container", "secondary": "secondary",
    "tertiary": "tertiary", "surface": "surface", "surfaceText": "on_surface",
    "surfaceVariant": "surface_variant", "surfaceVariantText": "on_surface_variant",
    "background": "background", "backgroundText": "on_background",
    "outline": "outline", "error": "error",
    "surfaceContainerLowest": "surface_container_lowest",
    "surfaceContainerLow": "surface_container_low",
    "surfaceContainer": "surface_container",
    "surfaceContainerHigh": "surface_container_high",
    "surfaceContainerHighest": "surface_container_highest",
}


def dms_mode():
    try:
        return "light" if json.loads(DMS_SESSION.read_text()).get("isLightMode") else "dark"
    except Exception:
        return "dark"


def dms_palettes():
    """Both modes, as {"dark": {...}, "light": {...}} in matugen keys.

    dms-colors.json is DMS's matugen export. With a custom theme (e.g.
    gnome-accent) DMS paints its own UI straight from the theme file, while
    the export is re-derived and drifts slightly (#ffaaf8 vs #f5aeff), so the
    theme file's colours win wherever it defines them.
    """
    try:
        pals = json.loads(DMS_COLORS.read_text())["colors"]
    except Exception:
        return None
    try:
        settings = json.loads(DMS_SETTINGS.read_text())
        if settings.get("currentThemeName") == "custom" and settings.get("customThemeFile"):
            theme = json.loads(Path(settings["customThemeFile"]).expanduser().read_text())
            for mode in ("dark", "light"):
                for k, v in (theme.get(mode) or {}).items():
                    if k in CUSTOM_KEYS and mode in pals:
                        pals[mode][CUSTOM_KEYS[k]] = v
    except Exception:
        pass
    return pals


def with_accent(pal, mode):
    """Add `accent` / `on_accent`: the colour the rest of the system uses.

    Material's dark-mode `primary` is a pastel meant for DARK text, which made
    white tab titles and borders hard to read. Outside DMS's own panels the
    accent is therefore the mid-tone container in dark mode (for the
    gnome-accent theme that is exactly the Yaru accent, #af48af) and
    `primary` in light mode, each with its own text colour.
    """
    if not pal:
        return pal
    if mode == "dark" and pal.get("primary_container"):
        pal["accent"] = pal["primary_container"]
        pal["on_accent"] = pal.get("on_primary_container") or "#ffffff"
    else:
        pal["accent"] = pal.get("primary")
        pal["on_accent"] = pal.get("on_primary") or "#ffffff"
    return pal


def dms_palette():
    pals = dms_palettes()
    mode = dms_mode()
    return with_accent(pals.get(mode), mode) if pals else None


def gtk_accent():
    theme = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "gtk-theme"],
                           capture_output=True, text=True).stdout.strip().strip("'")
    for base in (HOME / ".themes", HOME / ".local/share/themes", Path("/usr/share/themes")):
        d = base / theme / "gtk-3.0"
        if not (d / "gtk.css").is_file():
            continue
        text = (d / "gtk.css").read_text(errors="replace")
        # Yaru keeps the real stylesheet in a gresource and only @imports it.
        m = re.search(r'resource://(/[^")]+)', text)
        if m and (d / "gtk.gresource").is_file():
            text = subprocess.run(["gresource", "extract", str(d / "gtk.gresource"), m.group(1)],
                                  capture_output=True, text=True).stdout
        m = re.search(r"@define-color\s+theme_selected_bg_color\s+(#[0-9a-fA-F]{6})", text)
        if m:
            return m.group(1).lower()
    return FALLBACK


if __name__ == "__main__":
    if "--gtk" in sys.argv:
        # The GTK (Yaru) accent alone, ignoring DMS: what hypr-dms-accent seeds
        # the gnome-accent DMS theme from. Reading DMS here would be circular.
        print(gtk_accent())
        sys.exit(0)
    if "--all" in sys.argv:
        # Same shape as dms-colors.json, for hypr-accent's shared palette file.
        pals = dms_palettes() or {}
        for m in pals:
            with_accent(pals[m], m)
        print(json.dumps({"mode": dms_mode(), "colors": pals}))
        sys.exit(0)
    pal = dms_palette()
    if "--json" in sys.argv:
        print(json.dumps(pal or {"primary": gtk_accent()}))
    else:
        print(((pal or {}).get("accent") or gtk_accent()).lower())
