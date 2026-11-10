#!/bin/sh
# Build Gershwin's Workspace (the file manager and desktop) from the
# revision pinned by contrib/gershwin-workspace and install it in
# /System, where its makefiles put it (System domain).
#
# Needs the GNUstep that build-gnustep.sh installs in /System (with
# libdispatch), run as the same unprivileged user while /System is
# writable by that user.  Uses dbus and SQLite (GWMetadata) from DPorts.
set -eu

revision=817491d7dc7de207c3e71938b69f0f6d56000a81
sha256=0c8f52f95a5873c26c548e917bee6c67557955fd92781712e4e45c7fea29dd80
prefix=/System
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# DragonFly: extattr(2) without extattr_list_file, kinfo_proc from
# <sys/user.h>, and its process and disk interfaces.
patch_file=$script_dir/patches/workspace-dragonfly.txt

say() { echo "build-workspace: $*"; }
die() { echo "build-workspace: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0"
[ "$(id -u)" != 0 ] || die "run as an unprivileged user"
[ -w "$prefix/Library/Libraries" ] || die "$prefix is not writable by $(id -un)"
[ -r "$prefix/Library/Makefiles/GNUstep.sh" ] ||
    die "no GNUstep in $prefix: run build-gnustep.sh first"
[ -r "$patch_file" ] || die "patch not found: $patch_file"
for tool in fetch sha256 tar patch gmake clang19 pkgconf; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/workspace-build.XXXXXXXX")
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
    "https://codeload.github.com/gershwin-desktop/gershwin-workspace/tar.gz/$revision" ||
    die "cannot fetch the source"
[ "$(sha256 -q "$work/source.tar.gz")" = "$sha256" ] || die "source checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1
src=$work/src
(cd "$src" && patch -s -p1 < "$patch_file") || die "the Workspace patch does not apply"
# The video thumbnailer needs an AVFoundation library, which is not built
# here; the makefile's optional GNUmakefile.local leaves it out.
echo 'SUBPROJECTS = ImageThumbnailer' > "$src/Workspace/Thumbnailer/GNUmakefile.local"

set +u
# shellcheck disable=SC1091
. "$prefix/Library/Makefiles/GNUstep.sh"
set -u
export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
# dbus and the other DPorts libraries are in /usr/local.
export CPPFLAGS="-I/usr/local/include ${CPPFLAGS:-}"
export LDFLAGS="-L/usr/local/lib ${LDFLAGS:-}"
# The file system watcher: kqueue, the native one.  With DPorts'
# libinotify installed (PipeWire uses it) configure also builds the
# inotify one, which then fails to link (inotify_rm_watch), and its
# --without-inotify is overridden by its header check: hide the header.
step "configure Workspace" sh -c "cd '$src' && ./configure ac_cv_header_sys_inotify_h=no"
step "build Workspace" gmake -C "$src"
step "install Workspace" gmake -C "$src" install
app=$prefix/Applications/Workspace.app
[ -x "$app/Workspace" ] || die "Workspace is missing from $app"
say "installed $app"
