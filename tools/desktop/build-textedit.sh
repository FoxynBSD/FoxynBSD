#!/bin/sh
# Build the pinned Gershwin TextEdit source into a standalone GNUstep bundle.
set -eu

revision=f7dc768641c1a23609cfb53e6cf17c2ea7f0c898
sha256=be7aae93a9eb9e6f0697ef58d0ee4359681c4a935ce421eb1b622c3c0cca0b5b
makefiles=/usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
output=${1:-./TextEdit.app}

[ "$#" -le 1 ] || { echo "usage: $0 [output-bundle]" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "output already exists: $output" >&2; exit 1;
}
[ -r "$makefiles" ] || { echo "GNUstep Make not found: $makefiles" >&2; exit 1; }
for tool in fetch sha256 tar gmake clang19; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing command: $tool" >&2; exit 1; }
done
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || {
    echo "output directory is not writable: $parent" >&2; exit 1;
}
output=$(cd "$parent" && pwd)/$(basename "$output")
work=$(mktemp -d "$parent/.textedit-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
work=$(cd "$work" && pwd)
fetch -qo "$work/source.tar.gz" \
    "https://codeload.github.com/gershwin-desktop/gershwin-textedit/tar.gz/$revision"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || {
    echo "TextEdit source checksum mismatch" >&2; exit 1;
}
tar -xzf "$work/source.tar.gz" -C "$work"
cd "$work/gershwin-textedit-$revision"
# GNUstep.sh is not safe with nounset on every supported package version.
set +u
. "$makefiles"
set -u
gmake
[ -x TextEdit.app/TextEdit ] || { echo "TextEdit executable missing" >&2; exit 1; }
mv TextEdit.app "$output"
echo "built $output"
