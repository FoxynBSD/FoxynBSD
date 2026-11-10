#!/bin/sh
# Install Gershwin's system-wide settings and assets in /System/Library,
# from the revisions pinned by contrib/gershwin-system and
# contrib/gershwin-assets:
#	gershwin-system's Library/Preferences: GlobalDefaults (the GNUstep
#	defaults for every user: GSTheme=Eau, fonts, ...), fonts.conf and
#	GlobalShortcuts.plist
#	gershwin-assets' Library: Fonts (Inter, Luxi, Nimbus Sans, URW) and
#	Desktop Pictures
# The rest of gershwin-system (scripts for FreeBSD/Linux images, the
# LoginWindow service) is not installed.
#
# Run as the unprivileged user who may write /System, like the other
# helpers.
set -eu

system_rev=bb8186cdb8ab5dcafc469228e6eb60b3c8f43a97
system_sha=c3969f4a0e912c73082b4bfeb5b47ab1de1e3bb378da0a8c25a662af18bc152a
assets_rev=67e6946db9c47c8a666730f4e086d8c63986265b
assets_sha=a6cdb533555ddaa0b1e472189b9338df9657c3919a3b1bf7a4bce640e8a84042
prefix=/System

say() { echo "install-gershwin-system: $*"; }
die() { echo "install-gershwin-system: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w "$prefix/Library" ] || die "$prefix is not writable by $(id -un)"
for tool in fetch sha256 tar; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/gershwin-system.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# get NAME REVISION SHA256: fetch and unpack into $work/NAME.
get()
{
	fetch -qo "$work/$1.tar.gz" \
	    "https://codeload.github.com/gershwin-desktop/$1/tar.gz/$2" ||
	    die "cannot fetch $1"
	[ "$(sha256 -q "$work/$1.tar.gz")" = "$3" ] || die "$1: checksum mismatch"
	mkdir "$work/$1"
	tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
}
get gershwin-system "$system_rev" "$system_sha"
get gershwin-assets "$assets_rev" "$assets_sha"

mkdir -p "$prefix/Library/Preferences"
(cd "$work/gershwin-system/Library/Preferences" && tar cf - .) |
    (cd "$prefix/Library/Preferences" && tar xf -)
say "installed $prefix/Library/Preferences (GlobalDefaults, fonts.conf, GlobalShortcuts.plist)"
(cd "$work/gershwin-assets/Library" && tar cf - Fonts "Desktop Pictures") |
    (cd "$prefix/Library" && tar xf -)
say "installed $prefix/Library/Fonts and Desktop Pictures"
