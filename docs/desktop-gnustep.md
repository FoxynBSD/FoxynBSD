# GNUstep from the pinned sources

`tools/desktop/build-gnustep.sh` builds the GNUstep runtime that the
Gershwin desktop uses from the revisions pinned by the `contrib/gnustep-*`
and `contrib/libdispatch` submodules, instead of DPorts' older packages (Base 1.29, GUI 0.31).
`foxyn-desktop(8)` runs it by default (`-g source`); `build.sh desktop`
puts the helper and its patches in the image's
`/usr/share/foxynbsd/desktop`.

| Component | Submodule | Revision | Version |
| --- | --- | --- | --- |
| GNUstep Make | `contrib/gnustep-make` | `4e31a0310df5f0aa96ccd816d3b626e67c36f535` | 2.9.3 + 59 |
| libobjc2 | `contrib/gnustep-objc2` | `c9f4002ade04d755f2a0e6c83daf2738dca03759` | 2.2 + 82 (`libobjc.so.4.6`) |
| libdispatch | `contrib/libdispatch` | `95f592ab637c4d7916fa05d4d80cbc1ec7d0b2b8` | swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a |
| GNUstep Base | `contrib/gnustep-base` | `5bda52220a6d67382c9851cdfd91d459bfd2b489` | 1.31.1 + 652 |
| GNUstep GUI | `contrib/gnustep-gui` | `8f804fd520c60800961e0bee072066f4bbadca94` | 0.32.0 + 1294 |
| GNUstep Back | `contrib/gnustep-back` | `bbcc3de7cab63b6e65944edf02f2bbef9d8a7bbd` | 0.32.0 + 114 (Cairo) |

The guest has no copy of the source tree, so the helper downloads each
revision's GitHub archive and checks its SHA-256 (recorded in the script).
On the build host, each archive's contents were compared with the
submodule's checkout and were identical. libobjc2 also needs robin-map
v1.4.0 (MIT), which its CMake build would clone with git; the helper uses
that tag's archive, also checksummed. DPorts has robin-map 1.3.0.

## Layout and linking

GNUstep Make is configured with `--with-layout=gershwin`: everything is
under `/System` (`/System/Library/Libraries`, `/System/Library/Headers`,
`/System/Library/Makefiles`, `/System/Applications`), and the
configuration file is `/System/Library/Preferences/GNUstep.conf`. The
libraries install in the System domain. Make is configured twice, before
and after libobjc2, so that it records libobjc2's runtime: the library
combo is `ng-gnu-gnu`, with the `gnustep-2.2` ABI, native exceptions and
ARC.

libdispatch is built after libobjc2 and before Base, which then uses it,
with the DragonFly patch described in
[desktop-libdispatch.md](desktop-libdispatch.md). It installs
`libdispatch.so` and its own `libBlocksRuntime.so` in
`/System/Library/Libraries` and its headers in
`/System/Library/Headers/dispatch` and `os`. Its `Block.h` is not
installed: libobjc2's, with its embedded blocks runtime, stays. The
header directories are given as absolute paths: they are CMake `PATH`
cache variables, and a relative value on the command line is made
relative to the current directory, which first put them in the build
user's working directory and left Base without libdispatch. The
libdispatch patch also enables its CoreFoundation interface
(`_dispatch_get_main_queue_handle_4CF`) on DragonFly, which Base's run
loop uses to run blocks sent to the main queue.

Everything is compiled with DPorts' `clang19` and linked with its lld.
With GNU gold, libobjc2 got two `DT_INIT_ARRAY` entries and programs
aborted at exit in `__deregister_frame_info_bases` (see
[desktop-eau.md](desktop-eau.md)). The libraries and every program built
with this GNUstep Make get a runpath of `/System/Library/Libraries`
(GNUstep Make records the `LDFLAGS`), so they load without `GNUstep.sh`'s
`LD_LIBRARY_PATH`.

DPorts' GNUstep cannot be installed at the same time: its libobjc2 has
the same library name, `libobjc.so.4.6`, and its headers in
`/usr/local/include/objc` would be used before the new ones. The helper
and `foxyn-desktop -g source` refuse to run when DPorts' `libobjc2` is
installed.

## FoxynBSD changes

Three patches are applied to GNUstep Base, from `tools/desktop/patches`:

- `gnustep-base-dragonfly-uuid.txt`: on DragonFly, `<sys/statvfs.h>`,
  `<sys/mount.h>` and `<sys/user.h>` include `<sys/uuid.h>`, whose
  `uuid_t` conflicts with `NSUUID.h`'s once it renames `uuid_t`; including
  it first avoids that.
