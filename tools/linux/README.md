# Building FoxynBSD on Linux

`tools/linux/build.sh` builds FoxynBSD on a Linux host, without a
DragonFly machine: the kernel and its modules, the EFI loader, the
userland, and a root image that boots under QEMU. It does not use the
top-level `buildworld` / `buildkernel` targets, which expect a DragonFly
host. It builds a few host tools with the Linux compiler, then runs the
tree's own makefiles (`sys/`, `lib/`, `bin/`, ...) with them.

## Supported hosts

| Host | Package manager | How it is checked |
|------|-----------------|-------------------|
| Ubuntu 24.04 LTS | apt | CI on every push to `dev` (`linux-build.yml`): kernel, all modules, loader, userland, root image, QEMU boot to a root login, whole world |
| Arch Linux | pacman | CI in an `archlinux:latest` container (`linux-hosts.yml`): kernel and all modules built with clang, userland, ELF audit, QEMU boot to a root login |
| Debian stable | apt | CI in a `debian:stable` container (`linux-hosts.yml`): kernel and all modules with gcc, userland, ELF audit, QEMU boot to a root login |
| Omarchy | pacman | where the build is developed; it uses the Arch packages and toolchain, so the Arch job covers its packages, but nothing in CI runs Omarchy itself |

`linux-hosts.yml` runs when `tools/linux`, the compiler runtime or the
workflow changes, weekly, and by hand. On other distributions, `build.sh
doctor` tells you which tools are missing.

## Host packages

Arch Linux and Omarchy:

    sudo pacman -S --needed base-devel flex bison libbsd libtirpc   # tools, kernel
    sudo pacman -S --needed clang lld libisoburn ncurses            # userland, root image
    sudo pacman -S --needed qemu-base edk2-ovmf                     # boot under QEMU

Debian and Ubuntu:

    sudo apt install build-essential flex bison libfl-dev libbsd-dev libtirpc-dev pkg-config
    sudo apt install clang lld xorriso ncurses-bin
    sudo apt install qemu-system-x86 ovmf

LLVM's `compiler-rt` package is not needed: the compiler runtime is built
from `contrib/compiler-rt`. Check a host with:

    tools/linux/build.sh doctor

It reports the distribution, `/bin/sh` and `awk`, the host gcc's default
PIE and stack protector settings, the clang version, the OVMF firmware
QEMU would use, whether KVM is usable, and the packages to install for
anything missing. It exits with status 1 if something is missing.

## Usage

    tools/linux/build.sh doctor             # check the host
    tools/linux/build.sh tools              # host tools: bmake, config(8), mkdep, the shims, xcc, kcc
    tools/linux/build.sh kernel             # X86_64_GENERIC
    tools/linux/build.sh kernel MINI64      # also LINT64 and VKERNEL64 (see below)
    tools/linux/build.sh modules            # all kernel modules
    MODULES_OVERRIDE="vfs/udf vfs/ext2fs" tools/linux/build.sh modules   # only these
    KERNCC=clang tools/linux/build.sh kernel  # kernel (and modules) with clang
    tools/linux/build.sh sysroot            # stage DragonFly headers (for stand/ and the world)
    tools/linux/build.sh libc               # compiler runtime, lib/csu and lib/libc with clang
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
    tools/linux/qemu.sh --firmware          # print the OVMF images qemu.sh would use
    tools/linux/boot-test.sh                # headless boot, passes at the mountroot> prompt
    tools/linux/boot-test.sh --root         # headless boot to the userland, logs in as root
    tools/linux/check-boot-log.sh all       # check what the --root boot did (see Tests)
    tools/linux/elf-audit.sh "$OBJDIR/rootfs" "$OBJDIR/sysroot"   # host contamination audit
    eval "$(tools/linux/build.sh env)"      # shell env for running make by hand

A first boot from scratch:

    tools/linux/build.sh tools && tools/linux/build.sh kernel &&
      tools/linux/build.sh loader && tools/linux/build.sh esp &&
      tools/linux/build.sh rootfs        # runs sysroot, libc and base as needed
    tools/linux/qemu.sh --root           # log in as root, no password; Ctrl-A X quits

