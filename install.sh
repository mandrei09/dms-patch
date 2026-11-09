#!/usr/bin/env bash
# dms-patch installer.
#
#   ./install.sh [--user]        link home/ into $HOME, enable the user units (default)
#   ./install.sh --deps          install the packages in deps/<distro>.txt
#                                (apt on Debian/Ubuntu; pacman + paru/yay on Arch)
#   ./install.sh --root [--yes]  copy root/ + root.<distro>/ into / (re-runs itself
#                                via pkexec); shows a diff and asks per changed file
#   ./install.sh --check         report drift on both sides, change nothing (exit 1 = drift)
#   ./install.sh --uninstall     remove the $HOME links that point into this repo
#   -n / --dry-run               print what --user/--root would do
#   -q / --quiet                 --check: print only problems
#
# home/ is linked, not copied: editing ~/.local/bin/dms-tray-patch edits the
# repo, so `git status` shows every change. Most entries are linked file by
# file. The directories in DIR_LINKS (and every child of DIR_LINK_PARENTS) are
# linked whole, because tools write generated files into them.
# root/ is copied, because root must not run files a user can edit. Files in
# root.debian/ or root.arch/ are added for (or override root/ on) that distro.
# The distro comes from /etc/os-release; DMS_PATCH_DISTRO=arch|debian overrides.
set -uo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
H="$REPO/home"
. "$REPO/lib/pkg.sh"
DISTRO=$(distro)
DEPS="$REPO/deps/$DISTRO.txt"
ROOTS=("$REPO/root" "$REPO/root.$DISTRO")
DIR_LINK_PARENTS=(.config/dms/plugins .config/quickshell)
DIR_LINKS=(.local/share/dms-launcher-patch .local/share/vscode-dark-modern)
STAMP=$(date +%Y%m%d-%H%M%S)
UNITDIR=.config/systemd/user

MODE=user DRY=0 YES=0 QUIET=0
for a in "$@"; do
    case "$a" in
        --user) MODE=user ;;
        --root) MODE=root ;;
        --deps) MODE=deps ;;
        --check) MODE=check ;;
        --uninstall) MODE=uninstall ;;
        -n|--dry-run) DRY=1 ;;
        -y|--yes) YES=1 ;;
        -q|--quiet) QUIET=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