- `gnustep-base-kvm-configure.txt`: configure's kernel-memory test has a
  missing parenthesis and never compiles, so every system without procfs
  falls back to `GS_FAKE_MAIN`; then a `+load` method that reaches
  `NSProcessInfo` before `main()` aborts (Gershwin Workspace). With the
  test fixed, DragonFly's libkvm provides the arguments.
- `gnustep-base-connection-null.patch`: `+connectionWithRegisteredName:...`
  wrote the remote name into a nil connection; Workspace crashed there at
  every start (see [desktop-workspace.md](desktop-workspace.md)).

- `gnustep-base-dispatch-pipe.txt` (2026-11-11): on Unix systems other
  than Linux, libdispatch's main queue handle is a pipe packed in a 64-bit
  value (read end in the high 32 bits, write end in the low 32 bits).
  `NSRunLoop.m` called `_dispatch_get_main_queue_handle_4CF()` without a
  declaration, so the value was truncated to an `int`, the write end,
  and the run loop waited for it to become readable: blocks dispatched to
  the main queue, and operations on `NSOperationQueue`'s main queue, never
  ran. The patch declares the function, watches the read end and empties
  the pipe before draining the queue, as the Linux code does with its
  eventfd.

One patch is applied to GNUstep Back: `gnustep-back-mouse-init.txt`
(2026-11-11) reads the mouse settings when the X input source is set up
instead of on the first button press, where their registration (a
synchronous call to `gdnc`) handled the press's button release first; see
`desktop-windowmanager.md`, "Lost button releases".

These are small changes to the upstream sources that should go upstream.
Make, libobjc2 and GUI build unmodified.

## Licenses

GNUstep Make is GPL; Base, GUI and Back are LGPL with GPL parts (see
`COPYING` and `COPYING.LIB` in each); libobjc2 and robin-map are MIT.
These are the source trees' notices, not a file-level audit. The build
uses DPorts' libraries (libxml2, libxslt, libffi, GnuTLS, ICU, Cairo,
libXft, libjpeg, libtiff, ...), which are not part of the base.

## Test, 2026-11-10

QEMU with KVM, OVMF, `-vga std`, kernel and world from `69d12dacac`, on a
copy of the `build.sh desktop` image with DPorts' GNUstep removed. As the
unprivileged user `foxyn`, the helper built and installed everything in
`/System` (41 MB), reporting `installed in /System (ng-gnu-gnu)`. Then
`foxyn-desktop -g source` built WindowManager and TextEdit against it;
`ldd` shows `libgnustep-gui.so.0.32.0`, `libgnustep-base.so.1.31.1` and
`libobjc.so.4.6` from `/System/Library/Libraries`. The session started by
`service foxyn_desktop start` ran WindowManager, TextEdit (window
`UNTITLED`) and an xterm as `foxyn`, and the desktop-session test passed,
including the stop. This tests startup only: no input, theme, Workspace,
Menu, XLibre or physical hardware.

The whole path was then run from a new image on the Linux host:
`build.sh rootfs`, then `build.sh desktop` with the SJTU DPorts mirror. In
about 15 minutes, `foxyn-desktop` reported `installed GNUstep in /System`,
WindowManager and TextEdit in `/System/Applications`. On the next boot,
`boot-test.sh --desktop` passed: WindowManager, xterm and TextEdit ran as
`foxyn`, the `Terminal` and `UNTITLED` windows were mapped, X rejected a
client without the cookie, and `service foxyn_desktop stop` ended X and
the user's processes. The sessions log `Failed to get _NET_WORKAREA`
and `gdnc - unable to register with name server`; their causes were not
investigated.

## Base's test suite, 2026-11-11

GNUstep Base's own tests (`Tests/base` of the pinned revision), run in
QEMU on the `build.sh desktop` image as `foxyn` against the GNUstep in
`/System`. The installed `gnustep-tests` is a stub (GNUstep Make was
configured without bash), so a copy was run with DPorts' bash, installed
in the test VM only; some tests need Base's source tree configured
(`./configure`, for `config.h`/`config.mak`).

- First run: 13,077 tests passed, 40 "dashed hopes" (tests marked as
  expected to fail upstream), and 11 failed: 5 that need the main queue
  (`NSOperation/threads.m`, `NSRunLoop/dispatch.m`), fixed by
  `gnustep-base-dispatch-pipe.txt`, and 6 network tests (HTTPS to
  google.com; `http://www.gnustep.org`, which redirects to HTTPS).
