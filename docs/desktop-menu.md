# Gershwin Menu

`tools/desktop/build-menu.sh` builds Gershwin's Menu, the global menu bar,
with the SoundBackend and NetworkBackend libraries it links with, from
`contrib/gershwin-components` at `08ca92248d35115c15d7060567ae2000a9222e10`
(tag 26.09). Like `build-gnustep.sh`, it downloads that revision's archive
and checks its SHA-256 (the archive's contents are identical to the
submodule). It installs the libraries in `/System/Library/Libraries` and
Menu in `/System/Library/CoreServices/Applications/Menu.app`, where
Gershwin's makefiles put them. `foxyn-desktop -g source` runs it as the
desktop user after `build-gnustep.sh`, and the session starts Menu after
the window manager.

Menu needs libdispatch, which `build-gnustep.sh` builds from
`contrib/libdispatch` before GNUstep Base, so Base uses it too (see
[desktop-libdispatch.md](desktop-libdispatch.md) for the DragonFly
patch). It also needs `dbus` and `gettext-runtime` from DPorts, and
`libexecinfo` from the base.

## FoxynBSD changes

Three patches to `Menu/`, from `tools/desktop/patches`:

- `menu-dragonfly-gnumakefile.txt`: Menu's `GNUmakefile` sets its compiler
  flags and libraries per system and has no DragonFly case; this one is
  FreeBSD's.
- `menu-dragonfly-kinfo.txt`: the process name lookup reads FreeBSD's
  `kinfo_proc` (`ki_comm`); DragonFly's is `<sys/kinfo.h>`, `kp_comm`.
- `menu-dragonfly-extra-poll.txt`: menu extras are found by polling, as on
  Linux, FreeBSD and OpenBSD, rather than with Apple's `O_EVTONLY`.

These came from the earlier laboratory builds (`*-experiment.txt`) and
should go upstream.

## Test, 2026-11-10

QEMU with KVM, kernel and world from `69d12dacac`, on a copy of the
`build.sh desktop` image. As `foxyn`, `build-gnustep.sh` (now with
libdispatch) and then `build-menu.sh` passed. `ldd` showed GNUstep Base
linked with `/System/Library/Libraries/libdispatch.so`, and Menu with
GNUstep, libdispatch and both backends from `/System/Library/Libraries`.
After `foxyn-desktop -y`, the session showed the menu bar across the top
of the screen with its extras (sound, clock, CPU, network, memory, help),
and the desktop-session test found Menu running as `foxyn`; `service
foxyn_desktop stop` ended the session.

Then from a new image on the Linux host: `build.sh rootfs`, then
`build.sh desktop` (about 18 minutes with the SJTU DPorts mirror) built
GNUstep, Menu, WindowManager and TextEdit, and `boot-test.sh --desktop`
passed on the next boot, with `Menu runs as foxyn` and the session
stopped cleanly.

Menu logged `no Desktop menu after 15 attempts`; Workspace, which is
expected to provide that menu, is not installed yet. In one of two stops, GNUstep's
`gdnc` daemon exited with SIGABRT and a core dump a few seconds after it
was sent SIGTERM; the cause was not investigated. The menu bar's items
and extras were not used, and there is no logout through it yet.
