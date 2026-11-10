#!/bin/sh
# Build OpenRC from the revision pinned by contrib/openrc, with the
# DragonFly patch, and stage its installation under an output directory
# (OUTPUT/sbin, OUTPUT/bin, OUTPUT/usr/local/...): prefix /usr/local, its
# configuration (init.d, conf.d, runlevels) in /usr/local/etc.  OpenRC
# runs next to rc.d, not as init.  Run as an unprivileged user; root
# copies the staged tree into place.  Needs meson, ninja and clang19.
set -eu

revision=c3689317b5b028f96c1e4912ab5281f2719665e5
sha256=dfc02d54175189749000a05eb03ebc28bd0dfb585464fdcd4b90df148ea94470
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patch_file=$script_dir/patches/openrc-dragonfly.txt
output=${1:-./openrc-root}

say() { echo "build-openrc: $*"; }
die() { echo "build-openrc: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "usage: $0 [output-dir]"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ ! -e "$output" ] && [ ! -L "$output" ] || die "output already exists: $output"
[ -r "$patch_file" ] || die "patch not found: $patch_file"
for tool in fetch sha256 tar patch meson ninja clang19; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done
parent=$(dirname "$output")
[ -d "$parent" ] && [ -w "$parent" ] || die "output directory is not writable: $parent"
output=$(cd "$parent" && pwd)/$(basename "$output")

work=$(mktemp -d "$parent/.openrc-build.XXXXXXXX")
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
    "https://codeload.github.com/OpenRC/openrc/tar.gz/$revision" ||
    die "cannot fetch the source"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || die "source checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1
(cd "$work/src" && patch -s -p1 < "$patch_file") || die "the OpenRC patch does not apply"

# The sysconfdir must be absolute: its install script joins a relative
# one to DESTDIR, not to the prefix.
step "configure OpenRC" env CC=clang19 meson setup "$work/build" "$work/src" \
    --prefix=/usr/local -Dsysconfdir=/usr/local/etc \
    -Dpam=false -Dselinux=disabled -Daudit=disabled
step "build OpenRC" ninja -C "$work/build"
step "stage OpenRC" env DESTDIR="$output" ninja -C "$work/build" install
[ -x "$output/sbin/openrc" ] || die "openrc is missing from $output/sbin"
say "staged $output"
