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
                                                                    # (disk image: sfdisk, in util-linux)
    sudo pacman -S --needed qemu-desktop edk2-ovmf                  # boot under QEMU (qemu-base: no window)

Debian and Ubuntu:

    sudo apt install build-essential flex bison libfl-dev libbsd-dev libtirpc-dev pkg-config
    sudo apt install clang lld xorriso ncurses-bin fdisk     # fdisk: sfdisk, for the disk image
    sudo apt install qemu-system-x86 qemu-system-gui ovmf     # qemu-system-gui: the window

LLVM's `compiler-rt` package is not needed: the compiler runtime is built
from `contrib/compiler-rt`. Check a host with:

    tools/linux/build.sh doctor

It reports the distribution, `/bin/sh` and `awk`, the host gcc's default
PIE and stack protector settings, the clang version, the OVMF firmware
QEMU would use, whether KVM is usable, and the packages to install for
anything missing. It exits with status 1 if something is missing.

## Quick start

    tools/linux/build.sh doctor     # check the host, list missing packages
    tools/linux/build.sh            # the whole system: kernel, loader, world, root image
    tools/linux/qemu.sh             # boot it in a QEMU window; log in as root (no password)

`build.sh` with no arguments (`build.sh all`) builds the host tools,
`X86_64_GENERIC`, the EFI loader and boot tree, the whole world and a
root image with all of it. Run it again after changing the tree: it is
incremental (see [Incremental builds](#incremental-builds)). `qemu.sh`
with no options boots that image in a window to a `login:` prompt.
Root's shell is `csh` with DragonFly's dot files (`root@foxynbsd:~ #`).
`qemu.sh --serial` uses the terminal instead (Ctrl-A X quits), and
`qemu.sh --kernel-only` boots the kernel alone, to `mountroot>`.

The image is a read-only live system: what you change is gone at the
next boot. For a system that keeps its changes, put the same tree on a
writable disk:

    tools/linux/build.sh disk       # $OBJDIR/disk.img: UFS root on a GPT disk
    tools/linux/qemu.sh --disk      # boot it; changes stay for the next boot

To package a separately prepared root tree without replacing the default
`$OBJDIR/rootfs`, set `DISK_ROOTFS` to that tree. It must already contain
`etc/rc.conf`; a missing tree fails instead of building the default root.
Use a separate `OBJDIR` or `DISK` when the resulting disk must not replace
an existing image. This selects the tree to package; it does not build or
install a desktop into it.

The network comes up at boot either way (`dhcpcd` on QEMU's user-mode
network), and `fetch` reaches HTTP and HTTPS servers.

To install FoxynBSD on a disk that then boots on its own, run the
installer from the live image (see [The installers](#the-installers)):

    tools/linux/boot-test.sh --install     # root.iso runs foxyn-install on $OBJDIR/installed.img
    tools/linux/qemu.sh --installed        # boot that disk alone (its own ESP, HAMMER2 root)

or by hand: `ROOTDISK=<empty image> tools/linux/qemu.sh`, log in, and
`foxyn-install vbd2`.

## Usage

    tools/linux/build.sh [all]              # everything below, ready for qemu.sh
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
    tools/linux/build.sh rootfs             # root tree + root.iso (cd9660) with the whole world
    ROOTFS=base tools/linux/build.sh rootfs # minimal image: only the base programs
    tools/linux/build.sh disk               # disk.img: the root tree on a writable UFS disk
    DISK_SIZE=8G tools/linux/build.sh disk  # a bigger one (sparse; default 4G)
    tools/linux/build.sh world              # the whole userland, buildworld's order
    KEEP_GOING=1 tools/linux/build.sh world # same, listing every failed directory
    tools/linux/build.sh subdir bin/date    # build and install any world directory
    tools/linux/build.sh loader             # stand/ -> loader.efi
    WITH_MODULES=1 tools/linux/build.sh esp # EFI boot tree: loader + kernel (+ stripped .ko)
    tools/linux/qemu.sh                     # boot kernel + root.iso in a QEMU window: login:
    tools/linux/qemu.sh --serial            # same, on the serial console in this terminal
    tools/linux/qemu.sh --kernel-only       # the kernel alone: ends at mountroot>
    tools/linux/qemu.sh --disk              # boot disk.img instead of root.iso (read-write)
    tools/linux/qemu.sh --installed         # boot installed.img alone (from its own ESP)
    NETDEV_OPTS=,hostfwd=tcp::2222-:22 tools/linux/qemu.sh   # more -netdev user options
    tools/linux/qemu.sh --firmware          # print the OVMF images qemu.sh would use
    tools/linux/boot-test.sh                # headless boot, passes at the mountroot> prompt
    tools/linux/boot-test.sh --root         # headless boot to the userland, logs in as root
    tools/linux/boot-test.sh --disk         # same with disk.img, then halt -p
    tools/linux/boot-test.sh --install      # root.iso installs itself on installed.img
    tools/linux/boot-test.sh --installed    # boot installed.img alone, run the tests
    tools/linux/boot-test.sh --bsdinstaller # log in as installer: the BSD Installer starts
    tools/linux/check-boot-log.sh all       # check what the --root boot did (see Tests)
    tools/linux/elf-audit.sh "$OBJDIR/rootfs" "$OBJDIR/sysroot"   # host contamination audit
    tools/linux/check-logos.sh -p           # the boot menu logos: sizes, variants agree
    tools/linux/check-submodules.sh -r      # contrib/ submodules checked out, at the recorded commits
    eval "$(tools/linux/build.sh env)"      # shell env for running make by hand

A quicker first boot, with the minimal image instead of the world:

    tools/linux/build.sh kernel && tools/linux/build.sh loader &&
      tools/linux/build.sh esp && ROOTFS=base tools/linux/build.sh rootfs
    tools/linux/qemu.sh

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
    $OBJDIR/disk.img               the root tree on a writable UFS disk (build.sh disk)
    $OBJDIR/disk.mtree, disk-etc/  its makefs manifest and the /etc files it replaces
    $OBJDIR/installed.img          the disk boot-test.sh --install installs on
    $OBJDIR/qemu/                  serial logs, UEFI variable store

The build needs no root privileges. It takes a few GB for the kernel,
modules and base image and much more for the whole world; with `$HOME`
on a tmpfs, point `OBJDIR` at a disk.

Environment: `OBJDIR`, `JOBS` (default: `nproc`), `HOST_CC`/`HOST_CFLAGS`
(host tools, default `gcc`/`-O2`), `HOST_GCC` (kernel gcc), `HOST_CLANG`
(userland and `KERNCC=clang` compiler), `KERNCC` (`gcc` or `clang`),
`MODULES_OVERRIDE`, `KEEP_GOING`, `WITH_MODULES`, `ROOTFS` (`world` or
`base`), `DISK` and `DISK_SIZE`; for QEMU `GUI`, `ROOT`, `DISPLAY_BACKEND`,
`OVMF_CODE`, `OVMF_VARS`, `MEM`, `SMP`, `ROOTISO`, `DISK`, `ROOTDISK`,
`NETDEV_OPTS`, `BOOT_TIMEOUT`.

## Incremental builds

Build commands keep their outputs and, when rerun, rebuild what their
dependencies identify as changed. Image commands assemble the staged
outputs; they do not necessarily rebuild them. The edit-and-boot loop is:

    $EDITOR sys/dev/misc/syscons/scterm-xterm.c bin/ls/ls.c
    tools/linux/build.sh            # compiles those two files, relinks, packs the images
    tools/linux/qemu.sh

or, for one piece, `build.sh kernel` or `build.sh subdir bin/ls`
followed by `build.sh rootfs`.

* The kernel's object directory is kept. `config(8)` runs every time
  but rewrites only the files whose contents change, and the objects
  are compiled with `-MD` (`FASTER_DEPEND`): the compiler's `.d` files
  become the `.depend`, so a changed header recompiles exactly the files
  that include it. The full `make depend` (which also covers the
  modules) runs only for a new object directory and when `config`
  writes a new `Makefile` (a file or an option came or went).
* The world's directories are rebuilt by their makefiles, which compile
  only what is out of date. The `install` shim leaves a file whose
  contents did not change alone, mtime included (BSD `install -C`), so
  installing libc again does not relink every program. A `.depend`
  that names a file which is gone (a header a contrib update removed)
  is made again, instead of rebuilding that directory on every run.
  `base` and `world` go through `lib/csu` and `lib/libc` first every
  time, so a new system call or `Symbol.map` entry reaches the image.
* The headers in the sysroot are synchronized with the tree before
  every world command (`libc`, `base`, `world`, `subdir`): a header
  whose contents changed is copied again, the others keep their mtimes.
* The root image (`rootfs`), the disk image and the ESP are assembled
  from scratch each time; that takes copies, not compiles. In particular,
  `rootfs` reuses a completed world in the sysroot. After changing a world
  component, run `build.sh world` or the relevant `build.sh subdir` before
  `rootfs`; rebuilding only the image can otherwise package older files.

To start a piece from scratch, remove its output: `$OBJDIR/sys/<KERNCONF>`
(the kernel), `$OBJDIR/world` (the world's objects), `$OBJDIR/sysroot`
(everything installed). The kernel is also rebuilt from scratch when
`KERNCC` changes.

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
* `makefs` from `usr.sbin/makefs`, with only its ffs back end, for
  `build.sh disk` (`tools/linux/makefs` has the few headers and
  definitions glibc lacks; the UFS headers are copied from `sys/vfs/ufs`
  into a directory of their own);
* `btxld` and BSD `dd`/`stat` shims for the BIOS boot blocks (see
  [The BSD Installer](#the-bsd-installer));
* the compiler wrappers `cc`, `kcc`, `xcc`, `xc++`, `xgcc`, `hostcc`,
  `hostc++` and `nxenv`.

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

`gnu/lib/gcc80/{csu,libgcc}` are not built: they need gcc's internals
(machine modes, generated headers) and do not compile with clang.
`lib/libcompiler_rt` is not in `lib/Makefile`'s `SUBDIR`, so a native
build is unchanged.

### gcc 12's runtime (`xgcc`)

gcc 12 is DragonFly's default compiler: the image's `cc`, `c++` and `gcc`
are gcc 12 (`gnu/usr.bin/cc120`, built by the world), and they link with
gcc 12's own runtime in `/usr/lib/gcc120` (`crtbegin.o`/`crtend.o`,
`libgcc`, `libgcc_eh`, `libgcc_pic`, `libssp`, `libssp_nonshared`,
`libatomic`, `libgcov`, `libgomp`, `libstdc++`, `libstdc++fs`), with its
headers in `/usr/libdata/gcc120` and `/usr/include/c++/12.0`.
`build.sh world` builds `gnu/lib/gcc120` last, after `gnu/usr.bin/cc120`,
whose generated headers (`cc_prep`, `cc_tools`) it includes, as
buildworld's `_compiler_libs_gcc120` stage does.

The C parts need gcc itself: what it predefines for `-fbuilding-libgcc`,
mode attributes and builtins clang lacks. They are built with `xgcc`, the
host gcc used as a compiler for the DragonFly target, and with the
makefiles' gcc settings (`CCVER=gcc120`). A gcc for x86_64 Linux and gcc 12
for x86_64 DragonFly generate the same code for this runtime (ELF, the
SysV ABI); what differs is what `xgcc` replaces:

* the predefined system macros (`-U__linux__ ... -D__DragonFly__`) and the
  headers (`-nostdinc`: the sysroot's `/usr/include`, then the host
  gcc's own intrinsics, then gcc 12's in `/usr/libdata/gcc120`);
* the hardening defaults of Linux distributions (PIE, CET, stack clash
  protection, `_FORTIFY_SOURCE`, the stack protector), off as in
  DragonFly's gcc;
* `-Werror` stays a warning: the host gcc is newer than gcc 12.

Only compiling goes to gcc; links (`libatomic`, `libgomp` and `libssp`
are also shared libraries) go to `xcc`. `libstdc++` is built with `xc++`
(clang), like gcc 8's: host g++ releases newer than gcc 12 do not all
compile its exception support (gcc 16 has an internal compiler error on
`libsupc++/eh_call.cc`). For it, `xcc` drops `-gno-as-loc-support` and
`xc++` maps gcc's `__builtin_ia32_rdseed_si_step` to clang's name.

The `cc` test (see below) compiles, links and runs C (dynamic and static,
with a 128-bit division from `libgcc`) and C++ (an exception through a
destructor) in the image, with gcc 12 and with gcc 8 (`CCVER=gcc80`).

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
`LINT64` and `VKERNEL64`. `build.sh kernel` runs `make depend` (on a new
object directory, see [Incremental builds](#incremental-builds)) for the
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

By default (`ROOTFS=world`), `build.sh rootfs` puts the whole world into
`$OBJDIR/rootfs`: everything `build.sh world` installed in the sysroot,
building the world first if it has not completed (`build.sh world` marks
it done in the sysroot). The image is about 450 MB. With `ROOTFS=base`
it copies only the programs of `base` and every shared library they load
(following `NEEDED` through the standard directories and each file's
`RUNPATH`, e.g. `/usr/lib/gcc80` for `libstdc++`), a small image that is
quick to build; CI's userland jobs use it. Either way the image gets the
`/etc` files of `etc/Makefile`'s `distribution` target that a session
reads (`profile`, `shells`, `csh.*`, `hosts`, `services`, all of
`pam.d`, ...) and root's dot files from `share/skel`, with a `.shrc`
prompt that shows `user@host:directory`. Root's shell is `csh`, as on
DragonFly. The base programs include LibreSSL 4.3 (`libcrypto`, `libssl`),
`libfetch` and what uses them: `csh`, `mtree`, `dhcpcd`, `fetch` and
`openssl`, with `/etc/ssl/openssl.cnf` and LibreSSL's CA certificates in
`/etc/ssl/cert.pem`. It compiles a few console terminal types (`xterm`,
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

The network: `rc.conf` has `ifconfig_vtnet0="DHCP"` with
`dhcp_client="dhcpcd"`, so `rc.d/netif` starts `dhcpcd -b` on QEMU's
virtio-net card. QEMU's user-mode network leases it 10.0.2.15 with the
gateway 10.0.2.2 and the name server 10.0.2.3, and dhcpcd's hooks write
`/etc/resolv.conf` and the host name. dhcpcd runs privilege-separated as
`_dhcp`, with the tree's `/etc/dhcpcd.conf`.

One image-only script, `/etc/rc.local.d/imagedb`, runs first: it mounts
the `/etc` tmpfs and builds the password database with `pwd_mkdb`, before
the devfs rules look up `root`. (On the disk image it builds the database
only on the first boot; see below.) `/etc/rc.local` prints `uname -a` and runs
the boot tests below. When `/etc/rc` exits, init starts `getty` on the
console from a small `/etc/ttys` (`ttyv0` in the QEMU window, the serial
`ttyd0` with `--serial`), and `login` checks passwords through PAM
(`/etc/pam.d`, `pam_unix` and friends). Root has no password. `ttyv0` has
the type `xterm`, and the image's `rc.conf` sets `allscreens_flags="-T
xterm"`, so `/etc/rc.d/syscons` gives every virtual console syscons'
xterm emulator (`sys/dev/misc/syscons/scterm-xterm.c`, `vidcontrol -T`)
instead of the cons25 one, which shows the `ESC [ ?` sequences of line
editors such as Ruby's `irb` (Reline) as text.

`build.sh rootfs` finally packs the tree as a Rock Ridge ISO with xorriso,
with every file owned by root:wheel (the build runs unprivileged, so the
`install` shim drops `-o`/`-g`; modes, including setuid bits, are kept).
`qemu.sh` attaches it as a second virtio disk and sets
`vfs.root.mountfrom="cd9660:vbd1"`, so no step needs root privileges.
(Not as a CD: QEMU's AHCI ATAPI emulation times out with the `ahci`
driver.)

## The disk image

`build.sh disk` puts the tree of `build.sh rootfs` (built first if there
is none; `ROOTFS` picks the world or the base programs) on a writable
disk, `$OBJDIR/disk.img`, without root privileges:

* `makefs -t ffs` (built from the tree by `build.sh tools`) writes a
  UFS1 file system from an mtree manifest of the tree, `disk.mtree`, in
  which every file is root:wheel with the mode it has in the tree
  (setuid bits included); hard and symbolic links are kept;
* `sfdisk` puts a GPT around it: partition 1, at 1 MiB, of DragonFly's
  UFS1 type and named `foxynroot`, which the kernel sees as `vbd1s0`
  (the ESP is `vbd0`);
* the image is sparse: `DISK_SIZE` (default `4G`) is its size, not what
  it takes on the host.

Two files differ from the live image (they come from `disk-etc/`, which
the manifest takes instead of the tree's): `/etc/fstab` mounts `/dev/vbd1s0`
read-write on `/` with `fsck` pass 1, and `/etc/rc.conf` lacks
`root_rw_mount="NO"`. So `/var`, `/tmp` and `/root` live on the disk, and
`rc.d/fsck` checks it at boot. The password database cannot be made on
the host: on the first boot, `imagedb` mounts the root read-write, runs
`pwd_mkdb` and mounts it read-only again, before `fsck` and the devfs
rules. Later boots keep the database.

`qemu.sh --disk` boots it (the kernel is still the ESP's) with
`vfs.root.mountfrom="ufs:vbd1s0"`. Shut it down with `halt -p` (or
`shutdown -p now`), so the next boot finds a clean file system; after a
hard stop, `fsck -p` repairs it at boot. `build.sh disk` makes a new image
each time: what was written into the old one is lost.

## The installers

The image with the whole world has two installers. The BSD Installer
(`usr.sbin/installer`) is DragonFly's, the one to install with by hand.
`foxyn-install` is a short script that does a fixed install with no
questions, for CI and scripts.

### The BSD Installer

Log in as `installer` on the live image (no password; `/etc/issue` says
so) and the BSD Installer starts: on a serial console it asks for the
terminal type first (`vt100`, `xterm`), then its curses front end
(`dfuife_curses`) and back end (`dfuibe_installer`) walk through the
install. With the defaults (UEFI, one disk, HAMMER2) it makes a GPT with
an EFI system partition holding `boot1.efi`, a disklabel64 slice with
`/boot` (UFS, 1 GB), swap and the HAMMER2 root with its `/build` PFS, and
copies the live system (`share/installer/sources.conf`) with `cpdup`.
`boot1.efi` starts `/loader.efi` from the `/boot` partition, which loads
the kernel there. It also configures the installed system (root
password, users, time zone, network) and can set up a NetBoot server.

As `nrelease` builds the release CD, `build.sh`:

* builds it: `WANT_INSTALLER` is set for the world, so `usr.sbin/installer`
  and `share/installer` are built (they are only built for release media);
* builds `boot1.efi` with the EFI loader, and the BIOS boot blocks
  (`boot1_64`, `boot2_64` and their 32-bit versions from
  `stand/boot/pc32/boot2`), which `disklabel64 -B` writes into the slice
  (the installer always runs it). They are 32-bit code; `btxld` is built
  for the host with the tree's a.out and ELF32 definitions, and the boot2
  makefile gets BSD `dd conv=osync` and `stat` shims. Arch's assembler adds
  an x86 ISA note by default, which would make `boot1` longer than its
  512-byte sector: it is turned off (`-mx86-used-note=no`);
* gives the image what the installer copies: `/boot` with `boot1.efi`,
  `loader.efi`, the boot blocks and the kernel, and `/etc/mtree`;
* makes `/etc.hdd`, the `/etc` the installer puts on the disk instead of
  the live one (no tmpfs mounts, a read-write root, no boot tests), and
  the `installer` user (uid 0, shell `/usr/sbin/installer`).

Its texts name FoxynBSD (`libdfui/system.h`).

The installer names the disks in `fstab` and `loader.conf` by serial
number when there is one (`/dev/serno/<serial>.s1d`), so the installed
system finds them in any order. The virtio disk driver reads the serial
number from the device (`VIRTIO_BLK_T_GET_ID`, in `virtio_blk.c`), and
`qemu.sh` gives each disk one, from its file name (`installed.img`:
`installed`).

`boot-test.sh --bsdinstaller` (CI's *Whole world* job) logs in as
`installer` and passes on the welcome screen. To install with it by hand
under QEMU:

    truncate -s 8G target.img
    ROOTDISK=$PWD/target.img tools/linux/qemu.sh     # log in as installer
    INSTALLED=$PWD/target.img tools/linux/qemu.sh --installed

### foxyn-install

`foxyn-install` (`tools/linux/foxyn-install`, in the image as
`/usr/sbin/foxyn-install`) installs the running system on a disk that
then boots on its own, with no questions beyond the confirmation (`-y`
skips it): one disk, no swap, no encryption.

    foxyn-install [-y] [-t hammer2|ufs] [-b BOOTDISK] [-s ESPSIZE] DISK

It erases `DISK` and gives it a GPT with two partitions: slice 0, the
EFI system partition (FAT32, 256 MiB, `-s`), and slice 1, the root
(HAMMER2 by default, with `newfs_hammer2`'s default `DATA` PFS; `-t ufs`
for UFS). It copies the running system with `cpdup` (`bin`, `boot`,
`etc`, `lib`, `libexec`, `root`, `sbin`, `usr`, `var`; on root.iso,
`/etc`, `/var` and `/root` are the tmpfs copies, so the password database
comes along), writes an `fstab` with a read-write root, drops
`root_rw_mount="NO"` from `rc.conf`, and fills the ESP:
`EFI/BOOT/BOOTX64.EFI` (the loader itself, not `boot1.efi`) and `boot/`
with `dloader.rc`, the defaults, the kernel and the modules. Its
`loader.conf` takes the console the running system was booted with
(`kenv console`) and sets `vfs.root.mountfrom`.

`loader.conf` and `fstab` name the slices by their GPT unique ids,
`slice-by-uuid/<uuid>`: devfs makes that alias for every GPT slice, so
the installed disk finds its root on any bus and machine. An image
installed under QEMU can be written to a USB stick (`dd
if=installed.img of=/dev/sdX bs=4M conv=fsync` on Linux) and boots a PC
from it, leaving the PC's own disks alone. `-b` names the disk instead
(`serno/<serial>`, `vbd0`, `da0`, ...); without the uuid aliases, the
disk's serial number name (found by device number in `/dev/serno`) is
the default, else `vbd0`.

The base programs include what it runs: `gpt`, `newfs_msdos`,
`newfs_hammer2`, `newfs`, `mount_msdos`, `mount_hammer2`, `hammer2`,
`cpdup`, `kenv` and `dd`.

`boot-test.sh --install` boots root.iso with an empty disk
(`$OBJDIR/installed.img`, `INSTALL_SIZE`, default 4G) as `vbd2`, runs
`foxyn-install -y vbd2` (`INSTALL_ARGS` adds options) and powers off;
`boot-test.sh --installed` boots that disk alone (`qemu.sh --installed`:
no ESP from the host, the firmware starts the disk's own loader) and runs
the same tests as `--root`. With `INSTALLED_BUS=usb` the disk is a USB
stick on its own xHCI controller (the firmware boots it, the kernel
finds the root on `da8` by its uuid), as on a PC.

## QEMU

OVMF runs `EFI/BOOT/BOOTX64.EFI` (our `loader.efi`). The loader reads
`boot/dloader.rc`, `boot/loader.conf` (serial console) and
`boot/kernel/kernel` from the ESP, which QEMU serves as a read-only
virtual FAT disk (`-drive file=fat:<dir>`). The kernel mounts `root.iso`
and init runs its `/etc/rc`; with `--kernel-only` there is no root
filesystem and the boot ends at the `mountroot>` prompt.
`ROOTDISK=<img>` attaches an extra virtio disk.

The EFI loader also loads `ehci.ko` and `xhci.ko` at every boot (the
GENERIC kernel has only the UHCI and OHCI USB drivers built in), so
`build.sh esp` always builds these two modules and puts them in
`boot/kernel`. When `build.sh modules` built them, `build.sh rootfs`
puts all the modules (682, 62 MB without debug information) in the
image's `/boot/kernel`, as installkernel does: devd(8) loads a driver from
there when a device has none (`ums` for a USB mouse, sound, network), and
the installers copy them. Without, the image has the ESP's two. USB
devices attach under QEMU on `qemu-xhci`,
`nec-usb-xhci` and EHCI controllers (`-- -device qemu-xhci,id=x -device
usb-tablet,bus=x.0`); `boot-test.sh` always attaches a USB keyboard to a
`qemu-xhci` controller.

The console is a QEMU window (gtk, else sdl, whichever the installed QEMU
has) when there is a graphical session (`$DISPLAY` or `$WAYLAND_DISPLAY`),
with the serial console copied to the terminal. Without a session, or
with a QEMU that has no window backend (Arch's `qemu-base`, Debian's
`qemu-system-x86` without `qemu-system-gui`), `qemu.sh` says so and uses
the serial console. `boot-test.sh` always runs headless.

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
in as root over the serial line, lists the running programs, runs
`/root/tests/cron-check` (cron, crontab and anacron), `/root/tests/net-check` (the network and TLS), `/root/tests/cc-check`
(the image's compilers) and `periodic daily`. It
has QEMU's user-mode network answer HTTP on 10.0.2.100 (a `guestfwd`
that runs a small script for each connection), so the network test needs
no network on the host. `boot-test.sh --disk` does the same with
`disk.img` and ends with `halt -p`; CI boots the disk twice. `check-boot-log.sh` then checks the serial log, one
check per CI step (`all` runs them all):

| Check | What it verifies |
|-------|------------------|
| `rtld` | dynamically linked programs ran (ld-elf.so.2, libc, libutil, ncurses) |
| `rcd` | lists commands the rc.d scripts did not find (not fatal) |
| `identity` | `uname -a` reports FoxynBSD |
| `basics` | terminfo, a writable tmpfs `/tmp`, login classes, devfs rules after the password database |
| `syslogd` | a `logger(1)` message reached `/var/log/messages` |
| `daemons` | `syslogd`, `cron` and `devd` still run after login |
| `cron` | `cron(8)` (Cronie) ran a root crontab's job and an `/etc/cron.d` job; `nobody` installed, listed and removed a crontab (images with `su`); `/etc/anacrontab` parses and `anacron(8)` ran a test job |
| `periodic` | `periodic daily` finished and found every command |
| `cxx` | a static C++ program throws through two frames and catches |
| `runtime` | compiler-rt builtins in a static and a dynamic program; C++ constructors, destructors and an exception across a shared library; `atexit` order; `dlopen(3)`; named semaphores; `umtx` wait and wake; `eventfd(2)`; `/dev/shm` and `shm_open(3)` as root and an unprivileged user (sources in `tools/linux/tests`) |
| `fs` | `/tmp` and `/var/tmp` sticky and writable; `/etc`, `/var/run`, `/var/log`, `/var/db`, `/root` writable; devd sockets accept connections and its pidfile names a live process; `/` read-only on root.iso and writable on disk.img; `master.passwd` and `spwd.db` mode 600 |
| `abi` | programs with either ELF ABI note (FoxynBSD, DragonFly) run |
| `kld` | the loader loaded `xhci.ko` (and `ehci.ko`) at boot; modules in `KLD_TESTS` load and unload when present and not already loaded; modules already in use are reported and left loaded |
| `usb` | the USB keyboard that `boot-test.sh` attaches to a `qemu-xhci` controller attached as `ukbd0` |
| `net` | `dhcpcd` runs and leased `vtnet0` an address, a default route and a name server; `fetch` gets `http://10.0.2.100/` through the gateway |
| `tls` | `fetch` over HTTPS to an `openssl s_server` in the guest, with a certificate `openssl req` made there (LibreSSL's libcrypto and libssl); `ssh-keygen` makes RSA and Ed25519 keys when the image has OpenSSH |
| `disk` | on a disk (`disk.img`, an installed disk): the root is UFS or HAMMER2 and writable (skipped for root.iso) |
| `persist` | not in `all`: a second boot of `disk.img` found the first one's boot count in `/var/db`, kept the password database and had a clean file system |
| `install` | not in `all`: `foxyn-install` finished (`boot-test.sh --install`) |
| `desktop` | not in `all`: Xorg (`scfb`), libinput, fonts and GNUstep from DPorts; a temporary unprivileged user runs a GNUstep application and an xterm shell on a pty (`DESKTOP_CHECK=1 boot-test.sh --disk` or `--installed`; needs the internet) |
| `audio` | not in `all`: PipeWire, WirePlumber and JACK from DPorts, libepoll-shim built against `eventfd(2)`; `pw-play` plays a 440 Hz tone through the JACK tunnel to the HDA card, and QEMU's recording of the card has at least 3 s of it (`AUDIO_CHECK=1 boot-test.sh --disk` or `--installed`; needs the internet) |
| `pkg` | not in `all`: `pkg(8)` bootstrapped from DragonFly's mirror, the dynamic `pkg` runs, `pkg install inxi` brought Perl, and both run (`PKG_CHECK=1 boot-test.sh --disk` or `--installed`; needs the internet) |
| `cc` | gcc 12 (`cc`, `c++`) and gcc 8 (`CCVER=gcc80`) compile, link and run C, static C and C++ with an exception in the image (skipped for an image without compilers) |
| `ruby` | Ruby with `openssl` (LibreSSL), `yaml` (libyaml), `zlib` and `socket`, `Net::HTTP` to `http://10.0.2.100/`, RubyGems and DragonFly gem-platform matching; with a `cc`, `mkmf` builds and loads a C extension, as `gem install` does (skipped for an image without Ruby) |

A failing boot leaves the serial log in `$OBJDIR/qemu/`. On a kernel
trap, `boot-test.sh` resolves the faulting instruction to a source line
(`<log>.fault`); with `machdep.print_user_faults`, it does the same for
faults in `ld-elf.so.2`.

## LibreSSL and Ruby

FoxynBSD's base has LibreSSL 4.3.4 (`crypto/libressl`; DragonFly has
3.6.1) and Ruby 4.0.9 (`contrib/ruby`, `usr.bin/ruby`), which DragonFly
does not have; Ruby's `openssl` extension needs LibreSSL 3.9 or later.

LibreSSL builds as before: `lib/librecrypto` (`libprivate_crypto.so.57`),
`lib/libressl` (`libprivate_ssl.so.60`), `usr.bin/openssl` and
`usr.bin/nc`, with source lists, `HAVE_*` settings and the x86_64
assembly taken from what LibreSSL's own configure produces for the
target; `crypto/libressl/README.DRAGONFLY` says how to regenerate them.
The portable LibreSSL's `include/compat` headers stand in for most of
DragonFly's earlier local changes (`pledge`, `unveil`, `syslog_r`, ...).
LibreSSL 4 removed old interfaces, which a few programs used: `BN_init`
(`libtelnet`, `newkey`/`chkey`), `BN_MASK2` and `BN_zero`'s return value
(`dc`), `EVP_add_cipher_alias` (`tcpdump`); they are changed as OpenBSD
changed them. `Makefile_upgrade.inc` removes the old libraries and
headers on an upgrade.

Ruby is built by its own configure and makefiles, which `usr.bin/ruby`
drives (on DragonFly natively, or here as a cross build). Its extensions
link the base's libraries: `openssl` (LibreSSL), `psych` (YAML, which
RubyGems needs: `contrib/libyaml`, `lib/libyaml`, a private
`libprivate_yaml.so.2`), `zlib`, `socket`; `fiddle` is not built, as the
base has no libffi. A cross build needs a Ruby of the same version on the
build host (BASERUBY), which runs the generators, the extensions' setup
and the gems' installation: `build.sh` builds it first from the same
`contrib/ruby`, for the host (`$OBJDIR/host/obj/ruby`), so the host needs
no Ruby. Its precompiled core library (`builtin_binary.rbbin`) also goes
into the target build, which cannot make it (it would have to run the
target's miniruby): without it the interpreter would start as miniruby
does, compiling that code at each start and without RubyGems. The
format records the version, word size and byte order, which the host and
the target share.

`rbconfig.rb` records how Ruby was built, and `mkmf` builds the gems' C
extensions with it on the installed system. `usr.bin/ruby` installs it
naming the system's `cc`, `c++`, `install` and `mkdir`, without the
build's `deps` directory; here `build.sh` also has it drop the flags that
configure found `xcc` (clang) takes and the image's `cc` (gcc 12) does
not (`RUBY_RBCONFIG_DROP`). `gem install` and Bundler then work in the
image, C extensions included (tested with `msgpack`).

Ruby is in the image with the whole world, not in the base image. The
`ruby` test runs it there with each of those extensions, `Net::HTTP`
through QEMU's network and RubyGems. With the image's compilers, it also has
`mkmf` build and load a small C extension.

## Packages (DPorts)

FoxynBSD runs DragonFly BSD's packages. On a writable root (`disk.img`
or an installed disk), `make -C /usr pkg-bootstrap` fetches DragonFly's
`pkg-static` from its mirror and installs `pkg` and the CA certificates
(`ca_root_nss`, which makes `/etc/ssl/cert.pem` a link to its bundle);
`pkg` then uses DragonFly's `dragonfly:6.6:x86:64` repository:

    # make -C /usr pkg-bootstrap
    # pkg install inxi
    # inxi -Fxxxz -c 0

A few packages, `pkg` among them, link DragonFly's private LibreSSL
(`libprivate_crypto.so.50`, `libprivate_ssl.so.53`), which FoxynBSD's
LibreSSL 4.3 replaced. `/etc/libmap.conf` has the run-time linker load
FoxynBSD's versions instead; every LibreSSL function that `pkg` imports is
in them, and `pkg update`, `install`, `check` and `audit` work through
them. `pkg-static` needs none of this.

`PKG_CHECK=1 boot-test.sh --disk` (or `--installed`) runs
`/root/tests/pkg-check` after the other tests: it bootstraps `pkg`,
installs `inxi` (which brings Perl), checks `inxi --recommends` and parses
its JSON output, and prints inxi's report (`inxi| ` lines) and `pciconf -lv`
(`pciconf| `). It also collects and filters a disposable hardware report using
the program from the guide; `check-boot-log.sh pkg` checks it. The JSON and
the report used by the filter test are not logged.
It needs the internet and DragonFly's mirror, so CI does not run it.

A first graphical session comes from the same packages.
`DESKTOP_CHECK=1 boot-test.sh --disk` gives the machine a VGA card and a
USB mouse and runs `/root/tests/desktop-check`. It installs Xorg/scfb,
libinput, fonts, GNUstep, Sudoku, xterm and the X authority utilities.

The test creates a temporary unprivileged account and a per-run Xauthority
cookie, starts X with `-auth` and `-nolisten tcp`, and checks that a client
without the cookie is rejected while the test user with the cookie can
connect. It starts Sudoku and xterm as that user, then removes the account
and temporary authority files. This is an isolated smoke test, not a
production session launcher or a security audit.

Xorg draws on syscons' EFI framebuffer with `scfb` (there is no KMS
under QEMU, so no `/dev/dri`); with modesetting, scfb and vesa all
matching, it gives up ("Cannot run in framebuffer mode") unless the
configuration names one. Input reaches it through evdev and libinput.
GNUstep applications abort without a font package ("Glyph generation
with no font"). The automated test also starts xterm as the temporary
unprivileged user and checks its window and shell's terminal descriptors.
To see it: `qemu.sh --disk` (a window) after running the
test on `disk.img`. For headless screenshots, set `MONITOR_SOCKET` to a
new local Unix socket path and use `--serial --disk --desktop-devices`;
connect to the QEMU monitor and run `screendump /absolute/path/image.ppm`.
The monitor controls the VM and is intended for trusted local use. XLibre, Gershwin and OpenRC are not in DPorts (issue #13).
An experimental source build of Gershwin TextEdit, including its known
license-review gaps, is described in
[`docs/desktop-textedit.md`](../../docs/desktop-textedit.md).
The WindowManager build and its currently failing client-launch check are
described in [`docs/desktop-windowmanager.md`](../../docs/desktop-windowmanager.md).
The tested X terminal and Gershwin Terminal build investigation are in
[`docs/desktop-terminal.md`](../../docs/desktop-terminal.md).

A desktop image to try, from the same packages:

    tools/linux/build.sh desktop    # $OBJDIR/desktop.img (DESKTOP_SIZE=8G)
    tools/linux/qemu.sh --desktop   # boots it; the session starts on vt9

`build.sh desktop` makes a new disk like `build.sh disk`, boots it once in
QEMU (`boot-test.sh --desktop-setup`) and runs `foxyn-desktop -y` on it,
which is in the image as `/usr/sbin/foxyn-desktop`. That installs X
(`scfb`), libinput, fonts, twm, xterm, the `llvm19` compiler and the
libraries GNUstep needs from DPorts, and creates the user `foxyn` without
a password (like root on these images). As that user it builds GNUstep
Make, libobjc2, libdispatch, Base, GUI and Back from the revisions pinned
by `contrib/gnustep-*` and `contrib/libdispatch` with
`tools/desktop/build-gnustep.sh` (see
[`docs/desktop-gnustep.md`](../../docs/desktop-gnustep.md)), in Gershwin's
layout under `/System`, Gershwin's Menu and session supervisor with
`build-menu.sh` ([`docs/desktop-menu.md`](../../docs/desktop-menu.md)),
System Preferences and Workspace with `build-systempreferences.sh` and
`build-workspace.sh`
([`docs/desktop-workspace.md`](../../docs/desktop-workspace.md)), the Eau
theme and Gershwin's system-wide defaults and fonts with `build-eau.sh`
and `install-gershwin-system.sh`
([`docs/desktop-eau.md`](../../docs/desktop-eau.md)), then WindowManager
(`build-windowmanager.sh`: pinned source, checksum, the titlebar patch)
and TextEdit (`build-textedit.sh`) against it; the helpers are in the
image's `/usr/share/foxynbsd/desktop`. `/System` and the applications in
`/System/Applications` end up root's. Last, it enables the `foxyn_desktop`
rc.d service. `DESKTOP_GNUSTEP=dports` (`foxyn-desktop -g dports`)
installs DPorts' older GNUstep in `/usr/local/GNUstep` instead, with
Sudoku as the application; `foxyn-desktop -w twm` skips WindowManager. At
boot, the service starts X as root with a fresh cookie and no TCP
listener, gives the cookie to `foxyn` only, and runs `~foxyn/.xsession` as
that user: Gershwin's session, where `gershwin-session` supervises
Workspace, Menu and WindowManager, with TextEdit and an xterm. Menu's
System > Log Out ends the session; X stops and the console login remains
(Ctrl-Alt-F1). With `-g dports` the session is WindowManager (twm when it
is missing), Sudoku and an xterm, and ends when the window manager exits;
twm's menu (left button on the background) has "Log out". To turn it off,
set `foxyn_desktop_enable="NO"` in `/etc/rc.conf`; `service foxyn_desktop
stop` ends a running session. It needs the internet; `DPORTS_MIRROR` picks
the mirror, and a failed run leaves an existing `desktop.img` in place.
`boot-test.sh --desktop` checks the result: the session started at boot
with its windows, a client without the cookie is rejected, ending the
session (SIGTERM to the supervisor, as Log Out does) stops X, the service
and the user's processes, and QEMU's screen is saved in
`$OBJDIR/qemu/desktop.ppm`. This desktop runs on DPorts' Xorg, not XLibre,
and has no display manager; it is not the issue #13 desktop yet. To run a
second VM while another one runs, give it its own `QEMU_STATE` directory
(see `qemu.sh`).

Sound: `AUDIO_CHECK=1 boot-test.sh --disk` gives the machine an Intel HDA
card whose output QEMU writes to `$OBJDIR/qemu/audio.wav`, and runs
`/root/tests/audio-check`. It installs `pipewire wireplumber jackit
cmake`, builds libepoll-shim from source, loads `snd_hda`, starts `jackd
-d oss` on `/dev/dsp` and PipeWire with `libpipewire-module-jack-tunnel`,
and plays a 440 Hz tone with `pw-play`. After QEMU exits, `boot-test.sh`
measures the recording (`audio-wav: 4.1 s of sound, 440 Hz`).
At boot, `/dev/shm` points to the same tmpfs directory used by
`shm_open(3)`, `/var/run/shm`; before installing packages, the audio test
checks that both paths reach the same object for root and an unprivileged user.
DPorts' libepoll-shim was built without `eventfd(2)` and emulates it
with kqueue descriptors, which the kernel does not pass over
`SCM_RIGHTS`: PipeWire's clients are disconnected (`error -45`). Built
on FoxynBSD, it finds the native `eventfd` and leaves `eventfd()` to
libc. PipeWire starts WirePlumber itself (DPorts' `10-wireplumber.conf`;
a second one stalls both), without its camera monitor (`monitor.v4l2 =
disabled`): unloading it faults in libinotify. `DPORTS_MIRROR` picks a
faster mirror than pkg's default, e.g.
`https://mirror.sjtu.edu.cn/dragonflybsd/dports`.
[`docs/hardware-report.md`](../../docs/hardware-report.md) says how to make a
hardware report with inxi and the base system's tools, and what to remove
before sharing it.

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

* gcc 8's runtime comes from `lib/libcompiler_rt` (see above), so
  `gnu/lib/gcc80/csu` and `libgcc` are not built. The world's own C++
  programs link gcc 8's `libstdc++`, as in `base`. gcc 12's runtime
  (`gnu/lib/gcc120`) is built last, with `xgcc` and `xc++` (see above).
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
| `linux-build.yml` | every push and PR to `dev` | Ubuntu 24.04: *Kernel, loader and boot tree* (kernel-only boot to `mountroot>`), *Kernel modules* (all 682), *Userland and boot to a shell* (base image, ELF audit, test modules, boot to a root login, every boot-log check), *Whole world* (`KEEP_GOING=1`, then `build.sh` with no arguments: the full image, ELF audit, boot to a root login, every boot-log check) |
| `linux-hosts.yml` | changes to `tools/linux`, the compiler runtime or the workflow; weekly; by hand | Arch Linux container (clang kernel and modules) and Debian stable container (gcc): tools, kernel, all modules, loader, base, root image, ELF audit, boot, `check-boot-log.sh all` |
| `linux-lint.yml` | changes to `tools/linux`, workflows, the loader menu (`stand/boot/dloader/cmds.c`), `.gitmodules` or `contrib/` | the scripts parse under dash and bash, `shellcheck -S error`, the submodule records (`check-submodules.sh`: each `contrib/<name>.README.DRAGONFLY` names the commit the tree records), the boot menu logos (`check-logos.sh`: 16 lines of 33 columns, colored and plain variants alike), the ELF audit rejects a glibc program |

All jobs are blocking. The names of the `linux-build.yml` jobs are the
required check names: do not rename them. The containers get `/dev/kvm`
from the runner; without it QEMU falls back to TCG within the 900 s boot
timeout. Failed builds and boots put the end of the log and the serial
console into a job annotation, and the logs, serial output and audit
report are uploaded as artifacts.

## Known limitations

* The root image is a read-only cd9660 with tmpfs over `/etc`, `/var`,
  `/tmp` and `/root`; `build.sh disk` makes a writable UFS one, which
  boots with the ESP that QEMU serves (the host `makefs` has only the ffs
  back end). The BSD Installer and `foxyn-install` make disks that boot
  alone. CI runs the whole BSD Installer only up to its welcome screen;
  its install was tested by hand under QEMU (UEFI, HAMMER2). The base
  image has `foxyn-install` but not the BSD Installer.
* The base image (`ROOTFS=base`) has only the programs of `build.sh
  base`; the default image has the whole world.
* The images come without packages; `make -C /usr pkg-bootstrap` gets
  `pkg` and DragonFly's packages on a writable root (see "Packages").
  The packages are DragonFly's, built for its base. inxi 3.3.11
  found no disk and no graphics device under QEMU.
* The gcc 12 compiler is built for the image, not as a cross compiler for
  the host; its runtime's C parts are compiled by the host gcc (`xgcc`)
  and its `libstdc++` by clang (see above).
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
* No QEMU window: `qemu.sh` prints why (no graphical session, or no gtk/sdl
  in this QEMU: install `qemu-desktop` / `qemu-system-gui`).
* The boot test times out without KVM: `BOOT_TIMEOUT=1500
  tools/linux/boot-test.sh --root`. Inside a container, pass
  `--device /dev/kvm`.
* A program fails to start in the image: `LD_DEBUG=1` works (rtld is
  built with debugging), and `qemu.sh` (with the root image) turns on
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
| root image | boots through `/etc/rc` and `rc.d` to a root login; syslogd, newsyslog, cron (Cronie) and anacron, devd, periodic |
| whole world (`build.sh world`) | builds into the sysroot (CI job *Whole world*) |
| ELF audit | no host contamination in the sysroot and the image |
| network (`dhcpcd`), LibreSSL 4.3, `fetch` | in the base image; tested at boot (DHCP lease, HTTP, HTTPS) |
| Ruby 4.0 | in the world image with openssl, psych, zlib, socket and RubyGems; tested at boot |
| writable root on a disk (`build.sh disk`) | UFS on GPT, made with the host `makefs`; boots twice in CI |
| gcc 12's runtime (`gnu/lib/gcc120`) | built by the world (`xgcc`, `xc++`); the image's gcc 12 and gcc 8 build and run C and C++ |
| packages (DPorts) | `pkg-bootstrap`, `pkg` and `pkg install inxi` (Perl 5.36) work on a disk image; tested with `PKG_CHECK=1`, not in CI |
| sound: PipeWire (DPorts) | through JACK to `snd_hda`, with libepoll-shim built against `eventfd(2)`; tested with `AUDIO_CHECK=1`, not in CI |
| X and GNUstep (DPorts) | Xorg on `scfb` with USB keyboard and mouse, a GNUstep application; tested with `DESKTOP_CHECK=1`, not in CI |
| installers | the BSD Installer starts in CI and installs by hand (disklabel64, `/boot` UFS, HAMMER2, `boot1.efi`); `foxyn-install` installs and the disk boots alone in CI |
