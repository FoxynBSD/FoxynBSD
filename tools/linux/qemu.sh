#!/bin/sh
#
# Boot a FoxynBSD kernel built by tools/linux/build.sh under QEMU + OVMF.
#
# Usage:
#	tools/linux/qemu.sh [--serial] [--kernel-only|--disk|--installed|--desktop] [KERNCONF] [-- qemu args]
#
# By default the whole system boots in a QEMU window: the root image
# from `build.sh rootfs` ($OBJDIR/root.iso) is attached as a second
# virtio disk and mounted as the root filesystem (cd9660), and the
# console is the video console (EFI framebuffer, then the kernel's
# syscons), with the serial console copied to the terminal.  It ends at
# a login prompt (root, no password).
#
#	--serial	no window: the serial console on this terminal (quit
#			with Ctrl-A X).  Also the default when there is no
#			graphical session ($DISPLAY, $WAYLAND_DISPLAY).
#	--kernel-only	boot the kernel without the root image; it stops at
#			the "mountroot>" prompt.
#	--disk		boot the writable disk image from `build.sh disk`
#			($OBJDIR/disk.img) instead of root.iso: the root is
#			UFS on its GPT partition (vbd1s0), mounted read-write,
#			and what is written there stays for the next boot.
#	--installed	boot a disk that foxyn-install installed FoxynBSD on
#			($OBJDIR/installed.img), alone: the firmware starts the
#			loader on its own ESP, without the ESP from build.sh.
#	--desktop-devices add a VGA framebuffer and xHCI USB keyboard and mouse
#			for desktop tests; this does not install a desktop.
#	--desktop	boot the desktop image from `build.sh desktop`
#			($OBJDIR/desktop.img) like --disk, with
#			--desktop-devices: the graphical session starts on
#			the window after the boot (vt9; Ctrl-Alt-F1 for the
#			console).
#	--gui, --root	the defaults, spelled out.
#	--firmware	print the OVMF images that would be used, and exit.
#
# The ESP tree from `build.sh esp` is handed to QEMU as a virtual FAT disk,
# so nothing needs root.
#
# Environment:
#	OBJDIR	same as build.sh
#	OVMF_CODE / OVMF_VARS	firmware images (default: what QEMU's firmware
#			descriptors in /usr/share/qemu/firmware name, else the
#			usual Arch, Debian/Ubuntu and Fedora paths)
#	MEM (default 2G), SMP (default 2)
#	ROOTISO		root image for --root (default $OBJDIR/root.iso)
#	DISK		disk image for --disk (default $OBJDIR/disk.img) and
#			--desktop (default $OBJDIR/desktop.img)
#	INSTALLED	disk image for --installed (default $OBJDIR/installed.img)
#	INSTALLED_BUS	virtio (default) or usb: --installed attaches the disk
#			as a USB stick on its own xHCI controller, as when
#			its image is written to one to boot a PC
#	ROOTDISK	optional disk image to attach as another virtio disk
#	NETDEV_OPTS	more options for the user-mode network (-netdev user),
#			starting with a comma: ",hostfwd=tcp::2222-:22"
#	MONITOR_SOCKET	optional QEMU monitor Unix socket for screenshots and
#			debugging; must not already exist (local trusted use)
#	SERIAL_LOG	headless: write the serial console to this file
#	QEMU_STATE	where the VM's ESP copy and UEFI variables are kept
#			(default $OBJDIR/qemu); give each VM that runs at the
#			same time its own: the ESP copy is remade at start
#	SERIAL_PIPE	headless: connect the serial console to the FIFOs
#			$SERIAL_PIPE.in and $SERIAL_PIPE.out (made by the caller),
#			so a script can both read the console and type on it
#	GUI=0/1		same as --serial / --gui
#	ROOT=0/1/disk/installed	same as --kernel-only / --root / --disk /
#			--installed
#	DISPLAY_BACKEND	QEMU -display backend for the window (default: gtk,
#			else sdl, whichever this QEMU has)
#
# Host packages: qemu-desktop (window) or qemu-base (serial only),
# edk2-ovmf; Debian/Ubuntu: qemu-system-x86 qemu-system-gui ovmf

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
GUI=${GUI:-}
QEMU_STATE=${QEMU_STATE:-$OBJDIR/qemu}
ROOT=${ROOT:-1}
FWONLY=0
DESKTOP_DEVICES=0

die() { echo "qemu.sh: $*" >&2; exit 1; }
usage() {
	die "usage: qemu.sh [--serial|--gui] [--kernel-only|--root|--disk|--installed|--desktop] [--firmware] [--desktop-devices] [KERNCONF] [-- qemu args]"
}

