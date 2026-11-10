#!/bin/sh
# Build the GNUstep runtime from the revisions pinned by contrib/gnustep-*
# and contrib/libdispatch (Make, libobjc2, libdispatch, Base, GUI, Back)
# and install it in the Gershwin
# filesystem layout under /System, with its configuration in
# /System/Library/Preferences/GNUstep.conf, so that it does not mix with
# a GNUstep from DPorts under /usr/local/GNUstep.
#
# Run it as an unprivileged user who may write /System (root creates the
# directory for that user and makes the result root-owned afterwards; see
# foxyn-desktop(8)).  Needs fetch, sha256, gmake, cmake, ninja, clang19
# and lld from DPorts' llvm19, and the libraries GNUstep links with
# (libxml2, libxslt, libffi, gnutls, icu, cairo, libXft, ...).
#
# Everything is linked with lld: with GNU gold, libobjc2 got two
# DT_INIT_ARRAY entries and Objective-C programs aborted at exit in
# __deregister_frame_info_bases (docs/desktop-eau.md).
set -eu

make_rev=4e31a0310df5f0aa96ccd816d3b626e67c36f535
make_sha=2969f0b7a295173f07a72733ba5d50867aff66265515f49ed5d0806f07c0eeff
objc_rev=c9f4002ade04d755f2a0e6c83daf2738dca03759
objc_sha=1a3c5289207003bf2ba5503f670caaae910fa0ea59e08c22851fa13378dd71a0
dispatch_rev=95f592ab637c4d7916fa05d4d80cbc1ec7d0b2b8
dispatch_sha=3c3d9496b9698ea5240f0139f59d604599e612972cec43196de932a2b3e69d79
base_rev=5bda52220a6d67382c9851cdfd91d459bfd2b489
base_sha=62cc24fc653ad29e9716a041fce342c880521aab852cc4ce89549cc5526f74c7
gui_rev=8f804fd520c60800961e0bee072066f4bbadca94
gui_sha=c5bf21d719fcb690b0c0f29e16d0f72b61ca77c6686927bed18631a3533970f0
back_rev=bbcc3de7cab63b6e65944edf02f2bbef9d8a7bbd
back_sha=3c55d2da5ce436dd1892cd2aae1572b9b98259b2c19499b8e34028fb63992819
# libobjc2 fetches robin-map v1.4.0 with git when it is not installed;
# DPorts has 1.3.0.  Use the tag's archive instead.
robin_tag=v1.4.0
robin_sha=7930dbf9634acfc02686d87f615c0f4f33135948130b8922331c16d90a03250c

prefix=/System
conf=$prefix/Library/Preferences/GNUstep.conf
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patches=$script_dir/patches
jobs=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 2)}