- The network tests failed because GnuTLS trusted no certificate
  authority: it reads them through p11-kit's trust module, which DPorts'
  p11-kit builds without a path (`trust list` showed none). Base's own
  bundle is only a fallback when that call fails, and it did not fail.
  `foxyn-desktop` now installs `ca_root_nss` and a module file in
  `/usr/local/etc/pkcs11/modules` that points the trust module at
  `/usr/local/share/certs/ca-root-nss.crt` (117 authorities); this
  affects every GnuTLS program, not only GNUstep.
- With Base rebuilt with the patch and the trust path set, the main
  queue and network directories passed (`NSOperation`, `NSRunLoop`,
  `NSURLConnection`, `NSStream`, `NSURLHandle`: 0 failures).

`lld` crashed (SIGSEGV) twice while the suite built its tests, without a
failed build; not investigated. `desktop-session gnustep` (run by
`boot-test.sh --desktop`) builds and runs `tests/gnustep-mainqueue.m`:
5 blocks dispatched to the main queue and an `NSOperationQueue` main
queue operation must run from the run loop. `desktop-session wait` checks
that p11-kit trusts at least one certificate authority.

## libobjc2 and GNUstep GUI tests, 2026-11-11

Same QEMU setup, image from `367ed195d0`.

- **libobjc2** (pinned revision with robin-map, built as
  `build-gnustep.sh` does but with `-DTESTS=ON`, then `ctest`): 194 of
  198 passed. The 4 failures are one test, `UnexpectedException`, in its
  four variants: an Objective-C exception that nothing catches must reach
  the handler set with `objc_setUncaughtExceptionHandler`; the process
  aborts instead. `objc_exception_throw` calls the handler only when
  `_Unwind_RaiseException` returns `_URC_END_OF_STACK`. A C program that
  raises an exception no frame claims gets 5 (`_URC_END_OF_STACK`) when
  built with the base `cc` (GCC 8), but a value that looks like the
  exception's address when built with DPorts' `clang19`, with
  `-lgcc_pic` (the default) or `-lgcc_eh`; `_Unwind_Backtrace` walks the
  same frames to the end of the stack in both. Catching exceptions
  worked (libobjc2's other exception tests passed); an uncaught exception
  in a clang-built program aborted without GNUstep's "uncaught
  exception" report.

  The cause was the link, not the compiler: DPorts' clang links
  `/usr/lib/gcc80`'s `libgcc_pic.a`, the base `cc` (gcc 12) the one in
  `/usr/lib/gcc120`. On the Linux host, `build.sh` compiled gcc 8's
  unwinder (`gnu/lib/gcc80/libgcc_eh`, and its PIC copy in
  `libgcc_pic.a`) with clang, whose code for libgcc's
  `_Unwind_RaiseException` returned a clobbered value; gcc 12's runtime
  was already compiled with the host gcc (`xgcc`). `build.sh` now
  compiles gcc 8's unwinder with `xgcc` too (and removes objects another
  compiler made: make does not notice the change). Then the C program
  got `_URC_END_OF_STACK` with both compilers and both links, and
  libobjc2 passed 198 of 198 tests. `xgcc` also no longer emits the x86
  ISA notes (`.note.gnu.property`) of newer assemblers, which DragonFly's
  gold warned about (`unknown program property type 0xc0010001`) at every
  link with gcc 12's crt and libgcc; gcc 12's runtime is rebuilt once for
  it.
- **GNUstep GUI** (`Tests/gui` of the pinned revision, configured, run as
  `foxyn` in the desktop session's display):
  - with GNUstep's own theme (`GSTheme GNUstep` in the user's defaults):
    4,111 tests passed; "application is hidden after hide:" failed
    (it depends on the window manager); 9 `render.m` comparisons with
    reference images that the previous run, with Eau, had captured are
    not counted;
  - with the session's settings (Gershwin's Eau theme): 4,102 passed, 7
    tests and one set failed and `NSPanel/behaviour.m` aborted, all of
    them passing with GNUstep's theme: a box's fill colour, the colour
    panel's new-button image, the system font size for size 0,
    `NSMenuView` item area insets, a table header title's alignment,
    alternating row colours and text field bezels by default. These are
    the Eau theme's (see `desktop-eau.md`).
  - The first run, without access to the display (the session's cookie
    is readable by root only), had failed every test that needs a window
    server; that run is not counted.