run()  { if [ "$DRY" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
PROBLEMS=0

# ── link entries (paths relative to home/) ──────────────────────────────
entries() {
    local p d prune=()
    for p in "${DIR_LINK_PARENTS[@]}"; do
        [ -d "$H/$p" ] || continue
        for d in "$H/$p"/*/; do printf '%s\n' "${d%/}"; done
        prune+=(-path "$H/$p" -prune -o)
    done
    for p in "${DIR_LINKS[@]}"; do
        [ -e "$H/$p" ] && printf '%s\n' "$H/$p"
        prune+=(-path "$H/$p" -prune -o)
    done
    find "$H" "${prune[@]}" \( -type f -o -type l \) -print
} 2>/dev/null

rel_entries() { entries | sed "s|^$H/||" | sort; }

# A parent directory that is itself a symlink (a stow "folded" dir, e.g.
# ~/.config/dms -> ~/dotfiles/dms/.config/dms) would make us write into the
# other repo. Report it instead.
folded_parent() {
    local dir
    dir=$(dirname "$HOME/$1")
    while [ "$dir" != "$HOME" ] && [ "$dir" != / ]; do
        if [ -L "$dir" ]; then printf '%s\n' "$dir"; return 0; fi
        dir=$(dirname "$dir")
    done
    return 1
}

link_state() {   # ok | missing | other:<where> | real | folded:<dir>
    local rel=$1 t="$HOME/$1" f
    if f=$(folded_parent "$rel"); then echo "folded:$f"; return; fi
    if [ -L "$t" ]; then
        [ "$(readlink -f "$t")" = "$H/$rel" ] && echo ok || echo "other:$(readlink "$t")"
    elif [ -e "$t" ]; then echo real
    else echo missing
    fi
}

# Units under home/.config/systemd/user that carry WantedBy=. They are pulled
# in by the tracked <target>.d/dms-patch.conf drop-ins (Wants=), not by .wants
# links: those folders belong to the dotfiles repo.
wanted_units() {
    local u
    for u in "$H/$UNITDIR"/*.service "$H/$UNITDIR"/*.path "$H/$UNITDIR"/*.timer; do
        [ -f "$u" ] || continue
        sed -n 's/^WantedBy=//p' "$u" | tr ' ' '\n' | sed "/^$/d; s|^|$(basename "$u") |"
    done
}

FONT_DST="$HOME/.local/share/fonts/MaterialSymbolsRounded-snip.ttf"
# Arch's dux-shell ships no /usr/share/quickshell/dms; there the font only
# exists in the tree dms-shell-sync extracts on the first DMS start.
font_src() {
    find /usr/share/quickshell/dms "$HOME/.cache/dms-shell-src" "$HOME/.local/share/dms-shell" \
        -name 'MaterialSymbolsRounded*.ttf' -print -quit 2>/dev/null
}

DOCKER_PLUGIN="$HOME/.config/dms/plugins/dockerManager"
DOCKER_PATCH="$REPO/patches/dockerManager.patch"
docker_patch_state() {   # applied | pending | absent | conflict
    [ -d "$DOCKER_PLUGIN" ] || { echo absent; return; }
    if patch -d "$DOCKER_PLUGIN" -p1 -R --dry-run -s -f <"$DOCKER_PATCH" >/dev/null 2>&1; then echo applied
    elif patch -d "$DOCKER_PLUGIN" -p1 --dry-run -s -f <"$DOCKER_PATCH" >/dev/null 2>&1; then echo pending
    else echo conflict
    fi
}

# ── user side ───────────────────────────────────────────────────────────
do_user() {
    local rel st t blocked=0
    while read -r rel; do
        st=$(link_state "$rel")
        [ "${st%%:*}" = folded ] || continue
        echo "✗ $HOME/$rel: parent ${st#folded:} is a symlink (stow-folded)."
        blocked=1
    done < <(rel_entries)
    if [ "$blocked" = 1 ]; then
        echo "Unfold those first, e.g.: cd ~/dotfiles && stow -R --no-folding <package>" >&2
        exit 1
    fi

    while read -r rel; do
        t="$HOME/$rel"
        st=$(link_state "$rel")
        case "$st" in
            ok) continue ;;
            real) say "backup  ~/$rel -> ~/$rel.bak-dms-patch-$STAMP"
                  run mv "$t" "$t.bak-dms-patch-$STAMP" ;;
            other:*) say "relink  ~/$rel (was -> ${st#other:})"; run rm -f "$t" ;;
            missing) say "link    ~/$rel" ;;
        esac
        run mkdir -p "$(dirname "$t")"
        run ln -sfn "$H/$rel" "$t"
    done < <(rel_entries)

    # snip's icon font: a private copy of the one DMS ships (see snip/shell.qml)
    local src; src=$(font_src)
    if [ -n "$src" ] && ! cmp -s "$src" "$FONT_DST"; then
        say "copy    snip icon font"
        run install -D -m644 "$src" "$FONT_DST"
    fi

    case $(docker_patch_state) in
        pending) say "patch   dockerManager (Docker 29 event field, DMS 2.0 imports)"
                 run patch -d "$DOCKER_PLUGIN" -p1 -s <"$DOCKER_PATCH" ;;
        conflict) echo "! dockerManager changed upstream; port $DOCKER_PATCH by hand" >&2 ;;
    esac

    if [ "$DRY" = 0 ] && systemctl --user daemon-reload 2>/dev/null; then
        say "Done. Apply the shell patches with: systemctl --user restart dms.service"
    else
        say "Done (user manager not reachable: units take effect at next login)."
    fi
}

do_uninstall() {
    local rel t
    while read -r rel; do
        t="$HOME/$rel"
        [ "$(link_state "$rel")" = ok ] || continue
        say "unlink  ~/$rel"; run rm -f "$t"
    done < <(rel_entries)
    say "Root files are left alone; remove them by hand if wanted (see README)."
}

# ── root side ───────────────────────────────────────────────────────────
# Debian: our hyprland.desktop replaces the package's (dpkg-divert keeps
# apt from overwriting it). Arch installs its own hyprland-dms.desktop instead.
DIVERSIONS=()
[ "$DISTRO" = debian ] && DIVERSIONS=(
    "/usr/share/wayland-sessions/hyprland.desktop /usr/share/wayland-sessions/hyprland.desktop.pkg"
    "/usr/share/wayland-sessions/hyprland-uwsm.desktop /usr/share/wayland-sessions/hyprland-uwsm.desktop.disabled"
)
deps() { awk -v want="${1:-}" '!/^#/ && NF && ((want == "") || ($2 == want)) { print $1 }' "$DEPS" 2>/dev/null; }

need_distro() {
    case "$DISTRO" in debian|arch) ;; *)
        echo "install.sh: unsupported distro (not Debian/Ubuntu or Arch); set DMS_PATCH_DISTRO" >&2; exit 2 ;;
    esac
}

# "<repo file>\t<live path>" for every root file; root.<distro>/ wins over root/.
root_files() {
    declare -A seen=()
    local dir f live
    for dir in "${ROOTS[@]}"; do
        [ -d "$dir" ] || continue
        while IFS= read -r f; do seen[${f#"$dir"}]=$f; done < <(find "$dir" -type f)
    done
    for live in "${!seen[@]}"; do printf '%s\t%s\n' "${seen[$live]}" "$live"; done | sort -t$'\t' -k2
}

do_deps() {
    need_distro
    local p missing=() aur=()
    for p in $(deps); do pkg_installed "$p" || missing+=("$p"); done
    [ ${#missing[@]} = 0 ] && { say "All packages from deps/$DISTRO.txt are installed."; return; }
    if [ "$DISTRO" = debian ]; then
        say "apt install: ${missing[*]}"
        run sudo apt-get install -y "${missing[@]}"
        return
    fi
    local repo=()
    for p in "${missing[@]}"; do
        if deps aur | grep -qx "$p"; then aur+=("$p"); else repo+=("$p"); fi
    done
    [ ${#repo[@]} = 0 ] || { say "pacman: ${repo[*]}"; run sudo pacman -S --needed --noconfirm "${repo[@]}"; }
    if [ ${#aur[@]} -gt 0 ]; then
        local helper; helper=$(command -v paru || command -v yay)
        if [ -z "$helper" ]; then
            echo "! AUR packages need an AUR helper: ${aur[*]}" >&2
            echo "  e.g.: sudo pacman -S --needed base-devel git && git clone https://aur.archlinux.org/paru-bin.git && (cd paru-bin && makepkg -si)" >&2
            exit 1
        fi
        say "$(basename "$helper"): ${aur[*]}"
        run "$helper" -S --needed --noconfirm "${aur[@]}"
    fi
}

do_root() {
    if [ "$(id -u)" != 0 ]; then
        local args=(--root); [ "$DRY" = 1 ] && args+=(-n); [ "$YES" = 1 ] && args+=(-y)
        exec pkexec "$REPO/install.sh" "${args[@]}"
    fi
    need_distro
    local d f live mode changed=0 ans
    for d in "${DIVERSIONS[@]}"; do
        set -- $d
        if ! dpkg-divert --list "$1" | grep -q .; then
            say "divert  $1 -> $2"
            run dpkg-divert --local --rename --divert "$2" --add "$1"
        fi
    done
    while IFS=$'\t' read -r f live; do
        mode=$(stat -c %a "$f")
        if cmp -s "$f" "$live"; then
            [ "$(stat -c %a "$live")" = "$mode" ] && continue
            say "chmod   $mode $live"; run chmod "$mode" "$live"; continue
        fi
        if [ -e "$live" ]; then
            echo; diff -u --label "live $live" --label "repo $live" "$live" "$f"
            if [ "$YES" = 0 ] && [ "$DRY" = 0 ]; then
                read -r -p "Replace $live with the repo copy? [y/N] " ans </dev/tty
                case "$ans" in y|Y) ;; *) echo "  kept $live"; continue ;; esac
            fi
            run cp -a "$live" "$live.bak-dms-patch-$STAMP"
        fi
        say "install $live"
        run install -D -o root -g root -m "$mode" "$f" "$live"
        changed=1
    done < <(root_files)

    local h; for h in $(deps hold); do
        pkg_installed "$h" || continue
        apt-mark showhold | grep -qx "$h" || { say "hold    $h"; run apt-mark hold "$h" >/dev/null; }
    done
    # explicit/manual, so autoremove (apt) or orphan cleanup (pacman -Qdt) keeps them
    local pkg missing=()
    for pkg in $(deps); do
        if ! pkg_installed "$pkg"; then missing+=("$pkg")
        elif ! pkg_explicit "$pkg"; then
            say "explicit $pkg"
            if [ "$DISTRO" = arch ]; then run pacman -D --asexplicit "$pkg" >/dev/null
            else run apt-mark manual "$pkg" >/dev/null; fi
        fi
    done
    [ ${#missing[@]} = 0 ] || echo "! missing packages (${missing[*]}): run install.sh --deps as your user"
    if [ "$DISTRO" = arch ] && [ "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" != /usr/lib/systemd/system/greetd.service ]; then
        echo "! greetd is not the display manager yet: systemctl enable greetd.service (disable the current one first)"
    fi
    [ "$changed" = 1 ] || { say "Root files already match the repo."; return; }
    run systemd-tmpfiles --create /etc/tmpfiles.d/polkit-fprint-skip.conf
    run systemctl daemon-reload
    run systemctl enable --now polkit-fprint-skip.path
    run /usr/local/sbin/dms-greeter-ui-rebuild
    say "Done. A changed greetd/PAM config takes effect at the next login."
}

# ── check ───────────────────────────────────────────────────────────────
do_check() {
    local rel st n=0 u target t f live src
    say "User links ($H):"
    while read -r rel; do
        n=$((n + 1))
        st=$(link_state "$rel")
        case "$st" in
            ok) ;;
            missing) bad "~/$rel is missing" ;;
            real) bad "~/$rel is a real file or folder, not a link into the repo" ;;
            other:*) bad "~/$rel points to ${st#other:}" ;;
            folded:*) bad "~/$rel sits under the folded symlink ${st#folded:}" ;;
        esac
    done < <(rel_entries)
    say "  $n entries checked"
    # links into the repo whose source was deleted or renamed
    while IFS= read -r t; do
        bad "dangling link $t (its repo file is gone)"
    done < <(find "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.config/dms/plugins" "$HOME/.config/quickshell" \
                  "$HOME/$UNITDIR" -maxdepth 3 -xtype l -lname "$H/*" 2>/dev/null)
    while read -r u target; do
        grep -qE "^Wants=.*\b${u//./\\.}\b" "$H/$UNITDIR/$target.d/dms-patch.conf" 2>/dev/null \
            || bad "$u has WantedBy=$target but is missing from $target.d/dms-patch.conf"
    done < <(wanted_units)
    src=$(font_src)
    [ -z "$src" ] || cmp -s "$src" "$FONT_DST" || bad "snip icon font missing or stale ($FONT_DST)"
    [ "$(docker_patch_state)" = pending ] && bad "dockerManager patch not applied"
    [ "$(docker_patch_state)" = conflict ] && bad "dockerManager patch no longer applies"

    say "Root files (root/ + root.$DISTRO/):"
    while IFS=$'\t' read -r f live; do
        if [ ! -e "$live" ]; then bad "$live is not installed"
        elif [ ! -r "$live" ]; then say "  ? $live is not readable without root"
        elif ! cmp -s "$f" "$live"; then bad "$live differs from the repo (diff -u $live $f)"
        fi
    done < <(root_files)
    for d in "${DIVERSIONS[@]}"; do
        set -- $d
        dpkg-divert --list "$1" | grep -q . || bad "$1 is not diverted"
    done
    if [ "$PROBLEMS" = 0 ]; then say "All good."; else echo "$PROBLEMS problem(s)."; exit 1; fi
}

case "$MODE" in
    user) do_user ;;
    root) do_root ;;
    deps) do_deps ;;
    check) do_check ;;
    uninstall) do_uninstall ;;
esac