while :; do
	case ${1:-} in
	--gui)	GUI=1; shift ;;
	--serial|--no-gui) GUI=0; shift ;;
	--root)	ROOT=1; shift ;;
	--kernel-only|--no-root) ROOT=0; shift ;;
	--disk)	ROOT=disk; shift ;;
	--installed) ROOT=installed; shift ;;
	--firmware) FWONLY=1; shift ;;
	--desktop-devices) DESKTOP_DEVICES=1; shift ;;
	--desktop) ROOT=disk DESKTOP_DEVICES=1
		DISK=${DISK:-$OBJDIR/desktop.img}; shift ;;
	--)	break ;;
	-h|--help) usage ;;
	-*)	echo "qemu.sh: unknown option: $1" >&2; usage ;;
	*)	break ;;
	esac
done
[ -n "${ROOTISO:-}" ] && [ "$ROOT" = 0 ] && ROOT=1
ROOTISO=${ROOTISO:-$OBJDIR/root.iso}
DISK=${DISK:-$OBJDIR/disk.img}
INSTALLED=${INSTALLED:-$OBJDIR/installed.img}
CONF=X86_64_GENERIC
if [ $# -gt 0 ] && [ "$1" != "--" ]; then CONF=$1; shift; fi
[ "${1:-}" = "--" ] && shift

command -v qemu-system-x86_64 >/dev/null 2>&1 ||
    die "qemu-system-x86_64 not found (pacman -S qemu-desktop edk2-ovmf / apt install qemu-system-x86 qemu-system-gui ovmf)"

# A window by default, unless a script drives the serial console, there
# is no graphical session to open one in, or this QEMU has no window
# backend (Arch's qemu-base and Debian's qemu-system-x86 alone have
# none: qemu-desktop / qemu-system-gui add gtk and sdl).
nogui() {
	[ "$GUI" = 1 ] && die "$1; boot with --serial"
	GUI=0
	echo "qemu.sh: $1: serial console instead (Ctrl-A X quits)" >&2
}
if [ -n "${SERIAL_LOG:-}" ] || [ -n "${SERIAL_PIPE:-}" ] || [ "$FWONLY" = 1 ]; then
	GUI=0
elif [ "$GUI" != 0 ]; then
	if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
		nogui "no graphical session (\$DISPLAY, \$WAYLAND_DISPLAY)"
	elif [ -z "${DISPLAY_BACKEND:-}" ]; then
		backends=$(qemu-system-x86_64 -display help 2>/dev/null) || :
		for b in gtk sdl; do
			if printf '%s\n' "$backends" | grep -qx "$b"; then
				DISPLAY_BACKEND=$b
				break
			fi
		done
		[ -n "${DISPLAY_BACKEND:-}" ] ||
		    nogui "this QEMU has no gtk or sdl display (pacman -S qemu-desktop / apt install qemu-system-gui)"
	fi
	[ "$GUI" = 0 ] || GUI=1
fi

ESP=$OBJDIR/esp/$CONF
[ "$FWONLY" = 1 ] || [ "$ROOT" = installed ] || [ -f "$ESP/EFI/BOOT/BOOTX64.EFI" ] ||
    die "no ESP at $ESP; run tools/linux/build.sh esp $CONF"

find_fw() {
	for f in "$@"; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

# The firmware QEMU itself would pick: the JSON firmware descriptors
# (docs/interop/firmware.json) that edk2/ovmf packages install, read in
# QEMU's order (/etc first, then by file name).  Wanted: x86_64 UEFI for
# q35 in raw flash images, without Secure Boot, enrolled keys or SMM
# (which needs -machine smm=on and a secure pflash).  Prints
# "<code> <vars>".
fw_descriptor() {
	for f in $(ls /etc/qemu/firmware/*.json /usr/share/qemu/firmware/*.json \
	    2>/dev/null | awk -F/ '!seen[$NF]++'); do
		awk '
		/"executable"/ { ctx = "code" }
		/"nvram-template"/ { ctx = "vars" }
		/"filename"/ { v = $0; sub(/.*"filename" *: *"/, "", v); sub(/".*/, "", v); file[ctx] = v }
		/"format"/ && !/"raw"/ { bad = 1 }
		/"device"/ && !/"flash"/ { bad = 1 }
		/"uefi"/ { uefi = 1 }
		/"architecture"/ && /"x86_64"/ { x86 = 1 }
		/"pc-q35-/ { q35 = 1 }
		/"secure-boot"|"enrolled-keys"|"requires-smm"|"intel-tdx"|"amd-sev-snp"/ { bad = 1 }
		END {
			if (!bad && uefi && x86 && q35 && file["code"] != "" && file["vars"] != "")
				print file["code"], file["vars"]
		}' "$f" | while read -r code vars; do
			[ -f "$code" ] && [ -f "$vars" ] && echo "$code $vars"
		done
	done | head -n 1
}

if [ -z "${OVMF_CODE:-}" ] || [ -z "${OVMF_VARS:-}" ]; then
	set -- $(fw_descriptor) "$@"
	if [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -f "$1" ]; then
		OVMF_CODE=${OVMF_CODE:-$1} OVMF_VARS=${OVMF_VARS:-$2}
		shift 2
	fi
fi
# Without descriptors: the usual places (Arch, Debian/Ubuntu, Fedora).
OVMF_CODE=${OVMF_CODE:-$(find_fw \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/OVMF_CODE_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/x64/OVMF_CODE.fd)} ||
    die "OVMF firmware not found (pacman -S edk2-ovmf / apt install ovmf), or set OVMF_CODE and OVMF_VARS"
OVMF_VARS_TMPL=${OVMF_VARS:-$(find_fw \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/OVMF_VARS_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/ovmf/x64/OVMF_VARS.fd)} || die "OVMF vars template not found (set OVMF_VARS)"

if [ "$FWONLY" = 1 ]; then
	echo "OVMF_CODE=$OVMF_CODE"
	echo "OVMF_VARS=$OVMF_VARS_TMPL"
	exit 0
fi

[ "$ROOT" != 1 ] || [ -f "$ROOTISO" ] ||
    die "no root image at $ROOTISO; run tools/linux/build.sh (or boot with --kernel-only)"
[ "$ROOT" != disk ] || [ -f "$DISK" ] ||
    die "no disk image at $DISK; run tools/linux/build.sh disk"
[ "$ROOT" != installed ] || [ -f "$INSTALLED" ] ||
    die "no installed disk at $INSTALLED; install with foxyn-install (boot-test.sh --install)"

# The ESP from build.sh boots on the serial console with no root device.
# For --gui or --root, boot a hardlinked copy with its own loader.conf, so
# the build output is left alone and no file contents are duplicated.
if [ "$ROOT" = installed ]; then
	:	# The disk has its own ESP and loader.conf.
elif [ "$GUI" = 1 ] || [ "$ROOT" != 0 ]; then
	VESP=$QEMU_STATE/esp-$GUI$ROOT/$CONF
	rm -rf "$VESP"
	mkdir -p "$(dirname "$VESP")"
	cp -al "$ESP" "$VESP" 2>/dev/null || cp -a "$ESP" "$VESP"
	if [ "$GUI" = 1 ]; then
		rm -f "$VESP/boot/loader.conf"
		printf 'console="efi"\nautoboot_delay="5"\n' > "$VESP/boot/loader.conf"
	fi
	if [ "$ROOT" != 0 ]; then
		# Break the hardlink before appending to the serial loader.conf.
		if [ "$GUI" = 0 ]; then
			rm -f "$VESP/boot/loader.conf"
			cp "$ESP/boot/loader.conf" "$VESP/boot/loader.conf"
		fi
		# The ESP is the first virtio disk (vbd0), the image the second:
		# the whole of root.iso, or the first GPT partition of disk.img.
		if [ "$ROOT" = disk ]; then
			echo 'vfs.root.mountfrom="ufs:vbd1s0"' >> "$VESP/boot/loader.conf"
		else
			echo 'vfs.root.mountfrom="cd9660:vbd1"' >> "$VESP/boot/loader.conf"
		fi
		# While the userland is young: report where programs fault.
		echo 'machdep.print_user_faults="1"' >> "$VESP/boot/loader.conf"
	fi
	ESP=$VESP
fi

# Writable per-config copy of the UEFI variable store.
VARS=$QEMU_STATE/$CONF.vars.fd
mkdir -p "$QEMU_STATE"
[ -f "$VARS" ] || cp "$OVMF_VARS_TMPL" "$VARS"

ACCEL="-accel tcg"
if [ -w /dev/kvm ]; then
	ACCEL="-accel kvm -cpu host"
fi

# Console: interactive serial on the terminal, or (SERIAL_LOG=<file>) a
# headless run that writes the serial console to a file, for boot-test.sh.
if [ -n "${SERIAL_PIPE:-}" ]; then
	CONSOLE="-display none -monitor none -chardev pipe,id=con,path=$SERIAL_PIPE -serial chardev:con"
elif [ -n "${SERIAL_LOG:-}" ]; then
	CONSOLE="-display none -monitor none -serial file:$SERIAL_LOG"
elif [ "$GUI" = 1 ]; then
	CONSOLE="-display ${DISPLAY_BACKEND:-gtk} -vga std -serial stdio"
else
	CONSOLE="-nographic -serial mon:stdio"
fi

# Each disk gets a serial number from its file name (installed.img:
# "installed"), which the kernel shows as /dev/serno/<serial>: a disk is
# then named the same in whatever order it is attached, as installers
# write it into fstab and loader.conf.  At most 20 characters.  QEMU
# takes it on the virtio-blk device (-drive serial= is gone in QEMU 9).
serial() {
	basename "$1" | sed 's/\.[^.]*$//; s/[^A-Za-z0-9_-]/_/g' | cut -c1-20
}

# The first virtio disk (vbd0): the ESP from build.sh, served as a
# virtual FAT disk, or an installed disk, whose own ESP boots.
BOOTBUS=
if [ "$ROOT" = installed ]; then
	BOOTDRIVE=file=$INSTALLED,if=none,id=vd0,format=raw
	BOOTDEV=virtio-blk-pci,drive=vd0,serial=$(serial "$INSTALLED")
	ESP="$INSTALLED (its own ESP)"
	if [ "${INSTALLED_BUS:-virtio}" = usb ]; then
		BOOTDEV=usb-storage,bus=bootxhci.0,drive=vd0,removable=on,bootindex=0
		BOOTBUS="-device qemu-xhci,id=bootxhci"
		ESP="$INSTALLED (its own ESP, as a USB stick)"
	fi
else
	BOOTDRIVE=file=fat:$ESP,if=none,id=vd0,format=raw,readonly=on
	BOOTDEV=virtio-blk-pci,drive=vd0,serial=foxyn-esp
fi

# -nodefaults: q35 would otherwise add an empty AHCI CD drive, whose
# ATAPI emulation keeps the ahci(4) driver in timeouts for a minute.
set -- \
    -nodefaults \
    -machine q35 $ACCEL \
    -m "${MEM:-2G}" -smp "${SMP:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive "$BOOTDRIVE" $BOOTBUS -device "$BOOTDEV" \
    -netdev "user,id=n0${NETDEV_OPTS:-}" -device virtio-net-pci,netdev=n0 \
    $CONSOLE \
    "$@"

# Add a known framebuffer and USB input devices for desktop testing.
# GUI mode already selects VGA in CONSOLE; serial mode needs it explicitly.
if [ "$DESKTOP_DEVICES" = 1 ]; then
	if [ "$GUI" != 1 ]; then
		set -- "$@" -vga std
	fi
	set -- "$@" -device qemu-xhci,id=xhci \
	    -device usb-kbd,bus=xhci.0 -device usb-mouse,bus=xhci.0
fi

# An explicit monitor remains available in headless runs for screendump.
# Refuse an existing path rather than replacing an unrelated socket or file.
if [ -n "${MONITOR_SOCKET:-}" ]; then
	case $MONITOR_SOCKET in
	*,*) die "MONITOR_SOCKET must not contain a comma" ;;
	esac
	[ ! -e "$MONITOR_SOCKET" ] && [ ! -L "$MONITOR_SOCKET" ] ||
	    die "MONITOR_SOCKET already exists: $MONITOR_SOCKET"
	set -- "$@" -monitor "unix:$MONITOR_SOCKET,server=on,wait=off"
fi

# The root is the second virtio disk (vbd1).  The ISO goes on virtio-blk
# rather than as an AHCI CD: QEMU's ATAPI emulation times out with the
# ahci(4) driver ("Cannot copy rfis").
if [ "$ROOT" = 1 ]; then
	set -- "$@" -drive file="$ROOTISO",if=none,id=vd1,format=raw,readonly=on \
	    -device virtio-blk-pci,drive=vd1,serial="$(serial "$ROOTISO")"
elif [ "$ROOT" = disk ]; then
	set -- "$@" -drive file="$DISK",if=none,id=vd1,format=raw \
	    -device virtio-blk-pci,drive=vd1,serial="$(serial "$DISK")"
fi
if [ -n "${ROOTDISK:-}" ]; then
	set -- "$@" -drive file="$ROOTDISK",if=none,id=vd2,format=raw \
	    -device virtio-blk-pci,drive=vd2,serial="$(serial "$ROOTDISK")"
fi

if [ "$GUI" = 1 ]; then
	echo ">>> booting $CONF from $ESP in a QEMU window (close it to quit)" >&2
else
	echo ">>> booting $CONF from $ESP (Ctrl-A X to quit)" >&2
fi
exec qemu-system-x86_64 "$@"
