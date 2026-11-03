# Building FoxynBSD on Linux (Omarchy / Arch)

`tools/linux/build.sh` builds FoxynBSD parts on a Linux host without a
DragonFly machine. It does not go through the top-level `buildworld` /
`buildkernel` targets. It first builds a few host tools with the Linux
compiler and then runs the build in `sys/` directly.

## Host packages

    sudo pacman -S --needed base-devel flex bison libbsd libtirpc
    # for the userland (sysroot is fine without them, libc needs them),
    # and xorriso to pack the root image:
    sudo pacman -S --needed clang lld compiler-rt libisoburn ncurses
    # for booting under QEMU:
    sudo pacman -S --needed qemu-base edk2-ovmf

On Debian/Ubuntu, the same set is
`build-essential flex bison libfl-dev libbsd-dev libtirpc-dev pkg-config
qemu-system-x86 ovmf`, plus `clang lld libclang-rt-18-dev xorriso` for
the userland.

## Usage

    tools/linux/build.sh tools              # bmake, config(8), mkdep, file2c, uudecode
    tools/linux/build.sh kernel             # X86_64_GENERIC, no modules
    tools/linux/build.sh kernel MINI64      # also LINT64 and VKERNEL64 (see below)
    tools/linux/build.sh modules            # all kernel modules
    tools/linux/build.sh sysroot            # stage DragonFly headers (for stand/ and the world)
    tools/linux/build.sh libc               # userland: lib/csu and lib/libc with clang
    tools/linux/build.sh base               # rtld, libs, init, sh and core utilities
    tools/linux/build.sh rootfs             # minimal root tree + root.iso (cd9660)
    tools/linux/build.sh world              # the whole userland, buildworld's order
    KEEP_GOING=1 tools/linux/build.sh world # same, listing every failed directory
    tools/linux/build.sh subdir bin/date    # build and install any world directory
    tools/linux/build.sh loader             # stand/ -> loader.efi
    WITH_MODULES=1 tools/linux/build.sh esp # EFI boot tree: loader + kernel (+ stripped .ko)
    tools/linux/qemu.sh                     # boot it under QEMU/OVMF on the serial console
    tools/linux/qemu.sh --gui               # same, in a QEMU window on the video console
    tools/linux/qemu.sh --root              # boot with root.iso as the root fs: login:
    tools/linux/boot-test.sh                # headless boot, passes at the mountroot> prompt
    tools/linux/boot-test.sh --root         # headless boot to the userland
    eval "$(tools/linux/build.sh env)"      # shell env for running make by hand

Output goes to `$OBJDIR`, which defaults to `~/.cache/foxynbsd`:

    $OBJDIR/host/bin/              host tools; cc is a gcc wrapper
    $OBJDIR/sys/<KERNCONF>/        kernel.debug, kernel.stripped, *.o
    $OBJDIR/sys/<KERNCONF>/<src>/sys/...   modules (*.ko)
    $OBJDIR/sysroot/usr/include/   DragonFly headers (mirrors include/Makefile "copies")
    $OBJDIR/stand/<src>/stand/...  libstand, dloader, libefi, loader.efi
    $OBJDIR/esp/<KERNCONF>/        EFI/BOOT/BOOTX64.EFI, boot/{dloader.rc,loader.conf,kernel/}
    $OBJDIR/world/<src>/...        world objects
    $OBJDIR/rootfs/, root.iso      minimal root tree and its ISO image

`host/bin` also holds what the stock `share/mk` rules expect from a BSD
host:

* `lorder` (the in-tree script, with `mktemp` templates GNU accepts) and
  a `tsort` shim, because GNU tsort has no `-q`;
* `rpcgen`, `unifdef` and `gencat` built from the tree (glibc's `gencat`
  writes a different catalog format);
* shims for `install` (drops `-o`/`-g`/`-f`, which need root, and
  `-C`/`-b`/`-B`, which GNU reads differently), `ln` (BSD
  `-h` is GNU `-n`) and `sed` (BSD `sed -i ""`);
* shims for `zic` (the host's, without the `-u`/`-g` owners that need
  root) and `find` (BSD `find -s`, sorted);
