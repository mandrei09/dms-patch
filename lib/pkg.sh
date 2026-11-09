# Package-manager helpers shared by the user-side scripts (sourced, POSIX sh).
# The root-side scripts (dms-greeter-launch, dms-greeter-ui-rebuild) carry an
# inline copy instead: the login screen must not depend on this repo.

# pkg_ver <debian-package> <file>: version of the Debian package, or of the
# pacman package that owns <file> (Arch names differ: dms = dux-shell, ...).
pkg_ver() {
    _v=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null) && [ -n "$_v" ] && { echo "$_v"; return; }
    command -v pacman >/dev/null 2>&1 && pacman -Qo "$2" 2>/dev/null | awk '{print $NF}'
}

# ver_lt A B: true when version A sorts before B.
ver_lt() {
    if command -v dpkg >/dev/null 2>&1; then dpkg --compare-versions "$1" lt "$2"
    else [ "$(vercmp "$1" "$2")" -lt 0 ]; fi
}

# distro: debian | arch | unknown (override with DMS_PATCH_DISTRO)
distro() {
    [ -n "${DMS_PATCH_DISTRO:-}" ] && { echo "$DMS_PATCH_DISTRO"; return; }
    _ids=$(. /etc/os-release 2>/dev/null; echo " ${ID:-} ${ID_LIKE:-} ")
    case "$_ids" in
        *" arch "*) echo arch ;;
        *" debian "*|*" ubuntu "*) echo debian ;;
        *) echo unknown ;;
    esac
}

# pkg_installed <package>, pkg_explicit <package> (not auto/dependency-installed)
pkg_installed() {
    case $(distro) in
        arch) pacman -Qq "$1" >/dev/null 2>&1 ;;
        *) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qE '^(install|hold) ok installed' ;;
    esac
}
pkg_explicit() {
    case $(distro) in
        arch) pacman -Qqe "$1" >/dev/null 2>&1 ;;
        *) ! apt-mark showauto "$1" 2>/dev/null | grep -qx "$1" ;;
    esac
}