Output goes to `$OBJDIR`, which defaults to `~/.cache/foxynbsd`:

    $OBJDIR/host/bin/              host tools, shims and compiler wrappers
    $OBJDIR/xtool/                 the clang driver copy that xcc runs (see below)
    $OBJDIR/sys/<KERNCONF>/        kernel.debug, kernel.stripped, *.o
    $OBJDIR/sys/<KERNCONF>/<src>/sys/...   modules (*.ko)
    $OBJDIR/sysroot/               the target tree: headers, libraries, programs
    $OBJDIR/stand/<src>/stand/...  libstand, dloader, libefi, loader.efi
    $OBJDIR/esp/<KERNCONF>/        EFI/BOOT/BOOTX64.EFI, boot/{dloader.rc,loader.conf,kernel/}
    $OBJDIR/world/<src>/...        world objects
    $OBJDIR/rootfs/, root.iso      minimal root tree and its ISO image
    $OBJDIR/qemu/                  serial logs, UEFI variable store

The build needs no root privileges. It takes a few GB for the kernel,
modules and base image and much more for the whole world; with `$HOME`
on a tmpfs, point `OBJDIR` at a disk.

Environment: `OBJDIR`, `JOBS` (default: `nproc`), `HOST_CC`/`HOST_CFLAGS`
(host tools, default `gcc`/`-O2`), `HOST_GCC` (kernel gcc), `HOST_CLANG`
(userland and `KERNCC=clang` compiler), `KERNCC` (`gcc` or `clang`),
`MODULES_OVERRIDE`, `KEEP_GOING`, `WITH_MODULES`; for QEMU `OVMF_CODE`,
`OVMF_VARS`, `MEM`, `SMP`, `ROOTISO`, `ROOTDISK`, `BOOT_TIMEOUT`.

## Toolchain architecture

There are three kinds of compiled code, each with its own compiler:

| Code | Compiler | Headers and libraries |
|------|----------|-----------------------|
| host tools (bmake, config, yacc, zic, the generators that run during the build) | host gcc: `$HOST_CC`, and `hostcc`/`hostc++` inside the world build | Linux's, plus libbsd and `host-compat.h` |
| kernel, modules, EFI loader | `cc`: host gcc through a wrapper (default); or `kcc`: host clang for `x86_64-unknown-dragonfly` (`KERNCC=clang`) | the tree's `sys/` and `-nostdinc`; the loader uses the sysroot headers |
| userland (libraries, programs, the virtual kernel's link) | `xcc`/`xc++`: host clang for `x86_64-unknown-dragonfly`, ld.lld | only the sysroot |

### Host tools

`host/bin` holds what the stock `share/mk` rules expect from a BSD host:

* `lorder` (the in-tree script, with `mktemp` templates GNU accepts) and
  a `tsort` shim, because GNU tsort has no `-q`;
* `rpcgen`, `unifdef` and `gencat` built from the tree (glibc's `gencat`
  writes a different catalog format);
* shims for `install` (drops `-o`/`-g`/`-f`, which need root, and
  `-C`/`-b`/`-B`, which GNU reads differently), `ln` (BSD `-h` is GNU
  `-n`), `sed` (BSD `sed -i ""`) and `find` (BSD `find -s`, sorted);
* buildworld's bootstrap tools, built from the tree because the glibc
  programs of the same name write other formats, take other options or do
  not exist: `yacc` (byacc), `zic`, `localedef`, `mkcsmapper`, `mkesdb`,
  `cap_mkdb` (with the tree's `db(3)` and `getcap(3)`), `uuencode` and
  `kbdcontrol` (for `LINT64`'s built-in keymaps);
* the compiler wrappers `cc`, `kcc`, `xcc`, `xc++`, `hostcc`, `hostc++`
  and `nxenv`.

The shims find the programs they wrap when `build.sh tools` runs, in
`$PATH` and then in `/usr/sbin` and `/sbin` (Debian keeps some tools
there), so no distribution's paths are written into the script. `zic`
is the tree's, not the host's, for the same reason buildworld builds it:
the hosts' tzcode releases differ in their options.

`tools/linux/host-compat.h` supplies BSD macros (`__unused`, `__pure`,
`NELEM`, ...) and `srandomdev()` to the host tools, which also get libbsd
and `_GNU_SOURCE`. When they only preprocess (`-E`), they get neither:
gcc builds `params.list` from cpp output.

### The kernel compiler (`cc`, `kcc`)

By default the kernel and modules are built by `cc`, a wrapper around the
host gcc that makes it act like DragonFly's base gcc. Its flags are of two
kinds.

What the DragonFly kernel needs, whatever the host defaults are:

* `-fno-pie -fno-pic -no-pie`: the kernel is linked at a fixed address
  with `-mcmodel=kernel`; Arch, Debian and Ubuntu gcc build PIE by
  default.
* `-U__linux__ ... -D__DragonFly__`: the predefines of DragonFly's gcc.
  Without them, ACPICA picks `aclinux.h`, and the headers that check
  `__DragonFly__` take the wrong branch.
* `-Wl,--no-as-needed`: Debian and Ubuntu link with `--as-needed`, which
  drops the kernel's dynamic section; the in-kernel module linker needs
  `_DYNAMIC` (`sys/kern/link_elf.c`).

Host hardening defaults that a kernel cannot use, because it has none of
the runtime support they rely on (CET setup, stack-clash probing, a
fortify library): `-fcf-protection=none -fno-stack-clash-protection
-U_FORTIFY_SOURCE`, and `-Wl,-z,lazy -Wl,-z,norelro` against Ubuntu's
`-z now`/relro. The kernel's own protections are chosen by its makefiles
as on DragonFly: stack protection is off in `kern.mk` (as in a native
build), and the Spectre v2 retpolines (`-mindirect-branch=thunk-inline`)
stay on.

Also: `-Wformat -Werror=format-security` (Debian and Ubuntu gcc turn
this on, so it is on everywhere and every host fails on the same
format-string bugs), and `-Wno-error=` for the warnings of gcc releases
newer than the in-tree gcc 12 (`dangling-pointer`, `enum-int-mismatch`,
`maybe-uninitialized`, `array-bounds`). They are still printed. Only the
ones the host gcc knows are passed: gcc rejects `-Wno-error=` for a
warning it does not have, so an older gcc would otherwise fail every
file.

With `KERNCC=clang`, the kernel and modules are built by `kcc`: the
host clang with `--target=x86_64-unknown-dragonfly`. The target supplies
the right predefines and no PIE or hardening defaults, so nothing has to
be undone, and the kernel makefiles' own clang settings (`CCVER=clang`)
apply. `kcc` changes two of them: it drops `-no-integrated-as` (only
clang's integrated assembler knows the target) and turns gcc's
`-mindirect-branch=thunk-inline` into clang's `-mretpoline`, so the
Spectre v2 mitigation stays on. It links through GNU ld (`-fuse-ld=bfd`),
like gcc. With `CCVER=clang` the makefiles do not add `-Werror`; clang's
warnings are printed (about 1500 for `X86_64_GENERIC`, mostly
`single-bit-bitfield-constant-conversion`, `address-of-packed-member` and
`string-plus-int`).

Status of the clang kernel: `X86_64_GENERIC` and all 682 modules build
with clang 23 (Omarchy). The kernel boots under QEMU to a root login and
passes every boot-log check, including loading and unloading clang-built
modules. Two tree files needed a clang spelling, without changing what gcc
gets: amdgpu's floating-point objects (`-mno-soft-float
-mstack-alignment=8` for gcc's `-mhard-float
-mpreferred-stack-boundary=3`) and drm's `atomic64_inc_return`, which
passed the `atomic64_t` struct rather than its counter to an atomic
builtin. It is opt-in until the Arch CI job has run it on another clang
release; gcc stays the default and the fallback. Linking with ld.lld instead of GNU ld (`kcc
-fuse-ld=lld`) also produces a kernel that boots, but lld lays out the
kernel linker script's program headers differently (`PT_INTERP` covering
the text, a larger `PT_DYNAMIC`), and module loading has not been tested
with it, so it is not used.

The in-tree gcc 12 (`gnu/usr.bin/cc120`) as the kernel compiler is not
built on Linux: building it as a cross compiler for the host would need
gcc's own configure-time host/target separation, which the tree's
makefiles (written for a native DragonFly build) do not have. clang for
the DragonFly target gives the same independence from the host's
distribution defaults with no extra compiler build.

### The userland compiler (`xcc`, `xc++`)

`xcc` is the host clang with `--target=x86_64-unknown-dragonfly`,
`--sysroot=$OBJDIR/sysroot` and ld.lld. It never sees a Linux header or
library:

* clang's DragonFly driver looks for `crt*.o` and libraries in
  `<driver dir>/../lib`. On Linux that is the host's `/usr/lib`, with
  glibc's `crti.o`. `xcc` therefore runs a copy of the small `clang`
  driver binary from `$OBJDIR/xtool/bin`, with `xtool/lib` pointing into
  the sysroot.
* `-nobuiltininc -idirafter <clang resource dir>/include`: the sysroot's
  `/usr/include` first and clang's own headers (intrinsics,
  `stdatomic.h`) after it, the order DragonFly's base gcc uses. This is
  the only thing taken from the host's clang installation, and the only
  host directory the sysroot links to (`usr/lib/clang`).
* `-ffile-prefix-map`: `__FILE__` (in assert messages) and debug info
  name the sources `/usr/src/...` and `/usr/obj/...`, as a native build
  does, not the build host's checkout.
* `-Wl,--undefined-version`: lld, unlike GNU ld, rejects version scripts
  that name symbols a configuration does not build (hesiod in libc).
* Old-C diagnostics that recent clang makes errors stay warnings, as in
  the tree's gcc 12: incompatible (function) pointer types, int
  conversions, implicit int and implicit function declarations.

`xc++` is `xcc --driver-mode=g++`; clang's DragonFly driver finds the gcc 8
C++ headers that `libstdc++` installs in `/usr/include/c++/8.0`.

`hostcc` and `hostc++` build the helpers that run during the world build
(ncurses' `make_keys`, gcc's generators, ...). `share/mk` calls them as
`${NXENV} ${CC}`; `NXENV` is `nxenv`, an `env(1)` that turns `xcc` into
`hostcc` and `xc++` into `hostc++`. Generators therefore always run as
Linux programs and are never installed.

### The compiler runtime

The startup files and `libgcc` replacement come from LLVM's compiler-rt,
imported in `contrib/compiler-rt` (tag and commit in
`README.DRAGONFLY`, license in `LICENSE.TXT`) and built by
`lib/libcompiler_rt` with `xcc` before libc. It installs, in
`/usr/lib/gcc80` where clang's DragonFly driver looks for them:

* `libgcc.a` and `libgcc_pic.a`: the x86_64 builtins (128-bit integer
  division and conversions, `long double` and `__float128` helpers,
  `_Float16` and `__bf16` conversions, overflow checks, CPU model), with
  the source list of compiler-rt's `CMakeLists.txt` for x86_64. Built PIC,
  with hidden symbols and `-fno-stack-protector` (as gcc builds libgcc:
  the runtime is also linked into code without libc).
* `crtbegin.o` and `crtend.o` (also installed as `crtbeginS.o`,
  `crtbeginT.o` and `crtendS.o`): `__dso_handle`, the `.init_array` and
  `.fini_array` entries that run `__cxa_finalize` for shared objects,
  and the `__register_frame_info` calls (weak) for the exception frames.

The builtins are not all of gcc's runtime. Two parts come from the tree's
gcc 8 runtime instead, built with clang: the exception unwinder
(`gnu/lib/gcc80/libgcc_eh`, also added to `libgcc_pic.a` with exported
symbols, as `gnu/lib/gcc80/libgcc_pic` does) and `libstdc++`. The
unwinder includes a few gcc target headers: `tm.h` and `options.h` come
from `gnu/usr.bin/cc80/cc_prep`, and `insn-constants.h` gets the one value
it needs (`FIRST_PSEUDO_REG`, read from `i386.md`). The `xcc` wrapper
defines the `__LIBGCC_*` macros that gcc predefines for
`-fbuilding-libgcc`. Until `base` runs, `libgcc_eh.a` is an empty archive,
which is enough for C. `crt1.o`, `crti.o` and `crtn.o` are the tree's
(`lib/csu`) and carry the DragonFly ABI note.

`gnu/lib/gcc120` (gcc 12's own runtime) and `gnu/lib/gcc80/{csu,libgcc}`
are not built: they need gcc's internals (machine modes, generated
headers) and do not compile with clang. `lib/libcompiler_rt` is not in
`lib/Makefile`'s `SUBDIR`, so a native build is unchanged.

Tests (see below) check the builtins in static and dynamic programs, C++
constructors and destructors in a program and a shared library, an
exception thrown across the library boundary, `atexit` order and
`dlopen(3)` with a module's constructor and destructor.

## Host and target isolation

The rules the build follows, and what checks them:

1. Target code is compiled only by `xcc`/`xc++` (userland) or `cc`/`kcc`
   with `-nostdinc` (kernel). No target object is compiled by `hostcc`.
2. Target code sees only DragonFly headers: the sysroot's, the tree's
   `sys/`, and the compiler's resource headers. The kernel module
   makefile's `${DESTDIR}/usr/include` fallback points at the sysroot
   (`build.sh` passes `DESTDIR=$OBJDIR/sysroot` to the kernel builds),
   never at Linux's `/usr/include`.
3. Target programs link only against the sysroot: `crt1.o`/`crti.o`
   from `lib/csu`, `crtbegin.o`/`libgcc.a` from `lib/libcompiler_rt`, and
   the tree's libraries. Nothing is copied from the host's compiler or C
   library.
4. Programs that run during the build (generators) are built by
   `hostcc`/`hostc++` through `NXENV`, run on Linux and are not
   installed.
5. Everything installed into the sysroot and the root image passes the
   ELF audit (below). GNU code that the DragonFly tree itself carries
   (gcc 8's libstdc++ and unwinder, binutils, grep, ...) is target code
   like any other, built from the tree.

## ELF audit

`tools/linux/elf-audit.sh [-o REPORT] DIR...` checks every ELF file and
static archive under the given trees. Errors, which fail CI, are
confirmed host contamination:

* not ELF64 little-endian x86-64;
* a program interpreter other than `/libexec/ld-elf.so.2` (for example
  `/lib64/ld-linux-x86-64.so.2`);
* a `NEEDED` library with a glibc or Linux soname (`libc.so.6`,
  `libgcc_s.so.1`, `libbsd.so.0`, ...);
* versioned references to `GLIBC_*` or `GCC_*` symbols;
* the Linux ABI note (`NT_GNU_ABI_TAG` with OS Linux) that glibc's
  `crt1.o` carries, in a file or an archive member;
* `RPATH`/`RUNPATH` pointing into the build host.

Warnings are reported but do not fail: a `NEEDED` library that is not in
the tree, a dynamically linked program without a DragonFly/FoxynBSD ABI
note, build-host paths in a file's loaded data, and `EI_OSABI` GNU.
`EI_OSABI` alone proves nothing. clang and lld write 0 (System V) for
DragonFly, and LLVM sets GNU when an object uses GNU ELF extensions:
clang emits `SHF_GNU_RETAIN` sections for a few of gcc 8's `libstdc++`
objects, and every program that links them inherits the mark. The kernel
accepts these programs by their ABI note. `.comment` is not used either.

CI runs the audit on `rootfs` and the sysroot in the userland jobs and on
the whole world's sysroot in the world job. The report is uploaded with
the logs.

## Kernel configurations

All four configurations in `sys/config` build: `X86_64_GENERIC`, `MINI64`,
`LINT64` and `VKERNEL64`. `build.sh kernel` runs `make depend` for the
kernel and, when the configuration has `INET`, for the modules too:
once the kernel's object directory has the generated `*_if.c`,
`kmod.mk` no longer makes them for the modules. `MINI64` has no
`INET` and builds no modules. `LINT64`'s built-in keymaps
(`ATKBD_DFLT_KEYMAP`, `UKBD_DFLT_KEYMAP`) are made by the tree's
`kbdcontrol -L`, built for the host as `KBDCONTROL` (the kernel makefiles
default to `/usr/sbin/kbdcontrol`). A virtual kernel is a DragonFly
program, so `VKERNEL64` links with `xcc` against the sysroot's libc and
libpthread; `build.sh kernel VKERNEL64` builds those first if they are
missing.

## The userland (world)

`build.sh sysroot` does what buildworld's `includes` stage does. It copies
the kernel headers, creates the directory tree from
`etc/mtree/BSD.include.dist`, and runs `buildincludes` and
`installincludes` under `include/` and `lib/`. It also creates the
`BSD.root.dist`, `BSD.usr.dist` and `BSD.var.dist` directory trees.

`build.sh libc` builds the compiler runtime (`lib/libcompiler_rt`),
`lib/csu` and `lib/libc` with `xcc` and installs them into the sysroot,
the way buildworld's library stage does, so that later links find them.
The world is built with `CCVER=clang` on the make command line, so
`share/mk` adds neither gcc-only flags nor `-Werror`; clang warnings are
reported but do not fail the build.

More on how the userland stays DragonFly's:

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
build (ncurses' `make_keys`) use the host compiler through `NXENV`, and
`_SHLIBDIRPREFIX` points at the sysroot so private headers such as
`usr/include/priv/ncurses` are found.

`build.sh base` builds the runtime linker (`libexec/rtld-elf`, on top of
`lib/libc_rtld`), libutil, libcrypt, the private ncurses, libedit, libm and
libkvm, libpam and its modules, the C++ runtime, then `init`, `sh`,
`getty`, `login` and the utilities that `rc.subr` and the `rc.d` scripts
call (`rcorder`, `awk`, `sed`, `grep`, `mount`, `fsck`, `ifconfig`,
`sysctl`, `periodic`, ...).

## The root image

`build.sh rootfs` copies the programs of `base` and every shared library
they load (following `NEEDED` through the standard directories and each
file's `RUNPATH`, e.g. `/usr/lib/gcc80` for `libstdc++`) into
`$OBJDIR/rootfs`. It compiles a few console terminal types (`xterm`,
`vt100`, `vt220`, `cons25`, ...) from the tree's `terminfo.src` with the
host's `tic`, copies `etc/login.conf` (read as text; no `cap_mkdb`
needed), `etc/group` and `etc/master.passwd`, and installs the tree's
`/etc/rc`, `rc.subr`, `rc.shutdown` and `rc.d` scripts. Its `fstab` and
`rc.conf` follow the live CD's (`nrelease/root/etc`): the root stays
read-only (`root_rw_mount="NO"`), and `rc.d/mountcritlocal` mounts tmpfs
with `-C` (copy the CD's files in) over `/var`, `/tmp` and `/root`.

`syslogd`, `newsyslog`, `devd` and `cron` run, with the tree's
`syslog.conf`, `devd.conf`, `devd/*.conf`, `crontab` (minus the `atrun`
job, whose program is not in the image yet) and the empty `/var/log`
files that `etc/Makefile` installs. The daily, weekly and monthly
`periodic` jobs write their reports to `/var/log/daily.log`,
`weekly.log` and `monthly.log`, since there is no mail program; the
image's `/etc/periodic.conf` turns off the checks for what it lacks
(sendmail, HAMMER, accounting, ipfw, pf, `locate`, `whatis`). The other
services whose programs the image lacks are off in `rc.conf`.

One image-only script, `/etc/rc.local.d/imagedb`, runs first: it mounts
the `/etc` tmpfs and builds the password database with `pwd_mkdb`, before
the devfs rules look up `root`. `/etc/rc.local` prints `uname -a` and runs
the boot tests below. When `/etc/rc` exits, init starts `getty` on the
console from a small `/etc/ttys` (serial `ttyd0`, or `ttyv0` with
`--gui`), and `login` checks passwords through PAM (`/etc/pam.d`,
`pam_unix` and friends). Root has no password and logs in to `/bin/sh`,
since `csh` needs libcrypto, which the image does not have yet.

`build.sh rootfs` finally packs the tree as a Rock Ridge ISO with xorriso,
with every file owned by root:wheel (the build runs unprivileged, so the
`install` shim drops `-o`/`-g`; modes, including setuid bits, are kept).
`qemu.sh --root` attaches it as a second virtio disk and sets
`vfs.root.mountfrom="cd9660:vbd1"`, so no step needs root privileges.
(Not as a CD: QEMU's AHCI ATAPI emulation times out with the `ahci`
driver.)

## QEMU

OVMF runs `EFI/BOOT/BOOTX64.EFI` (our `loader.efi`). The loader reads
`boot/dloader.rc`, `boot/loader.conf` (serial console) and
`boot/kernel/kernel` from the ESP, which QEMU serves as a read-only
virtual FAT disk (`-drive file=fat:<dir>`). With no root filesystem
attached, a kernel-only boot ends at the `mountroot>` prompt. With
`--root`, the kernel mounts `root.iso` and init runs its `/etc/rc`.
`ROOTDISK=<img>` attaches an extra virtio disk.

The firmware is found the way QEMU and libvirt find it: from the JSON
firmware descriptors that the edk2/OVMF packages install in
`/usr/share/qemu/firmware` (or `/etc/qemu/firmware`), taking the first
x86_64 UEFI image for q35 in raw format without Secure Boot or SMM. Without
descriptors, the usual Arch, Debian/Ubuntu and Fedora paths are tried.
`OVMF_CODE` and `OVMF_VARS` override both; `qemu.sh --firmware` prints
the choice. QEMU uses KVM when `/dev/kvm` is writable, and TCG otherwise
(several times slower: set `BOOT_TIMEOUT` higher for `boot-test.sh`).

## Tests

`boot-test.sh --root` boots the image headless, waits for `login:`, logs
in as root over the serial line, lists the running programs and runs
`periodic daily`. `check-boot-log.sh` then checks the serial log, one
check per CI step (`all` runs them all):

| Check | What it verifies |
|-------|------------------|
| `rtld` | dynamically linked programs ran (ld-elf.so.2, libc, libutil, ncurses) |
| `rcd` | lists commands the rc.d scripts did not find (not fatal) |
| `identity` | `uname -a` reports FoxynBSD |
| `basics` | terminfo, a writable tmpfs `/tmp`, login classes, devfs rules after the password database |
| `syslogd` | a `logger(1)` message reached `/var/log/messages` |
| `daemons` | `syslogd`, `cron` and `devd` still run after login |
| `periodic` | `periodic daily` finished and found every command |
| `cxx` | a static C++ program throws through two frames and catches |
| `runtime` | compiler-rt builtins in a static and a dynamic program; C++ constructors, destructors and an exception across a shared library; `atexit` order; `dlopen(3)` (sources in `tools/linux/tests`) |
| `fs` | `/tmp` and `/var/tmp` sticky and writable; `/etc`, `/var/run`, `/var/log`, `/var/db`, `/root` writable; `/` read-only; `master.passwd` and `spwd.db` mode 600 |
| `abi` | programs with either ELF ABI note (FoxynBSD, DragonFly) run |
| `kld` | the kernel modules in the image (`udf`, `ext2fs`, when built) load and unload |

A failing boot leaves the serial log in `$OBJDIR/qemu/`. On a kernel
trap, `boot-test.sh` resolves the faulting instruction to a source line
(`<log>.fault`); with `machdep.print_user_faults`, it does the same for
faults in `ld-elf.so.2`.

## The whole world

`build.sh world` builds everything buildworld builds into the sysroot, in
the order of `Makefile.inc1`: the startup libraries, the compiler's
unwinder and the `_prebuild_libs`, then every directory under `gnu/lib`,
`lib`, `libexec`, `bin`, `sbin`, `usr.bin`, `usr.sbin`, `gnu/usr.bin`
(binutils 2.27 and 2.34, gcc 8 and gcc 12), `games` and `share`. Each
top-level directory is walked one `SUBDIR` level deep. The first failing
directory stops the build; with `KEEP_GOING=1` the rest still builds and
the failed directories are listed at the end.

A directory that builds is not the same as a complete installation: the
world goes into the sysroot only, and the root image takes just the
`base` programs from it. There is no `installworld` or `distribution`
(`etc/Makefile`) step yet.

What differs from buildworld:

* The compiler runtime comes from `lib/libcompiler_rt` (see above), so
  `gnu/lib/gcc*/csu` and `libgcc` are not built, nor is `gnu/lib/gcc120`.
  The C++ runtime is gcc 8's, as in `base`.
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

## CI

| Workflow | When | Jobs |
|----------|------|------|
| `linux-build.yml` | every push and PR to `dev` | Ubuntu 24.04: *Kernel, loader and boot tree* (kernel-only boot to `mountroot>`), *Kernel modules* (all 682), *Userland and boot to a shell* (base, ELF audit, test modules, boot to a root login, every boot-log check), *Whole world* (`KEEP_GOING=1`, ELF audit of the sysroot) |
| `linux-hosts.yml` | changes to `tools/linux`, the compiler runtime or the workflow; weekly; by hand | Arch Linux container (clang kernel and modules) and Debian stable container (gcc): tools, kernel, all modules, loader, base, root image, ELF audit, boot, `check-boot-log.sh all` |
| `linux-lint.yml` | changes to `tools/linux` or workflows | the scripts parse under dash and bash, `shellcheck -S error`, the ELF audit rejects a glibc program |

All jobs are blocking. The names of the `linux-build.yml` jobs are the
required check names: do not rename them. The containers get `/dev/kvm`
from the runner; without it QEMU falls back to TCG within the 900 s boot
timeout. Failed builds and boots put the end of the log and the serial
console into a job annotation, and the logs, serial output and audit
report are uploaded as artifacts.

## Known limitations

* The root image is a read-only cd9660 with tmpfs over `/etc`, `/var`,
  `/tmp` and `/root`: there is no writable root filesystem or installer
  yet (issue #9).
* Not in the image: libcrypto (so `csh` and `mtree`), `sendmail`/`dma`,
  `atrun`, `locate`, and the rest of the world beyond `base`.
* gcc 12's runtime (`gnu/lib/gcc120`) and the gcc 12 compiler as a
  cross compiler for the host are not built (see above).
* The clang kernel is opt-in (`KERNCC=clang`); lld does not link the
  kernel.
* File ownership in the sysroot is the building user's; the ISO records
  root:wheel for everything.
* Omarchy is not tested in CI as such; the Arch container is.

## Troubleshooting

* Run `tools/linux/build.sh doctor` first: it names missing packages for
  pacman and apt.
* `build.sh: <cmd> failed (exit N)`: the last `>>>` line before it names
  the step; the compiler error is above it. In CI it is in the job's
  annotation.
* After updating the tree, a build that fails in the host tools or with
  odd shim behavior: `build.sh` rebuilds its host tools when their
  version (`TOOLS_STAMP`) changes; to force it, remove
  `$OBJDIR/host/bin/.done`. Staged headers have their own stamp
  (`$OBJDIR/sysroot/.headers_done`).
* A newer host gcc fails the kernel with `-Werror` on a new warning:
  add it to the probed `-Wno-error=` list in `write_cc_wrapper`, or try
  `KERNCC=clang`.
* `OVMF firmware not found`: install `edk2-ovmf` (Arch) or `ovmf`
  (Debian/Ubuntu), or set `OVMF_CODE` and `OVMF_VARS`.
* The boot test times out without KVM: `BOOT_TIMEOUT=1500
  tools/linux/boot-test.sh --root`. Inside a container, pass
  `--device /dev/kvm`.
* A program fails to start in the image: `LD_DEBUG=1` works (rtld is
  built with debugging), and `qemu.sh --root` turns on
  `machdep.print_user_faults`, which logs where user programs fault.
* `elf-audit.sh` reports an error: the report names the file and what
  ties it to the host (interpreter, soname, symbol version, ABI note).
  Rebuild that directory with `build.sh subdir <dir>` and look at how it
  was compiled and linked; it was most likely built by `hostcc` or linked
  outside the sysroot.
* `$HOME` on tmpfs runs out of space: set `OBJDIR` to a directory on
  disk.

## Status

| Piece | Linux host |
|-------|------------|
| host tools (bmake, config, zic, ...) | build on Omarchy and Ubuntu; Arch and Debian through `linux-hosts.yml` |
| kernels `X86_64_GENERIC`, `MINI64`, `LINT64`, `VKERNEL64` | build (gcc); `X86_64_GENERIC` also with clang |
| kernel modules (682 `.ko`) | build with gcc and with clang; load and unload in the image |
| `loader.efi`, ESP tree | boots under QEMU + OVMF |
| compiler runtime | built from `contrib/compiler-rt`; tested in the image |
| libc, rtld, base userland, C++ runtime | build with clang; run in the image |
| root image | boots through `/etc/rc` and `rc.d` to a root login; syslogd, newsyslog, cron, devd, periodic |
| whole world (`build.sh world`) | builds into the sysroot (CI job *Whole world*) |
| ELF audit | no host contamination in the sysroot and the image |
| writable root, installer, rest of the world in the image | TODO (issue #9) |