say() { echo "build-gnustep: $*"; }
die() { echo "build-gnustep: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -d "$prefix" ] && [ -w "$prefix" ] || die "$prefix is not writable by $(id -un)"
for tool in fetch sha256 tar patch gmake cmake ninja clang19 clang++19 ld.lld19 pkgconf; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done
# DPorts' GNUstep has the same library names (libobjc.so.4.6) and
# headers in /usr/local/include/objc that would be used instead.
[ ! -e /usr/local/include/objc/runtime.h ] ||
    die "remove DPorts' libobjc2 first (pkg delete libobjc2)"
for p in gnustep-base-dragonfly-uuid.txt gnustep-base-kvm-configure.txt \
    gnustep-base-connection-null.patch libdispatch-dragonfly.txt; do
	[ -r "$patches/$p" ] || die "patch not found: $patches/$p"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/gnustep-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
log=$work/build.log

# get NAME URL SHA256: fetch and unpack an archive into $work/NAME.
get()
{
	fetch -qo "$work/$1.tar.gz" "$2" || die "cannot fetch $2"
	[ "$(sha256 -q "$work/$1.tar.gz")" = "$3" ] || die "$1: checksum mismatch"
	mkdir "$work/$1"
	tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components 1
	rm "$work/$1.tar.gz"
}

# step NAME CMD...: run a build step, show the log's tail on failure.
step()
{
	name=$1; shift
	say "$name"
	"$@" >> "$log" 2>&1 || { tail -n 25 "$log" >&2; die "$name failed"; }
}

gh=https://codeload.github.com
get make "$gh/gnustep/tools-make/tar.gz/$make_rev" "$make_sha"
get objc "$gh/gnustep/libobjc2/tar.gz/$objc_rev" "$objc_sha"
get robin-map "$gh/Tessil/robin-map/tar.gz/refs/tags/$robin_tag" "$robin_sha"
get dispatch "$gh/apple/swift-corelibs-libdispatch/tar.gz/$dispatch_rev" "$dispatch_sha"
get base "$gh/gnustep/libs-base/tar.gz/$base_rev" "$base_sha"
get gui "$gh/gnustep/libs-gui/tar.gz/$gui_rev" "$gui_sha"
get back "$gh/gnustep/libs-back/tar.gz/$back_rev" "$back_sha"
(cd "$work/base" &&
    patch -s -p1 < "$patches/gnustep-base-dragonfly-uuid.txt" &&
    patch -s -p1 < "$patches/gnustep-base-kvm-configure.txt" &&
    patch -s -p1 < "$patches/gnustep-base-connection-null.patch") ||
    die "GNUstep Base patches do not apply"
(cd "$work/dispatch" && patch -s -p1 < "$patches/libdispatch-dragonfly.txt") ||
    die "the libdispatch patch does not apply"

export CC=clang19 CXX=clang++19 OBJC=clang19 OBJCXX=clang++19
# The libraries from DPorts (libjpeg, libtiff, ...) are in /usr/local,
# which the compiler does not search by default.  The runpath finds the
# GNUstep libraries without GNUstep.sh's LD_LIBRARY_PATH; gnustep-make
# records these LDFLAGS, so applications built with it get it too.
libs=$prefix/Library/Libraries
export CPPFLAGS="-I/usr/local/include ${CPPFLAGS:-}"
export LDFLAGS="-fuse-ld=lld -L$libs -Wl,-rpath,$libs -L/usr/local/lib ${LDFLAGS:-}"
export PATH="$prefix/Library/Tools:$PATH"
make_configure()
{
	(cd "$work/make" && ./configure --with-layout=gershwin \
	    --with-config-file="$conf" --with-library-combo=ng-gnu-gnu \
	    --with-runtime-abi=gnustep-2.2 --enable-native-objc-exceptions \
	    --enable-objc-arc)
}

# Make first, so that libobjc2 installs where gnustep-config says; then
# again, so that it records libobjc2's flags.
step "configure GNUstep Make" sh -c "cd '$work/make' && ./configure --with-layout=gershwin --with-config-file='$conf'"
step "install GNUstep Make" gmake -C "$work/make" install
step "configure libobjc2" cmake -S "$work/objc" -B "$work/objc/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang19 \
    -DCMAKE_CXX_COMPILER=clang++19 -DCMAKE_ASM_COMPILER=clang19 \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    -DGNUSTEP_INSTALL_TYPE=SYSTEM -DTESTS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_tsl-robin-map=ON \
    -DFETCHCONTENT_SOURCE_DIR_ROBINMAP="$work/robin-map" \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON
step "build libobjc2" ninja -C "$work/objc/build"
step "install libobjc2" ninja -C "$work/objc/build" install
# libdispatch before Base, which uses it (and Gershwin's Menu).  It
# brings its own BlocksRuntime library; its Block.h would replace
# libobjc2's, so its block headers are not installed.  The header
# directories are absolute: CMake makes a relative PATH cache value
# relative to the current directory, not to the prefix.
step "configure libdispatch" cmake -S "$work/dispatch" -B "$work/dispatch/build" \
    -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang19 \
    -DCMAKE_CXX_COMPILER=clang++19 \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX="$prefix/Library" \
    -DCMAKE_INSTALL_LIBDIR=Libraries \
    -DCMAKE_INSTALL_MANDIR=Documentation/man \
    -DINSTALL_DISPATCH_HEADERS_DIR="$prefix/Library/Headers/dispatch" \
    -DINSTALL_OS_HEADERS_DIR="$prefix/Library/Headers/os" \
    -DINSTALL_BLOCK_HEADERS_DIR="$work/discard"
step "build libdispatch" ninja -C "$work/dispatch/build"
step "install libdispatch" ninja -C "$work/dispatch/build" install
step "reconfigure GNUstep Make" make_configure
step "reinstall GNUstep Make" gmake -C "$work/make" install

# GNUstep.sh reads unset variables.
set +u
# shellcheck disable=SC1091
. "$prefix/Library/Makefiles/GNUstep.sh"
set -u
# The libraries are the system's, not the (default) Local domain.
export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
step "configure GNUstep Base" sh -c "cd '$work/base' && ./configure"
step "build GNUstep Base" gmake -C "$work/base" -j "$jobs"
step "install GNUstep Base" gmake -C "$work/base" install
step "configure GNUstep GUI" sh -c "cd '$work/gui' && ./configure"
step "build GNUstep GUI" gmake -C "$work/gui" -j "$jobs"
step "install GNUstep GUI" gmake -C "$work/gui" install
step "configure GNUstep Back" sh -c "cd '$work/back' && ./configure --enable-graphics=cairo"
step "build GNUstep Back" gmake -C "$work/back" -j "$jobs"
step "install GNUstep Back" gmake -C "$work/back" install
say "installed in $prefix ($(gnustep-config --variable=LIBRARY_COMBO))"
