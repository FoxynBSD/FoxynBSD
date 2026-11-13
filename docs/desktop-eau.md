# Eau theme for Gershwin on FoxynBSD

Eau is the selected theme for the Gershwin desktop. Upstream describes it as
Gershwin's default theme. The source examined for this integration was
[gershwin-eau-theme](https://github.com/gershwin-desktop/gershwin-eau-theme)
commit `3d741fbc61b62acb3dc1f3213ebe50a8a81c579c`; its GitHub source
archive has SHA-256
`e6bf5ba0603ff3050da4fe1151c4a82c428567d437f9b3e9ea22127bcb86fe8d`.

Upstream's GNUstep Make build creates `Eau.theme` and installs it under the
GNUstep library's `Themes` directory. The theme contains Objective-C code and
image resources, and its build uses ARC and X11. On 2026-11-07 an
unmodified build was attempted as an unprivileged user on a disposable
FoxynBSD QEMU disk with GNUstep Make 2.9.2, GNUstep GUI 0.31.1 and DPorts
llvm19. The build stopped in the first source file, `Eau.m`: the compiler
reported undeclared `dispatch_async`, `dispatch_sync` and
`dispatch_get_main_queue`, and the installed `GSTheme` interface did not
declare `proposedVisibility:forMenu:`. Later files and linking were not
tested. This does not establish whether an import, a different GNUstep
version, or additional porting work is sufficient.

The GNUstep source revisions selected by Gershwin Developer are now pinned
as `contrib/` submodules, along with Eau and libdispatch. The selected GUI
source declares `proposedVisibility:forMenu:` in
`Headers/Additions/GNUstepGUI/GSTheme.h`. This addresses the observed header
version mismatch in the source comparison, but the new stack has not yet
been built or tested together on FoxynBSD. The dispatch errors and any later
build or runtime failures still need investigation.

An isolated QEMU build of the pinned `libdispatch` source was attempted with
clang19 and CMake, with tests disabled and no installation. Configuration
advanced into compilation, which failed in `src/shims/lock.h` with unknown
`dispatch_lock` and `dispatch_tid` types and undefined `DLOCK_*` constants.
The build stopped before the complete library or GNUstep stack could be
tested. CMake and clang were guest build tools; libdispatch was built from the
submodule revision, not a DPorts libdispatch package.

The wait primitive needs an explicit DragonFly implementation: the kernel's
`umtx_sleep` takes microseconds and may return early with `EWOULDBLOCK`, even
for an indefinite wait; `umtx_wakeup` uses count zero for wake-all. A port
must handle retries and deadlines rather than treating each kernel timeout as
the caller's final deadline. `tools/linux/tests/rt-umtx.c` exercises the
native mismatch, invalid timeout, timed wait and a shared-memory wakeup path;
it does not prove the child was asleep at wakeup and is not a libdispatch
concurrency test.

There is also a separate timer incompatibility: this FoxynBSD kernel's
`EVFILT_TIMER` interprets its data in milliseconds and has no
`NOTE_NSECONDS`, while the pinned libdispatch explicitly rejects DragonFly
without it. A port must implement and test timer conversion and semantics;
defining the flag without implementing its behavior would be incorrect.

An experimental, uninstalled build in a disposable QEMU guest reached a
working libdispatch smoke test after adapting the platform lock encoding,
`umtx` waits, thread IDs, CPU detection, endian helpers, list traversal and
timer units in a separate source copy. A group of 128 asynchronous jobs
completed and a 100 ms one-shot timer fired after 108 ms. The clean submodule
was not changed. This is preliminary evidence only: the prototype has not
passed comprehensive concurrency, cancellation, timeout, timer rearming or
hardware tests, and is not part of the system build or a distribution-ready
port. Its source changes and their licensing/provenance still need review.
GNUstep Make and libobjc2 were then built from their pinned submodule sources
and installed into a temporary guest prefix. libobjc2 used the experimental
BlocksRuntime and a local copy of robin-map v1.4.0. These builds are not yet
integrated into the base, and the GNUstep libraries and Eau still require
end-to-end tests.

The first libobjc2 build exported `__register_frame*` and
`__deregister_frame*` from its statically linked compiler support. GNUstep
Base's Objective-C configure probe compiled but aborted during process exit
in `__deregister_frame_info_bases`. Rebuilding libobjc2 with
`-Wl,--exclude-libs,ALL` removed those exported symbols. An initial result
incorrectly reported success using the outer `su` status; checking the
probe's status inside the user shell showed that it still aborts with 134.
Hiding these symbols is not a fix. The GNU gold linked library had two
`DT_INIT_ARRAY` entries, while a rebuild with LLVM lld had one. The same
Objective-C probe then exited successfully 20 times when checked inside the
unprivileged guest shell. This supports a linker-related diagnosis for the
tested binaries; it does not by itself validate all constructor and
exception-unwinding behavior.

With the lld-linked libobjc2, GNUstep Base also built from its pinned source
in the disposable guest. A small Foundation program constructed and compared
a string and exited successfully. `ldd` showed GNUstep Base, libobjc2,
BlocksRuntime and libdispatch loading from the experimental prefix; other
third-party dependencies still came from packages installed in the guest.
This is not yet a reproducible base build or a graphical session.

GNUstep GUI, the Cairo/X11 backend and Eau were subsequently built from the
pinned sources and installed in that temporary prefix. Under Xorg/scfb in
the same QEMU guest, an unprivileged GNUstep application loaded the `Eau`
theme and created a window visible to `xwininfo`. This checks the theme and
window startup with experimental libdispatch; it does not establish input,
logout, XLibre, a full Gershwin desktop, or reproducible packaging.
The pinned Gershwin WindowManager, with the separately recorded experimental
titlebar fix, and TextEdit were then built against this prefix. The existing
window-manager smoke check passed when both were launched with `-GSTheme Eau`:
the document window appeared, was reparented, remained viewable and both
processes stayed alive. The check does not itself confirm which theme was
loaded by each process; the separate application check above did confirm Eau.

Eau has not been installed, activated or tested as a theme on FoxynBSD. The
WindowManager titlebar fix for the base GNUstep theme does not modify the
separate Eau drawing path.

Upstream's root `LICENSE` contains LGPL 2.1; some source files explicitly
carry different terms, including BSD-2-Clause and dual BSD-2-Clause or
GPL-3.0-or-later notices. `GSDisplayServer+Eau.m` has an LGPL 2-or-later
notice. These terms and the provenance of the many image resources need a
file-level review before distribution. Preserve the applicable notices and
source obligations when packaging the theme as its own component. No theme
code or assets have been vendored or packaged in the FoxynBSD base.

## Built and active in the desktop image (2026-11-10)

With GNUstep built from the pinned sources (see
[desktop-gnustep.md](desktop-gnustep.md)), `tools/desktop/build-eau.sh`
builds Eau from `contrib/gershwin-eau-theme` (the revision and archive
checksum above; the archive's contents are identical to the submodule)
without changes, and installs `Eau.theme` in `/System/Library/Themes`.
The earlier failures (undeclared `dispatch_*`, missing
`proposedVisibility:forMenu:`) came from DPorts' GNUstep without
libdispatch; with the pinned GUI and libdispatch it compiled.

Eau is selected by Gershwin's system-wide GNUstep defaults:
`tools/desktop/install-gershwin-system.sh` installs
`contrib/gershwin-system`'s `Library/Preferences` (`GlobalDefaults`:
`GSTheme` = `Eau`, the Inter font, `GSBackHandlesWindowDecorations`, ...;
`fonts.conf`; `GlobalShortcuts.plist`) in `/System/Library/Preferences`,
next to the system `GNUstep.conf`, where GNUstep Base reads a
`GlobalDefaults` directory, and `contrib/gershwin-assets`' fonts and
desktop pictures in `/System/Library`. `foxyn-desktop` adds
`/usr/local/etc/fonts/conf.d/60-gershwin.conf`, which includes
Gershwin's `fonts.conf`, so that `/System/Library/Fonts` is used along
with the system's fonts (setting `FONTCONFIG_FILE` to it, as Gershwin's
`Gershwin.sh` does, would hide DPorts' fonts, such as xterm's DejaVu).

