#!/bin/sh
# Build the XLibre X server with its scfb video and libinput input
# drivers, from the revisions pinned by contrib/xlibre,
# contrib/xlibre-video-scfb and contrib/xlibre-input-libinput, into
# /System/Library/XLibre (its own prefix: DPorts' xorg-server is not
# replaced).  The server uses DPorts' xkeyboard-config and xkbcomp, and
# its configuration in /System/Library/XLibre/etc/X11/xorg.conf.d.
#
# Run as an unprivileged user who may write /System, like the other
# helpers.  Needs meson, ninja, clang19, autoconf, automake, libtool,
# xorg-macros and the X libraries the server links with, from DPorts.
#
# Not built: GLX, glamor and DRI (no 3D here), udev, seatd, Xvfb, Xnest,
# Xephyr.
set -eu

server_rev=ec1f2d37daa1450d8452abb547de4546321d7bb9
server_sha=acfd4b04cbc4a5b400bb3b3022fef78a40bb781aa27bf7ab124cd14233cc9871
scfb_rev=df94d49909ec9c22e5044669f9d1363f4ed429a5
scfb_sha=1261349c19f863012a3b1d7046165ae32b9032388c76eb9eb89d778948e4a916
libinput_rev=4eb6691efeef4969a05b1d6b77d980943fb9760e
libinput_sha=9559348e118ba53b4e7878d774ce2e22d67595f9fab9e6f7ea88d1de3b6f69f2
prefix=/System/Library/XLibre

say() { echo "build-xlibre: $*"; }
die() { echo "build-xlibre: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
mkdir -p "$prefix" 2>/dev/null && [ -w "$prefix" ] ||
    die "$prefix is not writable by $(id -un)"
for tool in fetch sha256 tar meson ninja clang19 autoreconf libtoolize pkgconf gmake; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/xlibre-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
log=$work/build.log
step()
{
	name=$1; shift
	say "$name"
	"$@" >> "$log" 2>&1 || { tail -n 25 "$log" >&2; die "$name failed"; }
}
# get NAME REPO REVISION SHA256: fetch and unpack into $work/NAME.
get()
{
	fetch -qo "$work/$1.tar.gz" "https://codeload.github.com/$2/tar.gz/$3" ||
	    die "cannot fetch $2"
	[ "$(sha256 -q "$work/$1.tar.gz")" = "$4" ] || die "$1: checksum mismatch"
	mkdir "$work/$1"
	tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
}
get server X11Libre/xserver "$server_rev" "$server_sha"
get scfb X11Libre/xf86-video-scfb "$scfb_rev" "$scfb_sha"
get libinput X11Libre/xf86-input-libinput "$libinput_rev" "$libinput_sha"

export CC=clang19 CXX=clang++19
export CPPFLAGS="-I/usr/local/include ${CPPFLAGS:-}"
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib ${LDFLAGS:-}"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig:/usr/local/libdata/pkgconfig"

step "configure the server" meson setup "$work/server/build" "$work/server" \
    --prefix="$prefix" --buildtype=release \
    -Dxorg=true -Dxvfb=false -Dxnest=false -Dxephyr=false \
    -Dglamor=false -Dglx=false -Dglx_dri=false \
    -Ddri1=false -Ddri2=false -Ddri3=false -Ddocs=false -Ddevel-docs=false \
    -Dtests=false -Dlibunwind=false -Dxf86-input-inputtest=false \
    -Dudev=false -Dudev_kms=false -Dseatd_libseat=false \
    -Dxselinux=false -Dlinux_apm=false -Dlinux_acpi=false \
    -Dint10=false -Dsuid_wrapper=false -Dxvmc=false \
    -Dxkb_dir=/usr/local/share/X11/xkb -Dxkb_bin_dir=/usr/local/bin \
    -Dxkb_output_dir=/var/db/xkb -Dlog_dir=/var/log \
    -Ddefault_font_path=/usr/local/share/fonts/misc/,/usr/local/share/fonts/dejavu/
step "build the server" ninja -C "$work/server/build"
step "install the server" ninja -C "$work/server/build" install

step "configure scfb" sh -c "cd '$work/scfb' && NOCONFIGURE=1 ./autogen.sh && ./configure --prefix='$prefix' --with-xorg-module-dir='$prefix/lib/xorg/modules'"
step "build scfb" gmake -C "$work/scfb"
step "install scfb" gmake -C "$work/scfb" install

step "configure libinput" meson setup "$work/libinput/build" "$work/libinput" \
    --prefix="$prefix" --buildtype=release \
    -Dxorg-module-dir="$prefix/lib/xorg/modules" \
    -Dxorg-conf-dir="$prefix/share/X11/xorg.conf.d"
step "build libinput" ninja -C "$work/libinput/build"
step "install libinput" ninja -C "$work/libinput/build" install

[ -x "$prefix/bin/Xorg" ] || die "Xorg is missing from $prefix/bin"
say "installed $prefix ($("$prefix/bin/Xorg" -version 2>&1 | sed -n 's/^X.Org X Server \(.*\)/\1/p;s/^XLibre X Server \(.*\)/\1/p' | head -n 1))"
