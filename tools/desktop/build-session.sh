#!/bin/sh
# Build the pinned Gershwin session supervisor without modifying its source.
set -eu

source_sha256=300947548e1e15fb384357dab07af44cb5f39b1efbf4f039026200ccd08ccd43
[ "$#" -eq 2 ] || {
    echo "usage: $0 path/to/gershwin-session.m output" >&2
    exit 2
}
source_file=$1
output=$2
cc=${CC:-clang19}
[ -f "$source_file" ] || { echo "source not found: $source_file" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "output already exists: $output" >&2; exit 1;
}
command -v "$cc" >/dev/null 2>&1 || { echo "compiler not found: $cc" >&2; exit 1; }
command -v gnustep-config >/dev/null 2>&1 || {
    echo "gnustep-config not found; load the target GNUstep environment" >&2; exit 1;
}
if command -v sha256 >/dev/null 2>&1; then
    actual=$(sha256 -q "$source_file")
elif command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$source_file"); actual=${actual%% *}
else
    echo "sha256 or sha256sum is required" >&2; exit 1
fi
[ "$actual" = "$source_sha256" ] || {
    echo "unexpected supervisor source checksum: $source_file" >&2; exit 1;
}
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || {
    echo "output directory is not writable: $parent" >&2; exit 1;
}
work=$(mktemp -d "$parent/.gershwin-session.XXXXXXXX")
tmp=$work/gershwin-session
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
# gnustep-config intentionally returns a shell word list of compiler flags.
# CFLAGS and LDFLAGS permit target toolchain options, e.g. a linker sysroot.
# shellcheck disable=SC2046,SC2086
"$cc" $(gnustep-config --objc-flags) ${CFLAGS:-} "$source_file" \
    -o "$tmp" ${LDFLAGS:-} $(gnustep-config --base-libs)
chmod 755 "$tmp"
# link(2) fails if another process created the destination meanwhile.
ln "$tmp" "$output" || { echo "cannot create output: $output" >&2; exit 1; }
echo "built $output"
