# Gershwin session: Workspace, System Preferences and the supervisor

With GNUstep built from source (`foxyn-desktop -g source`, the default),
the desktop image runs Gershwin's own session, as Gershwin's
`Library/Scripts/Gershwin.sh` does: the session supervisor
`gershwin-session` runs Workspace, Menu and WindowManager, restarts any of
them that exits, and ends the session when it gets SIGTERM, which is what
Menu's System > Log Out sends it.

| Component | Helper | Source | Installed in |
| --- | --- | --- | --- |
| System Preferences and the PreferencePanes framework | `build-systempreferences.sh` | `contrib/gershwin-systempreferences` `d5809a837f2f094ab22624ca5c0b1f010b7348e9` (26.09) | `/System/Applications`, `/System/Library/Frameworks` |
| Workspace (file manager, desktop, dock) | `build-workspace.sh` | `contrib/gershwin-workspace` `817491d7dc7de207c3e71938b69f0f6d56000a81` (26.09) | `/System/Applications/Workspace.app` |
| `gershwin-session` | `build-menu.sh` | `contrib/gershwin-components` `08ca92248d35115c15d7060567ae2000a9222e10` (26.09) | `/System/Library/Tools` |

Each helper downloads the revision's archive, checks its SHA-256 (the
archives' contents are identical to the submodules) and installs in the
System domain as the desktop user while `foxyn-desktop` lets that user
write `/System`. System Preferences is built before Workspace, whose
metadata preferences panel needs the PreferencePanes framework. Workspace
needs SQLite from DPorts (GWMetadata) and dbus.

The supervisor finds the programs it supervises on `$PATH`.
`foxyn-desktop` writes three wrappers in `/System/Library/Tools/Gershwin`
(WindowManager with `-dc`, as there is no GL here; Workspace; Menu), and
`~/.xsession` puts that directory first, starts a D-Bus session bus with
`dbus-launch --exit-with-x11` for Menu, and then executes
`gershwin-session Workspace Menu WindowManager`. TextEdit and an xterm are
started next to it. When the supervisor exits, the session ends: X stops,
`gdnc`, `gpbs`, `ddbd` and `fswatcher` are stopped, and the console login
remains.

## FoxynBSD changes

- `workspace-dragonfly.txt` (Workspace): extended attributes through
  `<sys/extattr.h>` as on FreeBSD, without `extattr_list_file`, which
  DragonFly's libc lacks; `kinfo_proc` from `<sys/user.h>`; and the process
  and block device code for DragonFly.
- Workspace's video thumbnailer needs an AVFoundation library, which is not
  built: `build-workspace.sh` writes the makefile's optional
  `GNUmakefile.local` to build only the image thumbnailer.
- GNUstep Base gets `gnustep-base-connection-null.patch` (committed earlier
  with `tools/desktop/tests/nsconnection-null.m`): without it, Workspace
  crashed at start in `+[NSConnection
  connectionWithRegisteredName:host:usingNameServer:]` (a nil connection's
  `_remoteName`, page fault at address `0xa0`) when connecting to `ddbd`,
  and the supervisor restarted it every few seconds; 43 crashes in one
  test session.
- libdispatch's CoreFoundation interface (`DISPATCH_COCOA_COMPAT`), which
  GNUstep's run loop uses to drain the main queue and System Preferences
  calls directly, was enabled for Linux, FreeBSD and OpenBSD only; the
  libdispatch patch enables it on DragonFly, with the generic Unix pipe
  handle. System Preferences did not link without it.

## Test, 2026-11-10

QEMU with KVM, `-vga std`, kernel and world from `69d12dacac`, on a copy of
the `build.sh desktop` image. With `/System` empty, `build-gnustep.sh`,
`build-menu.sh`, `build-systempreferences.sh` and `build-workspace.sh`
built and installed everything as `foxyn`. After `foxyn-desktop -y`, the
session ran `gershwin-session`, Workspace, Menu and WindowManager as
`foxyn`; the screen showed Workspace's desktop with the System Disk icon,
its dock (⌘, trash) and Menu's bar. With `xdotool` (installed only for the
test), a click on Menu's ⌘ opened the System menu, Log Out... opened the
confirmation, and its Log Out button ended the session: X exited within
2 seconds, no process of `foxyn` remained, `foxyn_desktop` was no longer
running, and the console showed `login:`. The supervisor logged that Menu
did not exit after SIGTERM and was killed. Workspace did not crash during
that session.

Then from a new image on the Linux host: `build.sh rootfs`, then
`build.sh desktop` with the SJTU DPorts mirror built GNUstep, Menu and
the supervisor, System Preferences, Workspace, WindowManager and TextEdit
(setup about 11 minutes), and `boot-test.sh --desktop` passed on the next
boot: `gershwin-session`, Workspace, Menu, WindowManager, TextEdit and
xterm ran as `foxyn`, and the test's logout (SIGTERM to the supervisor,
the command Menu's Log Out runs) stopped X, the service and every process
of `foxyn`. Workspace did not crash.

Earlier attempts of that run stopped during the package installation: the
host's file system was full, and QEMU paused the VM (`info status`:
`paused (io-error)`). Keep several GB free for `build.sh desktop`.

Not tested: file management in Workspace, the System Preferences panes,
the dock's items, a second login, XLibre and physical hardware.
