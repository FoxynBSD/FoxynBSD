#!/bin/sh
# Build Gershwin's System Preferences (the PreferencePanes framework, its
# modules and the application) from the revision pinned by
# contrib/gershwin-systempreferences and install it in /System (System
# domain).  Workspace's metadata panel needs the framework.
#
# Needs the GNUstep that build-gnustep.sh installs in /System, run as the
# same unprivileged user while /System is writable by that user.
set -eu

revision=d5809a837f2f094ab22624ca5c0b1f010b7348e9
sha256=534e43d4c49abc62fe037d57f65c854a64f57e0c91ffc0f120e57924198f256b
prefix=/System

say() { echo "build-systempreferences: $*"; }
die() { echo "build-systempreferences: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w "$prefix/Library/Libraries" ] || die "$prefix is not writable by $(id -un)"
[ -r "$prefix/Library/Makefiles/GNUstep.sh" ] ||
    die "no GNUstep in $prefix: run build-gnustep.sh first"
for tool in fetch sha256 tar gmake clang19; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/sysprefs-build.XXXXXXXX")
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
    "https://codeload.github.com/gershwin-desktop/gershwin-systempreferences/tar.gz/$revision" ||
    die "cannot fetch the source"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || die "source checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1
src=$work/src

set +u
# shellcheck disable=SC1091
. "$prefix/Library/Makefiles/GNUstep.sh"
set -u
export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
step "build System Preferences" gmake -C "$src"
step "install System Preferences" gmake -C "$src" install
app=$prefix/Applications/SystemPreferences.app
[ -x "$app/SystemPreferences" ] || die "SystemPreferences is missing from $app"
[ -d "$prefix/Library/Frameworks/PreferencePanes.framework" ] ||
    die "the PreferencePanes framework is missing"
say "installed $app"
