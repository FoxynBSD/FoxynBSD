# Building FoxynBSD on Linux (Omarchy / Arch)

`tools/linux/build.sh` builds FoxynBSD parts on a Linux host without a
DragonFly machine. It does not go through the top-level `buildworld` /
`buildkernel` targets. It first builds a few host tools with the Linux
compiler and then runs the build in `sys/` directly.

## Host packages

    sudo pacman -S --needed base-devel flex bison libbsd
    # for booting under QEMU:
    sudo pacman -S --needed qemu-base edk2-ovmf

On Debian/Ubuntu, the same set is
`build-essential flex bison libfl-dev libbsd-dev pkg-config qemu-system-x86 ovmf`.

## Usage

    tools/linux/build.sh tools              # bmake, config(8), mkdep, file2c, uudecode
    tools/linux/build.sh kernel             # X86_64_GENERIC, no modules
    tools/linux/build.sh kernel MINI64
    tools/linux/build.sh modules            # all kernel modules
    tools/linux/build.sh sysroot            # stage DragonFly headers (for stand/, later world)
    tools/linux/build.sh loader             # stand/ -> loader.efi
    WITH_MODULES=1 tools/linux/build.sh esp # EFI boot tree: loader + kernel (+ stripped .ko)
    tools/linux/qemu.sh                     # boot it under QEMU/OVMF on the serial console
    tools/linux/boot-test.sh                # headless boot, passes at the mountroot> prompt
    eval "$(tools/linux/build.sh env)"      # shell env for running make by hand

Output goes to `$OBJDIR`, which defaults to `~/.cache/foxynbsd`:

    $OBJDIR/host/bin/              host tools; cc is a gcc wrapper
    $OBJDIR/sys/<KERNCONF>/        kernel.debug, kernel.stripped, *.o
    $OBJDIR/sys/<KERNCONF>/<src>/sys/...   modules (*.ko)
    $OBJDIR/sysroot/usr/include/   DragonFly headers (mirrors include/Makefile "copies")
    $OBJDIR/stand/<src>/stand/...  libstand, dloader, libefi, loader.efi
    $OBJDIR/esp/<KERNCONF>/        EFI/BOOT/BOOTX64.EFI, boot/{dloader.rc,loader.conf,kernel/}

`lorder` (the in-tree script) and a `tsort` shim (GNU tsort has no `-q`)
also go into `host/bin`, because `bsd.lib.mk` orders archives with them.

## Why the host `cc` is wrapped

The build calls `cc`, which is a wrapper around the host gcc. It makes the
Linux compiler act like DragonFly's base gcc for kernel code:

* `-fno-pie -fno-pic -no-pie`: Arch builds PIE by default, which clashes
  with `-mcmodel=kernel`.
* `-fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE`:
  turns off Linux distro hardening defaults.
* `-U__linux__ ... -D__DragonFly__`: without this, ACPICA picks
  `aclinux.h`, and the headers that check `__DragonFly__` take the
  wrong branch.
* `-Werror=format-security`: Debian and Ubuntu gcc turn this on by
  default, so it is on everywhere and the Omarchy build fails on the same
  format-string bugs as CI.
* `-Wno-error=` for `dangling-pointer`, `enum-int-mismatch`,
  `maybe-uninitialized` and `array-bounds`: these are diagnostics from
  compilers newer than the in-tree gcc120. They are still printed but
  don't stop `-Werror`.

## Status

| Piece                         | Linux host |
|-------------------------------|------------|
| host tools (bmake, config...) | works      |
| kernel X86_64_GENERIC         | builds and links |
| kernel modules (682 .ko)      | build      |
| header sysroot               | staged     |
| stand/ (loader.efi)           | builds; PE32+ EFI app, only R_X86_64_RELATIVE relocs |
| ESP tree + `qemu.sh` runner   | written; boot not verified yet |
| CI (`.github/workflows/linux-build.yml`) | kernel, loader, ESP and modules on Ubuntu; QEMU boot test is non-blocking until it passes |
| world (userland)              | TODO: needs a cross toolchain targeting DragonFly |

QEMU path: OVMF runs `EFI/BOOT/BOOTX64.EFI` (our `loader.efi`). The
loader reads `boot/dloader.rc`, `boot/loader.conf` (serial console) and
`boot/kernel/kernel` from the ESP, which QEMU serves as a read-only
virtual FAT disk (`-drive file=fat:<dir>`). No root is needed. With no
root filesystem attached, the expected end of a kernel-only boot is the
`mountroot>` prompt. `ROOTDISK=<img>` attaches a second disk for when a
userland image exists.