* buildworld's bootstrap tools for `share/`, built from the tree because
  the glibc programs of the same name write other formats or do not
  exist: `yacc` (byacc), `localedef`, `mkcsmapper`, `mkesdb`,
  `cap_mkdb` (with the tree's `db(3)` and `getcap(3)`) and `uuencode`;
* `xcc`, the userland compiler: host clang with
  `--target=x86_64-unknown-dragonfly`, the staged sysroot and `ld.lld`;
* `hostcc` and `hostc++`, the compilers for the helpers that run during
  the world build (ncurses' `make_keys`, gcc's generators, ...).
  `NXENV` is `nxenv`, an `env(1)` that turns `xcc` into `hostcc` and
  `xc++` into `hostc++`, so `share/mk`'s `${NXENV} ${CC}` and
  `${NXENV} ${CXX}` reach them.

`tools/linux/host-compat.h` supplies BSD macros (`__unused`, `NELEM`, ...)
and `srandomdev()` to those host tools, which also get libbsd and
`_GNU_SOURCE`.  When they only preprocess (`-E`), they get neither:
gcc builds `params.list` from cpp output.

## Kernel configurations

All four configurations in `sys/config` build: `X86_64_GENERIC`, `MINI64`
(no `INET`, so `build.sh kernel` leaves the modules' `depend` to
`build.sh modules`), `LINT64` and `VKERNEL64`. `LINT64`'s built-in
keymaps (`ATKBD_DFLT_KEYMAP`, `UKBD_DFLT_KEYMAP`) are made by the
tree's `kbdcontrol -L`, built for the host as `KBDCONTROL` (the kernel
makefiles default to `/usr/sbin/kbdcontrol`). A virtual kernel is a
DragonFly program, so `VKERNEL64` links with `xcc` against the
sysroot's libc and libpthread; `build.sh kernel VKERNEL64` builds those
first if they are missing.

## The userland (world)

`build.sh sysroot` does what buildworld's `includes` stage does. It copies
the kernel headers, creates the directory tree from
`etc/mtree/BSD.include.dist`, and runs `buildincludes` and
`installincludes` under `include/` and `lib/`. It also creates the
`BSD.root.dist` and `BSD.usr.dist` directory trees.

`build.sh libc` builds `lib/csu` and `lib/libc` with `xcc` and installs
them into the sysroot, the way buildworld's library stage does, so that
later links find them. The world is built with `CCVER=clang` on the make
command line, so `share/mk` adds neither gcc-only flags nor `-Werror`;
clang warnings are reported but do not fail the build.

How `xcc` stays inside the sysroot:

* clang's DragonFly driver looks for `crt*.o` and libraries in
  `<driver dir>/../lib`. On Linux that is the host's `/usr/lib`, with
  glibc's `crti.o`. `xcc` therefore runs a copy of the small `clang`
  driver binary from `$OBJDIR/xtool/bin`, with `xtool/lib` pointing into
  the sysroot.
* `-Wl,--undefined-version`: lld, unlike GNU ld, rejects version scripts
  that name symbols a configuration does not build (hesiod in libc).
* `ld-elf.so.2` finds its own `_DYNAMIC` PC-relative
  (`libexec/rtld-elf/x86_64/rtld_machdep.h`). The old
  `relocbase + &_DYNAMIC` relied on GNU ld leaving that GOT load alone;
  lld relaxes it to a `lea`, the base was added twice and every dynamic
  program died with SIGSEGV.
* Absolute symlinks installed into the sysroot
  (`/usr/lib/libc.so -> /lib/libc.so.8`) are made relative inside the
  sysroot; otherwise the linker silently falls back to `libc.a`.

