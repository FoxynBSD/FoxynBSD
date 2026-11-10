#!/bin/sh
# Build Gershwin's Menu (the global menu bar), the SoundBackend and
# NetworkBackend libraries it links with, the session supervisor
# gershwin-session and the LoginWindow display manager, from the revision
# pinned by contrib/gershwin-components, and install them in /System: the
# libraries in /System/Library/Libraries, Menu and LoginWindow in
# /System/Library/CoreServices/Applications, gershwin-session in
# /System/Library/Tools.
#
# Needs the GNUstep that build-gnustep.sh installs in /System (with
# libdispatch), run as the same unprivileged user while /System is
# writable by that user.  Needs dbus and gettext from DPorts.
set -eu

revision=08ca92248d35115c15d7060567ae2000a9222e10
sha256=142cfdfb4c5d24142b4de12c818747669afdecd0e3d6b29347863c616d3c51b2
prefix=/System
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patches=$script_dir/patches
# DragonFly: Menu's GNUmakefile has no DragonFly flags; its process name
# lookup reads FreeBSD's kinfo_proc; and menu extras are found by polling,
# as on FreeBSD, rather than with Apple's O_EVTONLY.
menu_patches="menu-dragonfly-gnumakefile.txt menu-dragonfly-kinfo.txt
    menu-dragonfly-extra-poll.txt"

say() { echo "build-menu: $*"; }
die() { echo "build-menu: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w "$prefix/Library/Libraries" ] || die "$prefix is not writable by $(id -un)"
[ -r "$prefix/Library/Makefiles/GNUstep.sh" ] ||
    die "no GNUstep in $prefix: run build-gnustep.sh first"
[ -r "$prefix/Library/Headers/dispatch/dispatch.h" ] ||
    die "no libdispatch in $prefix: run build-gnustep.sh first"
for tool in fetch sha256 tar patch gmake clang19 pkgconf; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done
for p in $menu_patches loginwindow-dragonfly.txt; do
	[ -r "$patches/$p" ] || die "patch not found: $patches/$p"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/menu-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
log=$work/build.log
step()
{
	name=$1; shift
	say "$name"
	"$@" >> "$log" 2>&1 || { tail -n 25 "$log" >&2; die "$name failed"; }
}

fetch -qo "$work/source.tar.gz" \
    "https://codeload.github.com/gershwin-desktop/gershwin-components/tar.gz/$revision" ||
    die "cannot fetch the source"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || die "source checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1
src=$work/src
for p in $menu_patches; do
	(cd "$src/Menu" && patch -s -p1 < "$patches/$p") || die "$p does not apply"
done

set +u
# shellcheck disable=SC1091
. "$prefix/Library/Makefiles/GNUstep.sh"
set -u
export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
# dbus, gettext's libintl and their headers are DPorts', in /usr/local.
inc="-I/usr/local/include"
lib="-L/usr/local/lib"
for d in SoundBackend NetworkBackend; do
	step "build $d" gmake -C "$src/Libraries/$d" \
	    ADDITIONAL_CPPFLAGS="$inc" ADDITIONAL_LDFLAGS="$lib"
	step "install $d" gmake -C "$src/Libraries/$d" install
done
step "build Menu" gmake -C "$src/Menu" ADDITIONAL_INCLUDE_DIRS="$inc" \
    ADDITIONAL_LIB_DIRS="$lib"
step "install Menu" gmake -C "$src/Menu" install
app=$prefix/Library/CoreServices/Applications/Menu.app
[ -x "$app/Menu" ] || die "Menu is missing from $app"
say "installed $app"
step "build gershwin-session" gmake -C "$src/gershwin-session"
step "install gershwin-session" gmake -C "$src/gershwin-session" install
[ -x "$prefix/Library/Tools/gershwin-session" ] ||
    die "gershwin-session is missing from $prefix/Library/Tools"
say "installed $prefix/Library/Tools/gershwin-session"
# LoginWindow: its install target also writes an rc.d script outside
# /System; foxyn-desktop provides the service, so only the bundle is
# copied.
(cd "$src/LoginWindow" && patch -s -p1 < "$patches/loginwindow-dragonfly.txt") ||
    die "loginwindow-dragonfly.txt does not apply"
step "build LoginWindow" gmake -C "$src/LoginWindow"
lw=$prefix/Library/CoreServices/Applications/LoginWindow.app
rm -rf "$lw"
cp -R "$src/LoginWindow/LoginWindow.app" "$lw"
[ -x "$lw/LoginWindow" ] || die "LoginWindow is missing from $lw"
say "installed $lw"
