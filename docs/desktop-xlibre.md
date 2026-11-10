# XLibre in the desktop image

`tools/desktop/build-xlibre.sh` builds the XLibre X server with the scfb
video and libinput input drivers from the revisions pinned by
`contrib/xlibre`, `contrib/xlibre-video-scfb` and
`contrib/xlibre-input-libinput`, into its own prefix,
`/System/Library/XLibre`. `foxyn-desktop -g source` (the default) runs it
as the desktop user, and the session's X server is then XLibre;
without it, the session falls back to DPorts' Xorg, which stays
installed.

| Component | Revision | Archive SHA-256 |
| --- | --- | --- |
| XLibre server 25.1.11 | `ec1f2d37daa1450d8452abb547de4546321d7bb9` | `acfd4b04cbc4a5b400bb3b3022fef78a40bb781aa27bf7ab124cd14233cc9871` |
| xf86-video-scfb | `df94d49909ec9c22e5044669f9d1363f4ed429a5` | `1261349c19f863012a3b1d7046165ae32b9032388c76eb9eb89d778948e4a916` |
| xf86-input-libinput | `4eb6691efeef4969a05b1d6b77d980943fb9760e` | `9559348e118ba53b4e7878d774ce2e22d67595f9fab9e6f7ea88d1de3b6f69f2` |

The archives' contents are identical to the submodules. The sources
build unmodified with DPorts' clang19; the server is configured without
GLX, glamor, DRI, udev, seatd, Xvfb, Xnest and Xephyr (no 3D on scfb),
logs to `/var/log/Xorg.0.log`, and uses DPorts' xkeyboard-config and
`xkbcomp`. The libinput driver needs DPorts' `evdev-proto` for
`<linux/input.h>`. Its configuration directory is
`/System/Library/XLibre/etc/X11/xorg.conf.d`, where `foxyn-desktop`
copies the scfb device section.

## Input without a hotplug backend

XLibre has no devd backend (FreeBSD's ports carry one as a patch to
xorg-server, and DPorts' Xorg has it), so it does not find input devices
by itself: it fell back to the `mouse` and `kbd` drivers, which are not
built. `foxyn-session` therefore writes
`xorg.conf.d/20-input.conf` before starting X, with automatic device
addition off and libinput devices for:

- the keyboard multiplexer's evdev node (`kbdmux0`), which carries every
  keyboard (by design also ones plugged in later; not tested), and
- the mouse nodes present at that moment (not `sysmouse`, which gets
  events only from `moused`).

It sets `kern.evdev.rcpt_mask` to 6: keyboards report through kbdmux,
mice through their own nodes. Opening a keyboard's own node as well made
the keyboard silent, probably because libinput's grab of the device
takes it away from kbdmux (not verified further). A mouse
plugged in during a session is not picked up until the next session.
XLibre also removed the `-noreset` option, so the session does not pass
it.

## Test, 2026-11-10

QEMU with KVM, `-vga std`, xHCI USB keyboard and mouse, kernel and world
from `69d12dacac`, on a copy of the `build.sh desktop` image. As the
desktop user, `build-xlibre.sh` built and installed the server and both
drivers (`XLibre X Server 1.25.1.11`). With the session started on
XLibre, the server used scfb at 1280x800, depth 32, and the libinput
devices; the Gershwin session (Workspace, Menu, WindowManager, TextEdit,
xterm) ran on it. Input was injected through QEMU (`sendkey`,
`mouse_move` on the monitor), that is through the guest's USB keyboard
and mouse, kbdmux, evdev and libinput, not through XTEST: `echo xlibre`
typed into the xterm ran and printed `xlibre`, and the pointer moved by
the injected distance. The control run with DPorts' Xorg on the same
image also took the keyboard and pointer.

Not tested: physical hardware, keyboards or mice plugged in during a
session, and other video drivers.
