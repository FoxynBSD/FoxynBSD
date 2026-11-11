#!/bin/sh
# Build Gershwin's Terminal from the revision pinned by
# contrib/gershwin-terminal (its archive, identical to the submodule,
# checked by SHA-256) into a standalone GNUstep application bundle, with
# patches/terminal-dragonfly.txt: DragonFly takes FreeBSD's headers
# (termios.h, libutil.h for forkpty) instead of Linux's termio.h and
# pty.h.  Run as the unprivileged desktop user, like the other helpers.
#
# Usage: build-terminal.sh [output-bundle]	(default ./Terminal.app)
set -eu

revision=2c77b9c3f7c8a4b7a200830f5ba81b5f9085be06
sha256=ad02595cb63402a7b66a155d9c07e986d4207b295a3fd33b83c386d7a366e1b3
makefiles=${GNUSTEP_SH:-/System/Library/Makefiles/GNUstep.sh}
output=${1:-./Terminal.app}
patch_file=$(CDPATH= cd -- "$(dirname "$0")" && pwd)/patches/terminal-dragonfly.txt

[ "$#" -le 1 ] || { echo "usage: $0 [output-bundle]" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "output already exists: $output" >&2; exit 1;
}
[ -r "$makefiles" ] || { echo "GNUstep Make not found: $makefiles" >&2; exit 1; }
[ -r "$patch_file" ] || { echo "missing $patch_file" >&2; exit 1; }
for tool in fetch sha256 tar patch gmake clang19; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing command: $tool" >&2; exit 1; }
done
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || {
    echo "output directory is not writable: $parent" >&2; exit 1;
}
output=$(cd "$parent" && pwd)/$(basename "$output")
work=$(mktemp -d "$parent/.terminal-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
work=$(cd "$work" && pwd)
fetch -qo "$work/source.tar.gz" \
    "https://codeload.github.com/gershwin-desktop/gershwin-terminal/tar.gz/$revision"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || {
    echo "Terminal source checksum mismatch" >&2; exit 1;
}
tar -xzf "$work/source.tar.gz" -C "$work"
cd "$work/gershwin-terminal-$revision"
patch -s -p0 < "$patch_file"
# GNUstep.sh is not safe with nounset on every supported package version.
set +u
. "$makefiles"
set -u
gmake
[ -x Terminal.app/Terminal ] || { echo "Terminal executable missing" >&2; exit 1; }
mv Terminal.app "$output"
echo "built $output"
