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
appears. It stops the processes it started and removes its temporary file.
It rejects a display that advertises another EWMH window manager; use a
throwaway display even if this check finds none. It does not validate window
management, input, logout, or a complete session.

In QEMU, WindowManager announced `_NET_SUPPORTING_WM_CHECK` and then died
with SIGSEGV when TextEdit opened; the regression check returned 1. A
control with Openbox (wrapped to ignore the WindowManager-specific `-dc`
option) and the same TextEdit returned `wm-check: ok`. A guest core dump
showed `objc_msgSend_fpret` called from GNUstep GUI's `cacheAttributes`,
`NSStringDrawing`, `GSTheme` titlebar drawing and WindowManager's
`renderGSThemeToWindow:frame:title:active:`. The faulting instruction
dereferenced a null dispatch-table pointer. This identifies the observed
failure path, not the root cause or a proven FoxynBSD-specific defect.

The upstream `WindowManager/LICENSE` contains an MIT license, while many
source files lack individual license headers. The XCB layer is bundled in
that source tree; the older README's separate XCBKit dependency description
is not sufficient to establish its license provenance. ScanCode was not
available and file and asset provenance remains to be reviewed before
redistribution. No upstream source was copied into this tree or patched in
this experiment.