Each world directory is built like buildworld does it: `make depend`, then
`make`, then `make install` into the sysroot. `depend` matters: the
generated `.depend` ties objects to their listed sources, so an arch `.S`
wins over a same-named `.c` (libm's `e_sqrtl`). Helpers that run during the
build (ncurses' `make_keys`) use the host compiler through `NXCC`, and
`_SHLIBDIRPREFIX` points at the sysroot so private headers such as
`usr/include/priv/ncurses` are found.

`build.sh base` builds the runtime linker (`libexec/rtld-elf`, on top of
`lib/libc_rtld`), libutil, libcrypt, the private ncurses, libedit, libm and
libkvm, libpam and its modules, then `init`, `sh`, `getty`, `login` and
the utilities that `rc.subr` and the `rc.d` scripts call (`rcorder`,
`awk`, `sed`, `grep`, `mount`, `fsck`, `ifconfig`, `sysctl`, ...).
`build.sh rootfs` copies those
programs and every shared library they load into `$OBJDIR/rootfs`, compiles
a few console terminal types (`xterm`, `vt100`, `vt220`, `cons25`, ...)
from the tree's `terminfo.src` with the host's `tic`, copies
`etc/login.conf` (read as text; no `cap_mkdb` needed), `etc/group` and
`etc/master.passwd`, and installs the tree's `/etc/rc`, `rc.subr`,
`rc.shutdown` and `rc.d` scripts. Its `fstab` and `rc.conf` follow the
live CD's (`nrelease/root/etc`): the root stays read-only
(`root_rw_mount="NO"`), and `rc.d/mountcritlocal` mounts tmpfs with
`-C` (copy the CD's files in) over `/var`, `/tmp` and `/root`.
`syslogd`, `newsyslog` and `devd` run, with the tree's `syslog.conf`,
`devd.conf` and `devd/*.conf`, and the
empty `/var/log` files that `etc/Makefile` installs. `cron` runs too,
with the tree's `crontab` minus the `atrun` job, whose program is not in
the image yet. The daily, weekly and monthly `periodic` jobs write their
reports to `/var/log/daily.log`, `weekly.log` and `monthly.log`, since
there is no mail program; the image's `/etc/periodic.conf` turns off the
checks for what it lacks (sendmail, HAMMER, accounting, ipfw, pf,
`locate`, `whatis`). The other services
whose programs the image lacks are off in `rc.conf`. One
image-only script, `/etc/rc.local.d/imagedb`, runs first: it mounts the
`/etc` tmpfs and builds the password database with `pwd_mkdb`, before
the devfs rules look up `root`. `/etc/rc.local`
prints `uname -a` and runs the ABI note tests. When `/etc/rc` exits,
init starts `getty` on the console from a
small `/etc/ttys` (serial `ttyd0`, or `ttyv0` with `--gui`), and `login`
checks passwords through PAM (`/etc/pam.d`, `pam_unix` and friends).
Root has no password and logs in to `/bin/sh`, since `csh` needs
libcrypto, which the image does not have yet. `build.sh rootfs` finally
packs the tree as a Rock Ridge ISO with xorriso. `qemu.sh --root` attaches
it as a second virtio disk and sets `vfs.root.mountfrom="cd9660:vbd1"`, so
no step needs root privileges and the root stays read-only. (Not as a CD:
QEMU's AHCI ATAPI emulation times out with the `ahci` driver.)

The compiler runtime (`crtbegin*.o`, `crtend*.o` and the `libgcc` helpers)
comes from the host's LLVM **compiler-rt** for now. The in-tree gcc
runtime (`gnu/lib/gcc120`) depends on gcc internals and does not build
with clang. The compiler-rt objects are OS-independent and PIC, and they
are installed where the driver looks (`usr/lib/gcc80`). Building
compiler-rt from source in the tree is a TODO.

C++ uses the tree's gcc 8 runtime. `build.sh base` builds the
exception unwinder (`gnu/lib/gcc80/libgcc_eh`) and `libstdc++` with
clang (`xc++`, which finds the headers in `/usr/include/c++/8.0`). The
unwinder includes a few gcc target headers: `tm.h` and `options.h` come
from `gnu/usr.bin/cc80/cc_prep`, and `insn-constants.h` gets the one
value it needs (`FIRST_PSEUDO_REG`, read from `i386.md`). The `xcc`
wrapper defines the `__LIBGCC_*` macros that gcc predefines for
`-fbuilding-libgcc`. Until `base` runs, `libgcc_eh` is an empty
archive, which is enough for C.

## The whole world

`build.sh world` builds everything buildworld builds into the sysroot, in
the order of `Makefile.inc1`: the startup libraries, the compiler's
unwinder and the `_prebuild_libs`, then every directory under `gnu/lib`,
`lib`, `libexec`, `bin`, `sbin`, `usr.bin`, `usr.sbin`, `gnu/usr.bin`
(binutils 2.27 and 2.34, gcc 8 and gcc 12), `games` and `share`. Each
top-level directory is walked one `SUBDIR` level deep. The first failing
directory stops the build; with `KEEP_GOING=1` the rest still builds and
the failed directories are listed at the end.

What differs from buildworld:

* The compiler runtime comes from the host's compiler-rt (see above), so
  `gnu/lib/gcc*/csu` and `libgcc` are not built, nor is
  `gnu/lib/gcc120`. The C++ runtime is gcc 8's, as in `base`.
* `libgcc_pic.a` is compiler-rt's builtins plus the unwinder built from
  `libgcc_eh`'s sources with default visibility, which is what
  `gnu/lib/gcc80/libgcc_pic` contains: dynamically linked C++ programs
  (gold, ...) take `_Unwind_*` from it for `libstdc++.so`. `libgcc_eh`
  is built in an object tree of its own (`$OBJDIR/world-libgcc`), so
  the stand-in gcc headers it needs never reach `gnu/usr.bin/cc80`.
* The sysroot doubles as `DESTDIR`; there is no separate installworld.

A few tree files carry Linux-host conditions that change nothing on
DragonFly: gcc 8's and 12's host configs (glibc declares `basename(3)`
for C++ and has no `<sys/sysctl.h>`), ncurses' `HAVE_BSD_CGETENT` for
`tic_next`, binutils' `genscripts.sh` (it takes its bash path only when
`genscrba.sh` exists, which the vendor import leaves out) and mpfr,
which leaves out its float128 functions when clang builds it. kdump's
`mkioctls` preprocesses with `$CC` (gcc by default, as before), and
`share/terminfo` builds its database in the object directory, which its
install target reads.

## Why the host `cc` is wrapped

The build calls `cc`, which is a wrapper around the host gcc. It makes the
Linux compiler act like DragonFly's base gcc for kernel code:

* `-Wl,--no-as-needed -Wl,-z,lazy -Wl,-z,norelro`: undo Debian/Ubuntu
  linker defaults. `--as-needed` drops
  the kernel's dynamic section, and the in-kernel module linker needs
  `_DYNAMIC` (`sys/kern/link_elf.c`).
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
| stand/ (loader.efi)           | builds; PE32+ EFI app, only R_X86_64_RELATIVE relocs |
| ESP tree + `qemu.sh` runner   | boots to `mountroot>` under QEMU + OVMF (verified in CI) |
| CI (`.github/workflows/linux-build.yml`) | kernel, loader, ESP and modules on Ubuntu; QEMU boot tests to `mountroot>` and, with the userland, through a root login on the serial console; all blocking |
| header sysroot via the tree's `includes` rules | works |
| userland: `lib/csu`, `libc.a` | build with clang (`xcc`) |
| userland: `libc.so.8`, linking programs | works (compiler-rt from the host); a test program links dynamically against `libc.so.8` with the DragonFly ELF note |
| userland: `rtld` (`ld-elf.so.2`), init, sh, base utilities | build with clang |
| root image (`root.iso`) and boot to `login:` | getty and login (PAM) under QEMU; CI logs in as root over the serial line and runs a command (blocking) |
| terminfo, tmpfs `/tmp` and `/var`, `login.conf`, users and groups (`pwd_mkdb` at boot) | in the root image (checked in CI) |
| the whole world (`build.sh world`): every library and program directory, binutils, gcc 8 and 12, `share/` data | builds |
| `/etc/rc` and `rc.d` from the tree | run at boot, tmpfs `/etc` and `/var` (CI lists commands the scripts miss) |
| C++ runtime (`libgcc_eh`, `libstdc++` from gcc 8) | builds with clang; `devd` links against it, and CI boots a test that throws and catches an exception |
| `syslogd`, `newsyslog`, `cron`, `devd` | run at boot; CI checks that a `logger` message reaches `/var/log/messages` and, after logging in, that `syslogd`, `cron` and `devd` are running |
| `periodic` | CI runs `periodic daily` after logging in and checks that the report in `/var/log/daily.log` is complete and that no script hit a missing command |
| rest of world, writable root | TODO (issue #9) |

QEMU path: OVMF runs `EFI/BOOT/BOOTX64.EFI` (our `loader.efi`). The
loader reads `boot/dloader.rc`, `boot/loader.conf` (serial console) and
`boot/kernel/kernel` from the ESP, which QEMU serves as a read-only
virtual FAT disk (`-drive file=fat:<dir>`). No root is needed. With no
root filesystem attached, the expected end of a kernel-only boot is the
`mountroot>` prompt. With `--root`, the kernel mounts `root.iso` instead
and init runs its `/etc/rc`. `ROOTDISK=<img>` attaches an extra virtio
disk.
