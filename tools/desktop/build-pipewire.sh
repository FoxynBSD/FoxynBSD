#!/bin/sh
# Build PipeWire and WirePlumber from the revisions pinned by
# contrib/pipewire and contrib/wireplumber, with epoll-shim, and install
# them in /System/Library/PipeWire.
#
# epoll-shim is built here, not taken from DPorts: DPorts' copy was built
# without eventfd(2) and emulates it with kqueue descriptors, which
# SCM_RIGHTS refuses, so PipeWire's clients were cut off (issue #13).
# Built on FoxynBSD it finds the native eventfd.  PipeWire has no OSS
# plugin and its ALSA plugin is Linux's: the sound goes through its JACK
# tunnel to jackd (DPorts' jackit) on OSS.
#
# Run as an unprivileged user while /System is writable by that user.
# Needs DPorts' meson, ninja, cmake, pkgconf, clang19, jackit, dbus,
# glib, lua54, libinotify, libsndfile and readline.
set -eu

# Tags (GitLab archives); contrib/*.README.DRAGONFLY record their commits.
pw_tag=1.6.11
pw_sha256=f3f70c4af173cc93d05070a9d412efe3ef5889bdf4ac32298e2c0d9ae1350559
wp_tag=0.5.19
wp_sha256=f9454eae3a5a6ca903c05ead2a7e47d7d3957fb0ffac3ebb11d92842603ae80f
shim_version=0.0.20240608
shim_sha256=8f5125217e4a0eeb96ab01f9dfd56c38f85ac3e8f26ef2578e538e72e87862cb
prefix=/System/Library/PipeWire
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patch_file=$script_dir/patches/pipewire-dragonfly.txt
wp_patch_file=$script_dir/patches/wireplumber-dragonfly.txt

say() { echo "build-pipewire: $*"; }
die() { echo "build-pipewire: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w /System/Library ] || die "/System/Library is not writable by $(id -un)"
for f in "$patch_file" "$wp_patch_file"; do
	[ -r "$f" ] || die "patch not found: $f"
done
for tool in fetch sha256 tar patch meson ninja cmake pkgconf clang19 jackd; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/pipewire-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
log=$work/build.log
step()
{
	name=$1; shift
	say "$name"
	"$@" >> "$log" 2>&1 || {
		# The first errors, which warnings after them would hide.
		grep -m 5 -A 4 'error:' "$log" >&2 || :
		tail -n 10 "$log" >&2
		die "$name failed"; }
}
# get NAME URL SHA256: fetch and unpack an archive in $work/NAME
get()
{
	fetch -qo "$work/$1.tar.gz" "$2" || die "cannot fetch $1"
	[ "$(sha256 -q "$work/$1.tar.gz")" = "$3" ] || die "$1: checksum mismatch"
	mkdir "$work/$1"
	tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
}
get epoll-shim "https://codeload.github.com/jiixyj/epoll-shim/tar.gz/refs/tags/v$shim_version" "$shim_sha256"
get pipewire "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/$pw_tag/pipewire-$pw_tag.tar.gz" "$pw_sha256"
get wireplumber "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/$wp_tag/wireplumber-$wp_tag.tar.gz" "$wp_sha256"
(cd "$work/pipewire" && patch -s -p1 < "$patch_file") || die "the PipeWire patch does not apply"
(cd "$work/wireplumber" && patch -s -p1 < "$wp_patch_file") ||
    die "the WirePlumber patch does not apply"

export CC=clang19 CXX=clang++19
export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/libdata/pkgconfig
# Its own libraries before /usr/local's (DPorts' libepoll-shim); the
# compiler does not search /usr/local (gettext's libintl, JACK).
export CFLAGS="-I/usr/local/include"
export LDFLAGS="-L$prefix/lib -L/usr/local/lib -Wl,-rpath,$prefix/lib"

step "configure epoll-shim" cmake -S "$work/epoll-shim" -B "$work/epoll-shim/b" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_PKGCONFIGDIR="$prefix/lib/pkgconfig"
grep -q 'Looking for eventfd - found' "$log" || die "epoll-shim did not find eventfd(2)"
step "build epoll-shim" cmake --build "$work/epoll-shim/b"
step "install epoll-shim" cmake --install "$work/epoll-shim/b"

step "configure PipeWire" meson setup "$work/pipewire/b" "$work/pipewire" \
    --prefix="$prefix" --buildtype=release -Dsession-managers=[] \
    -Ddocs=disabled -Dman=disabled -Dexamples=disabled -Dtests=disabled \
    -Dgstreamer=disabled -Dlibsystemd=disabled -Dlogind=disabled \
    -Dsystemd-system-service=disabled -Dsystemd-user-service=disabled \
    -Dselinux=disabled -Dpipewire-alsa=disabled -Dpipewire-jack=disabled \
    -Dpipewire-v4l2=disabled -Dalsa=disabled -Dbluez5=disabled -Djack=enabled \
    -Dv4l2=disabled -Dlibcamera=disabled -Dvulkan=disabled -Dudev=disabled \
    -Dffmpeg=disabled -Dsdl2=disabled -Dlibpulse=disabled -Droc=disabled \
    -Davahi=disabled -Decho-cancel-webrtc=disabled -Dlibusb=disabled \
    -Draop=disabled -Dlv2=disabled -Dx11=disabled -Dx11-xfixes=disabled \
    -Dlibcanberra=disabled -Davb=disabled -Dflatpak=disabled \
    -Dgsettings=disabled -Dcompress-offload=disabled -Dopus=disabled \
    -Dlibffado=disabled -Dsnap=disabled -Dlibmysofa=disabled \
    -Debur128=disabled -Dfftw=disabled -Donnxruntime=disabled \
    -Dsndfile=enabled -Dpw-cat=enabled -Ddbus=enabled -Dreadline=enabled
step "build PipeWire" ninja -C "$work/pipewire/b"
step "install PipeWire" ninja -C "$work/pipewire/b" install

# WirePlumber runs "python3", which DPorts only installs versioned
# (python3.11): Meson's own interpreter.
py=$(sed -n '1s/^#! *//p' "$(command -v meson)")
[ -x "$py" ] || die "cannot find meson's Python"
mkdir "$work/bin"
ln -s "$py" "$work/bin/python3"
PATH=$work/bin:$PATH
step "configure WirePlumber" meson setup "$work/wireplumber/b" "$work/wireplumber" \
    --prefix="$prefix" --buildtype=release -Dsystem-lua=true \
    -Dintrospection=disabled -Ddoc=disabled -Delogind=disabled \
    -Dsystemd=disabled -Dsystemd-system-service=false \
    -Dsystemd-user-service=false -Dtests=false -Ddbus-tests=false
step "build WirePlumber" ninja -C "$work/wireplumber/b"
step "install WirePlumber" ninja -C "$work/wireplumber/b" install

for f in bin/pipewire bin/wireplumber bin/pw-play; do
	[ -x "$prefix/$f" ] || die "$prefix/$f is missing"
done
say "installed $prefix"
