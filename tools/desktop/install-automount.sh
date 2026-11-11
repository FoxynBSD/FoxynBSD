#!/bin/sh
# Install automount(8) from the revision pinned by contrib/automount
# (vermaden's devd-based automounter, which Gershwin's FreeBSD images
# use), with patches/automount-dragonfly.txt, for the desktop's
# removable media: a USB stick or SD card is mounted under /media/<label>
# as the desktop user, shows on Workspace's desktop, can be ejected from
# Workspace, and is unmounted when it is pulled out.
#
#	install-automount.sh USER
#
# Installs /usr/local/sbin/automount (DragonFly's autofs has its own
# /usr/sbin/automount), /usr/local/etc/devd/automount.conf
# (automount-devd.conf) and, unless it exists, /usr/local/etc/automount.conf
# for USER (mounts as USER: vfs.usermount=1, nosuid, nodev).  Run as
# root.
set -eu

rev=b7a85de2c5491e6de7407a0dfdb4565af6658915
sha=c3e795d582a0390c0a7d6d9e69785caab8d6c3dc3ad92bcf507fc34693810ead
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patch_file=$script_dir/patches/automount-dragonfly.txt
devd_file=$script_dir/automount-devd.conf

say() { echo "install-automount: $*"; }
die() { echo "install-automount: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: $0 USER"
user=$1
[ "$(id -u)" = 0 ] || die "run as root"
group=$(id -gn "$user") || die "no user $user"
for f in "$patch_file" "$devd_file"; do
	[ -r "$f" ] || die "not found: $f"
done
for tool in fetch sha256 tar patch fstyp; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/automount.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
fetch -qo "$work/automount.tar.gz" \
    "https://codeload.github.com/vermaden/automount/tar.gz/$rev" ||
    die "cannot fetch automount"
[ "$(sha256 -q "$work/automount.tar.gz")" = "$sha" ] || die "checksum mismatch"
mkdir "$work/src"
tar -xzf "$work/automount.tar.gz" -C "$work/src" --strip-components 1
(cd "$work/src" && patch -s -p1 < "$patch_file") ||
    die "automount-dragonfly.txt does not apply"

install -d /usr/local/sbin /usr/local/etc/devd /media
install -m 555 "$work/src/automount" /usr/local/sbin/automount
install -m 444 "$devd_file" /usr/local/etc/devd/automount.conf
if [ ! -e /usr/local/etc/automount.conf ]; then
	cat > /usr/local/etc/automount.conf <<CONF
# automount(8): see /usr/local/sbin/automount for the options.
# Written by install-automount.sh for the desktop user.
USER="$user"
MNT_GROUP="$group"
MNT_PREFIX="/media"
NICENAMES=YES
MOUNT_AS_USER=YES
CONF
fi
say "installed /usr/local/sbin/automount for $user (/media)"
