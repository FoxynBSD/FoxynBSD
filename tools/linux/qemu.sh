#!/bin/sh
#
# Boot a FoxynBSD kernel built by tools/linux/build.sh under QEMU + OVMF.
#
# Usage:
#	tools/linux/qemu.sh [KERNCONF] [-- extra qemu args]
#
# The ESP tree from `build.sh esp` is handed to QEMU as a virtual FAT disk,
# so nothing needs root.  With no root filesystem attached yet the kernel
# is expected to stop at the "mountroot>" prompt, which is the kernel-only
# milestone.  Quit QEMU with Ctrl-A X.
#
# Environment:
#	OBJDIR	same as build.sh
#	OVMF_CODE / OVMF_VARS	firmware images (auto-detected)
#	MEM (default 2G), SMP (default 2)
#	ROOTDISK	optional disk image to attach as a second virtio disk
#
# Host packages: qemu-base (or qemu-full) edk2-ovmf

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
CONF=X86_64_GENERIC
if [ $# -gt 0 ] && [ "$1" != "--" ]; then CONF=$1; shift; fi
[ "${1:-}" = "--" ] && shift

die() { echo "qemu.sh: $*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 ||
    die "qemu-system-x86_64 not found (pacman -S qemu-base edk2-ovmf)"

ESP=$OBJDIR/esp/$CONF
[ -f "$ESP/EFI/BOOT/BOOTX64.EFI" ] ||
    die "no ESP at $ESP; run tools/linux/build.sh esp $CONF"

find_fw() {
	for f in "$@"; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}
OVMF_CODE=${OVMF_CODE:-$(find_fw \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/OVMF_CODE_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/x64/OVMF_CODE.fd)} || die "OVMF firmware not found (pacman -S edk2-ovmf)"
OVMF_VARS_TMPL=${OVMF_VARS:-$(find_fw \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/OVMF_VARS_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/ovmf/x64/OVMF_VARS.fd)} || die "OVMF vars template not found"

# Writable per-config copy of the UEFI variable store.
VARS=$OBJDIR/qemu/$CONF.vars.fd
mkdir -p "$OBJDIR/qemu"
[ -f "$VARS" ] || cp "$OVMF_VARS_TMPL" "$VARS"

ACCEL="-accel tcg"
if [ -w /dev/kvm ]; then
	ACCEL="-accel kvm -cpu host"
fi

set -- \
    -machine q35 $ACCEL \
    -m "${MEM:-2G}" -smp "${SMP:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file=fat:"$ESP",format=raw,if=virtio,readonly=on \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -serial mon:stdio \
    "$@"

if [ -n "${ROOTDISK:-}" ]; then
	set -- "$@" -drive file="$ROOTDISK",if=virtio,format=raw
fi

echo ">>> booting $CONF from $ESP (Ctrl-A X to quit)" >&2
exec qemu-system-x86_64 "$@"
