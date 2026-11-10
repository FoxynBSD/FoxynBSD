# Gershwin WindowManager on FoxynBSD

This is an investigation, not a usable desktop session. Gershwin
WindowManager revision `10b6797a3bfd391d559820232805f1a107fa9ec3`
compiled on a disposable FoxynBSD QEMU UFS disk, then crashed after
starting TextEdit on Xorg's `scfb` driver. The guest used kernel
`a0cc260ef3`, GNUstep Make 2.9.2, GNUstep GUI 0.31.1, libobjc2 and
DPorts `llvm19-19.1.7_1`. No physical hardware or XLibre was tested.

The test used this source archive, whose SHA-256 was
`9ad4d8061faed0a9df8da9dbe6140f810f81ba93347ad6e6333ad691996cfa40`:

```text
https://codeload.github.com/gershwin-desktop/gershwin-windowmanager/tar.gz/10b6797a3bfd391d559820232805f1a107fa9ec3
```

The existing GNUstep build environment described in
[desktop-textedit.md](desktop-textedit.md) was supplemented with DPorts
packages `xcb-util-cursor`, `xcb-util-wm`, `xcb-util` and `pkgconf`.
The archive was unpacked and `gmake` was run as the unprivileged user
with GNUstep's `GNUstep.sh` sourced. Dependencies and their transitive
versions are not pinned; this is not a reproducible package recipe.

For a focused regression check, start a disposable X display with no other
window manager, and run the following as its unprivileged session user after
sourcing GNUstep's environment. The executable paths refer to the builds
above and in [desktop-textedit.md](desktop-textedit.md):

```sh
tools/desktop/check-windowmanager.sh /path/to/WindowManager.app/WindowManager \
    /path/to/TextEdit.app/TextEdit
```

The check starts WindowManager with compositing disabled, opens a temporary
text document, and requires both processes to remain alive after the window
appears. It also checks that the document window is viewable and reparented.
It stops the processes it started and removes its temporary file.
It rejects a display that advertises another EWMH window manager; use a
throwaway display even if this check finds none. It does not validate all
window-management behavior, input, logout, or a complete session.

In QEMU, WindowManager announced `_NET_SUPPORTING_WM_CHECK` and then died
with SIGSEGV when TextEdit opened; the regression check returned 1. A
control with Openbox (wrapped to ignore the WindowManager-specific `-dc`
option) and the same TextEdit returned `wm-check: ok`. A guest core dump
showed `objc_msgSend_fpret` called from GNUstep GUI's `cacheAttributes`,
`NSStringDrawing`, `GSTheme` titlebar drawing and WindowManager's
`renderGSThemeToWindow:frame:title:active:`. The faulting instruction
dereferenced a null dispatch-table pointer. This identifies the observed
failure path, not a proven FoxynBSD-specific defect.

Further inspection of that core showed the private GNUstep titlebar method
using state 6 as an index into `titleTextAttributes`, which the installed
library's symbol table reports as a three-pointer array. The caller passes
`GSThemeSelectedState` for an inactive window; in the installed headers
that enum has value 6. The out-of-range read produced a pointer into
Objective-C metadata, which was then sent a message.

In a disposable guest only, an experiment mapped the active and inactive
cases to the key-window and normal-window slots (0 and 1) when calling the
base GSTheme method. It left the separate Eau-theme call unchanged. The
regression check passed with that experimental build and failed again after
a clean rebuild of the original. Two TextEdit windows were reparented; one
could be moved and activated through X requests while the manager remained
alive. This supports the diagnosis for the tested package versions, but is
not a complete session or theme test.

`tools/desktop/build-windowmanager.sh` downloads the pinned archive, verifies
its checksum, applies the focused `tools/desktop/patches/windowmanager-titlebar-state.txt` patch, and
builds a bundle in the current directory. It needs `gnustep gmake llvm19
xcb-util-cursor xcb-util-wm xcb-util pkgconf` and GNUstep Make configured
to invoke clang19, as in the experiment above. The patch changes
`WindowManager/URSThemeIntegration.m` only for the base GSTheme titlebar
method; the separate Eau method is unchanged. The upstream WindowManager
MIT notice is retained alongside the patch. Package versions and transitive
dependencies are not pinned; this is an experimental build, not a package.
On 2026-11-07, that script built the patched bundle as an unprivileged user
on a disposable QEMU disk. The existing `check-windowmanager.sh` passed with
the pinned TextEdit build: both processes stayed alive, and the document
window was reparented and viewable. This uses the base theme and Xorg/scfb;
it does not validate Eau, XLibre or a complete desktop session.

### Source and asset provenance (2026-11-07)

At the pinned revision, `WindowManager/LICENSE` supplies MIT terms for the
WindowManager directory and contains Alessandro Sangiuliano's 2020 copyright
notice. There is no separate LICENSE at the repository root. The candidate
fix concerns `WindowManager/URSThemeIntegration.m`, which has no individual
license notice; the directory license is evidence of the upstream project's
terms and the absence of a file header alone does not negate it. Git history
records contributions by several authors. An earlier version of this note
incorrectly named `GSThemeTitleBar.m` as the patched file.

The bundled `WindowManager/xcb` files came from the repository's former
`XCBKit` directory, moved in `a7abc2a29e2e1365cabab58cd1c2d125572ef116`.
Before that move, `XCBKit/LICENSE` contained MIT terms and a distinct 2019
copyright notice for Alessandro Sangiuliano. The move deleted that license
file. A distribution containing this code should retain the original 2019
notice and MIT permission text as well as the WindowManager notice; the
current 2020 notice alone is not the original XCBKit notice.

`WindowManager/WindowManager.png` is the only image or font asset found by
extension in the pinned tree and is included by the application build. Its
history says it was replaced with an X11 icon in
`d9c6fdeeddafeb01ec1792f42d1b508800b1c7ec` and resized in
`3e183e318128637c548bedc20245700c7b46c90b`, but identifies neither the
source nor its license. Trace it or replace it with a properly licensed
asset before distributing it.

The archive SHA-256 was checked against the hash above. A text search for
license, copyright and attribution notices across the tracked tree found
the notices described above and no separate license grant for the icon.
This is not a complete file-by-file or binary-asset audit; ScanCode was not
installed. The review used an AI assistant and has not had human legal review.