In QEMU (KVM, `-vga std`, kernel and world from `69d12dacac`), the
session's windows, Menu's bar, Workspace's icons and dock changed to Eau,
and the applications' menus moved into Menu's bar: with Workspace active
the bar showed Workspace, File, Edit, View, Go, Tools, Window and Help.
Before, without these defaults, each application drew its own vertical
GNUstep menu over the bar.

The assets' licenses differ per font: Inter is under the SIL Open Font
License 1.1, the URW and Nimbus Sans fonts under the AGPL 3 with a font
exception, Luxi under Bigelow & Holmes' license; the desktop picture's
terms are not recorded in the repository. Eau's own licenses are
described above. Review them before distributing an image; the image
built here is for local testing. Keyboard focus, contrast and the
coverage of every control have not been checked.

`build-eau.sh` applies `tools/desktop/patches/eau-searchfield-keydown.txt`:
Eau's NSSearchField category exchanged the implementation of `keyDown:`
that NSSearchField inherits, which swapped the superclass's
implementation for every view; a key sent to a button then made
`-[NSButton keyDown:]` and `-eau_keyDown:` call each other until the
stack overflowed. LoginWindow crashed that way (SIGSEGV; backtrace from
its core). The patch adds the method to NSSearchField first, as Eau's
NSButton swizzle already does; no crash was seen after it.

## GNUstep GUI's tests under Eau, 2026-11-11

GNUstep GUI's test suite in the desktop session (see `desktop-gnustep.md`)
fails these with Eau and passes them with GNUstep's own theme:
`NSBox` custom fill colour (`rendering.m`), `NSColorPicker`
`insertNewButtonImage:in:` (`backend.m`), the system font size for a zero
size (`systemfonts.m`), `NSMenuView` item area insets
(`menuItemAreaInsets.m`), a centred table header title (`headerCell.m`),
alternating row colours and text field bezels off/on by default
(`state.m`), and `NSPanel/behaviour.m`, which aborts. Some are deliberate
theme choices, the abort is not; not investigated yet.


## Read-only system colors, 2026-11-13

A root-owned Eau `ThemeColors.clr` is not editable by an ordinary user.
With the pinned GNUstep GUI, activating Eau raised
`NSColorListNotEditableException` while adding missing system colors. The
GUI patch copies a read-only theme color list into an editable in-memory
list before adding defaults; it does not change the installed file.

In an existing QEMU desktop, the focused test in
`tools/desktop/tests/eau-system-colors.m` compared the installed library
with a locally rebuilt library from GNUstep GUI revision
`8f804fd520c60800961e0bee072066f4bbadca94`. With the installed library,
35 theme colors were present, four expected defaults were missing, and
one color-list exception was logged. With the patched library, the 35
colors were preserved, all four defaults were present, and no color-list
exception was logged. The original `NSPanel/behaviour.m` test also passed
six checks in both runs; the exception appeared only in the unpatched run.
See [the captured test output](screenshots/issue-13/qemu-eau-system-colors.png).

These results do not establish that the separate full-suite NSPanel abort
above is fixed. A freshly built desktop image, theme switching, other
applications and physical hardware have not been tested with this patch.
