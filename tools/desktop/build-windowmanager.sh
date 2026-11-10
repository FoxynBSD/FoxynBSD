#!/bin/sh
# Build the pinned Gershwin WindowManager in a user's working directory.
set -eu

revision=10b6797a3bfd391d559820232805f1a107fa9ec3
sha256=9ad4d8061faed0a9df8da9dbe6140f810f81ba93347ad6e6333ad691996cfa40
makefiles=/usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
output=${1:-./WindowManager.app}
patch_file=$script_dir/patches/windowmanager-titlebar-state.txt

[ "$#" -le 1 ] || { echo "usage: $0 [output-bundle]" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "output already exists: $output" >&2; exit 1;
}
[ -r "$patch_file" ] || { echo "WindowManager experiment patch not found: $patch_file" >&2; exit 1; }
[ -r "$makefiles" ] || { echo "GNUstep Make not found: $makefiles" >&2; exit 1; }
for tool in fetch sha256 tar patch gmake clang19 pkgconf; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing command: $tool" >&2; exit 1; }
done
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || {
    echo "output directory is not writable: $parent" >&2; exit 1;
}
output=$(cd "$parent" && pwd)/$(basename "$output")
work=$(mktemp -d "$parent/.windowmanager-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
work=$(cd "$work" && pwd)
fetch -qo "$work/source.tar.gz" \
    "https://codeload.github.com/gershwin-desktop/gershwin-windowmanager/tar.gz/$revision"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || {
    echo "WindowManager source checksum mismatch" >&2; exit 1;
}
tar -xzf "$work/source.tar.gz" -C "$work"
cd "$work/gershwin-windowmanager-$revision"
patch -p1 < "$patch_file"
set +u
. "$makefiles"
set -u
gmake
[ -x WindowManager/WindowManager.app/WindowManager ] || {
    echo "WindowManager executable missing" >&2; exit 1;
}
mv WindowManager/WindowManager.app "$output"
echo "built $output"
