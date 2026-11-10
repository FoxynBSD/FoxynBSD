#!/bin/sh
# Build the pinned libdispatch (contrib/libdispatch's revision) with the
# DragonFly patch, and stage its installation under an output directory:
# OUTPUT/usr/local/{include,lib}.  Run as an unprivileged user; root
# copies the staged tree into place.  Needs cmake, ninja and clang19.
set -eu

revision=95f592ab637c4d7916fa05d4d80cbc1ec7d0b2b8
sha256=3c3d9496b9698ea5240f0139f59d604599e612972cec43196de932a2b3e69d79
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patch_file=$script_dir/patches/libdispatch-dragonfly.txt
output=${1:-./libdispatch-root}

[ "$#" -le 1 ] || { echo "usage: $0 [output-dir]" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "output already exists: $output" >&2; exit 1;
}
[ -r "$patch_file" ] || { echo "libdispatch patch not found: $patch_file" >&2; exit 1; }
for tool in fetch sha256 tar patch cmake ninja clang19 clang++19; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing command: $tool" >&2; exit 1; }
done
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || {
    echo "output directory is not writable: $parent" >&2; exit 1;
}
output=$(cd "$parent" && pwd)/$(basename "$output")
work=$(mktemp -d "$parent/.libdispatch-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
fetch -qo "$work/source.tar.gz" \
    "https://codeload.github.com/apple/swift-corelibs-libdispatch/tar.gz/$revision"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || {
    echo "libdispatch source checksum mismatch" >&2; exit 1;
}
tar -xzf "$work/source.tar.gz" -C "$work"
src=$work/swift-corelibs-libdispatch-$revision
(cd "$src" && patch -s -p1 < "$patch_file")
cmake -S "$src" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang19 -DCMAKE_CXX_COMPILER=clang++19 \
    -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_TESTING=OFF > "$work/cmake.log" ||
    { tail -n 20 "$work/cmake.log" >&2; exit 1; }
ninja -C "$work/build" > "$work/build.log" ||
    { grep -m 5 error "$work/build.log" >&2; exit 1; }
DESTDIR=$output ninja -C "$work/build" install > /dev/null
[ -f "$output/usr/local/include/dispatch/dispatch.h" ] || {
    echo "libdispatch headers missing" >&2; exit 1;
}
echo "staged $output/usr/local"
