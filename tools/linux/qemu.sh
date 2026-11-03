#!/bin/sh
#
# Boot a FoxynBSD kernel built by tools/linux/build.sh under QEMU + OVMF.
#
# Usage:
#	tools/linux/qemu.sh [--gui] [--root] [KERNCONF] [-- extra qemu args]
#
#	--gui	open a QEMU window and use the video console (EFI framebuffer,
#		then the kernel's syscons) instead of the serial console.
#		Serial output is still copied to the terminal.
#	--root	attach the root image from `build.sh rootfs` ($OBJDIR/root.iso)
#		as a second virtio disk and mount it as the root filesystem
#		(cd9660): boots to a shell.
#
# The ESP tree from `build.sh esp` is handed to QEMU as a virtual FAT disk,
# so nothing needs root.  Without --root the kernel is expected to stop at
# the "mountroot>" prompt, which is the kernel-only milestone.  Quit QEMU
# with Ctrl-A X.
#
# Environment:
#	OBJDIR	same as build.sh
#	OVMF_CODE / OVMF_VARS	firmware images (auto-detected)
#	MEM (default 2G), SMP (default 2)
#	ROOTISO		root image for --root (default $OBJDIR/root.iso)
#	ROOTDISK	optional disk image to attach as a second virtio disk
#	SERIAL_LOG	headless: write the serial console to this file
#	GUI=1		same as --gui
#	DISPLAY_BACKEND	QEMU -display backend for --gui (default gtk)
#
# Host packages: qemu-base (or qemu-full) edk2-ovmf

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
GUI=${GUI:-0}
ROOT=0

die() { echo "qemu.sh: $*" >&2; exit 1; }
usage() {
	die "usage: qemu.sh [--gui] [--root] [KERNCONF] [-- qemu args]"
}

while :; do
	case ${1:-} in
	--gui)	GUI=1; shift ;;
	--root)	ROOT=1; shift ;;
	--)	break ;;
	-h|--help) usage ;;
	-*)	echo "qemu.sh: unknown option: $1" >&2; usage ;;
	*)	break ;;
	esac
done
[ -n "${ROOTISO:-}" ] && ROOT=1
ROOTISO=${ROOTISO:-$OBJDIR/root.iso}
CONF=X86_64_GENERIC
if [ $# -gt 0 ] && [ "$1" != "--" ]; then CONF=$1; shift; fi
[ "${1:-}" = "--" ] && shift

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
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/x64/OVMF_CODE.fd)} || die "OVMF firmware not found (pacman -S edk2-ovmf)"
OVMF_VARS_TMPL=${OVMF_VARS:-$(find_fw \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/OVMF_VARS_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/ovmf/x64/OVMF_VARS.fd)} || die "OVMF vars template not found"

[ "$ROOT" = 0 ] || [ -f "$ROOTISO" ] ||
    die "no root image at $ROOTISO; run tools/linux/build.sh rootfs"

# The ESP from build.sh boots on the serial console with no root device.
# For --gui or --root, boot a hardlinked copy with its own loader.conf, so
# the build output is left alone and no file contents are duplicated.
if [ "$GUI" = 1 ] || [ "$ROOT" = 1 ]; then
	VESP=$OBJDIR/qemu/esp-$GUI$ROOT/$CONF
	rm -rf "$VESP"
	mkdir -p "$(dirname "$VESP")"
	cp -al "$ESP" "$VESP" 2>/dev/null || cp -a "$ESP" "$VESP"
	if [ "$GUI" = 1 ]; then
		rm -f "$VESP/boot/loader.conf"
		printf 'console="efi"\nautoboot_delay="5"\n' > "$VESP/boot/loader.conf"
	fi
	if [ "$ROOT" = 1 ]; then
		# Break the hardlink before appending to the serial loader.conf.
		if [ "$GUI" = 0 ]; then
			rm -f "$VESP/boot/loader.conf"
			cp "$ESP/boot/loader.conf" "$VESP/boot/loader.conf"
		fi
		# The ESP is the first virtio disk (vbd0), the image the second.
		echo 'vfs.root.mountfrom="cd9660:vbd1"' >> "$VESP/boot/loader.conf"
		# While the userland is young: report where programs fault.
		echo 'machdep.print_user_faults="1"' >> "$VESP/boot/loader.conf"
	fi
	ESP=$VESP
fi

# Writable per-config copy of the UEFI variable store.
VARS=$OBJDIR/qemu/$CONF.vars.fd
mkdir -p "$OBJDIR/qemu"
[ -f "$VARS" ] || cp "$OVMF_VARS_TMPL" "$VARS"

ACCEL="-accel tcg"
if [ -w /dev/kvm ]; then
	ACCEL="-accel kvm -cpu host"
fi

# Console: interactive serial on the terminal, or (SERIAL_LOG=<file>) a
# headless run that writes the serial console to a file, for boot-test.sh.
if [ -n "${SERIAL_LOG:-}" ]; then
	CONSOLE="-display none -monitor none -serial file:$SERIAL_LOG"
elif [ "$GUI" = 1 ]; then
	CONSOLE="-display ${DISPLAY_BACKEND:-gtk} -vga std -serial stdio"
else
	CONSOLE="-nographic -serial mon:stdio"
fi

# -nodefaults: q35 would otherwise add an empty AHCI CD drive, whose
# ATAPI emulation keeps the ahci(4) driver in timeouts for a minute.
set -- \
    -nodefaults \
    -machine q35 $ACCEL \
    -m "${MEM:-2G}" -smp "${SMP:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file=fat:"$ESP",format=raw,if=virtio,readonly=on \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    $CONSOLE \
    "$@"

# The ISO goes on virtio-blk rather than as an AHCI CD: QEMU's ATAPI
# emulation times out with the ahci(4) driver ("Cannot copy rfis").
if [ "$ROOT" = 1 ]; then
	set -- "$@" -drive file="$ROOTISO",if=virtio,format=raw,readonly=on
fi
if [ -n "${ROOTDISK:-}" ]; then
	set -- "$@" -drive file="$ROOTDISK",if=virtio,format=raw
fi

if [ "$GUI" = 1 ]; then
	echo ">>> booting $CONF from $ESP in a QEMU window (close it to quit)" >&2
else
	echo ">>> booting $CONF from $ESP (Ctrl-A X to quit)" >&2
fi
exec qemu-system-x86_64 "$@"
