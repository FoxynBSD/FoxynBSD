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

`gershwin-session` does not notice when X goes away: it keeps restarting
Workspace and WindowManager, which abort without a display, every second
and with a core dump. `service foxyn_desktop stop` killed only X and so
left that loop running (the earlier stop tests passed because they ended
the session first). The rc script now ends the session as Log Out does,
with SIGTERM to the user's `gershwin-session`, before stopping X, and
`foxyn-session` sends it the same signal if X exits while the session
still runs. Tested in QEMU: after `service foxyn_desktop stop`, X and
every process of `foxyn` were gone within 20 seconds, with no new
crashes, and the supervisor logged `Shutdown signal received`.

The look comes from the Eau theme and Gershwin's system-wide defaults,
which `build-eau.sh` and `install-gershwin-system.sh` install; see
[desktop-eau.md](desktop-eau.md).

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

## Using the session by mouse and keyboard (automated), 2026-11-11

`desktop-session use` (run by `boot-test.sh --desktop`) uses the
automatic Gershwin session as the desktop user would, with xdotool,
clicks held 150 ms, and checks each result on disk:

- TextEdit: a click into the untitled document, "Hello from FoxynBSD"
  typed, Alt+S (GNUstep's Command key is Alt), the file name typed into
  the save panel's Name field and Return: the file in the user's home has
  that text.
- Workspace: a click on the desktop until Workspace is the active
  application (the active window in the same X client range as its
  "Desktop" window; GNUstep windows have no `_NET_WM_PID`), then
  Command-Shift-N (File > New Folder): `~/Desktop/New Folder` exists;
  a click on its icon, Command-Backspace (Move to Trash) and Return in the
  confirmation ("Move one item from: /home/foxyn/Desktop to the Trash?"):
  it is in `~/.Trash`.
- System Preferences (the dock's third icon) > Defaults: the setting
  `GSSavePanelShowProgress` set to YES with Set: `defaults read` in a new
  process returns it (the test removes it afterwards).

Choosing Workspace's menu items by their position in the menu bar was
not reliable (the menu bar shows the active application's menus, and the
click could land in the previous application's); the keyboard shortcuts
are. In QEMU, three runs in a row after restarting the session passed.
The same steps by hand, with screenshots, are in issue #13. Not covered:
the other System Preferences panes (Date and Time, Internet, Indexing; the
Modifier keys pane is disabled), drag and drop, and file operations other
than creating and trashing a folder.
