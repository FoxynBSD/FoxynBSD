#!/bin/sh
# Build Gershwin's Eau theme from the revision pinned by
# contrib/gershwin-eau-theme and install it in /System/Library/Themes
# (System domain), where GNUstep finds GSTheme=Eau.
#
# Needs the GNUstep that build-gnustep.sh installs in /System (with
# libdispatch), run as the same unprivileged user while /System is
# writable by that user.
set -eu

revision=3d741fbc61b62acb3dc1f3213ebe50a8a81c579c
sha256=e6bf5ba0603ff3050da4fe1151c4a82c428567d437f9b3e9ea22127bcb86fe8d
prefix=/System

say() { echo "build-eau: $*"; }
die() { echo "build-eau: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w "$prefix/Library" ] || die "$prefix is not writable by $(id -un)"
[ -r "$prefix/Library/Makefiles/GNUstep.sh" ] ||
    die "no GNUstep in $prefix: run build-gnustep.sh first"
for tool in fetch sha256 tar gmake clang19; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/eau-build.XXXXXXXX")
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
    "https://codeload.github.com/gershwin-desktop/gershwin-eau-theme/tar.gz/$revision" ||
    die "cannot fetch the source"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || die "source checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1

set +u
# shellcheck disable=SC1091
. "$prefix/Library/Makefiles/GNUstep.sh"
set -u
export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
step "build Eau" gmake -C "$work/src"
step "install Eau" gmake -C "$work/src" install
[ -d "$prefix/Library/Themes/Eau.theme" ] || die "Eau.theme is missing"
say "installed $prefix/Library/Themes/Eau.theme"
