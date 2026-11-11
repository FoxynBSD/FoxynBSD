# OpenRC on FoxynBSD

`tools/desktop/build-openrc.sh` builds OpenRC from `contrib/openrc`
(tag 0.62.6, `c3689317b5b028f96c1e4912ab5281f2719665e5`; the archive's
SHA-256 is in the script and its contents are identical to the
submodule) with DPorts' meson, ninja and clang19, as an unprivileged
user, and stages the installation under an output directory: `/sbin`
(`openrc`, `openrc-run`, `rc-service`, `rc-update`, `start-stop-daemon`,
`supervise-daemon`), `/bin/rc-status`, librc and libeinfo in
`/usr/local/lib`, and its configuration (`init.d`, `conf.d`,
`runlevels`, `rc.conf`) in `/usr/local/etc`. Root copies the staged tree
into place. OpenRC is meant to run next to DragonFly's init and rc.d,
not as PID 1, managing the desktop's own services in a runlevel of its
own.

## FoxynBSD changes

`tools/desktop/patches/openrc-dragonfly.txt`:

- `uname -s` prints `DragonFly`, while `meson.build` compared it with
  `Dragonfly`: no branch set `cc_os_flags`, and Meson stopped with
  `Unknown variable "cc_os_flags"` (the earlier laboratory result). The
  patch accepts `DragonFly` and uses FreeBSD's `-D_BSD_SOURCE`.
- DragonFly has no `MNT_UNION` mount flag; `mountinfo` lists it only
  where it is defined.

`build-openrc.sh` also passes an absolute `-Dsysconfdir`: OpenRC's
runlevel install script joins a relative one to `DESTDIR`, not to the
prefix, and failed.

## Test, 2026-11-10

QEMU with KVM, kernel and world from `69d12dacac`, on a copy of the
`build.sh desktop` image. As `foxyn`, the helper configured, built (193
targets) and staged OpenRC. Installed by root, with two test services in
a new `desktop` runlevel, `foxyn-beta` declaring `need foxyn-alpha`:

```
 * service foxyn-beta added to runlevel desktop
 * Caching service dependencies ...
 * Starting foxyn-alpha ...  [ ok ]
 * Starting foxyn-beta ...   [ ok ]
openrc=0
Runlevel: desktop
 foxyn-beta  [  started  ]
```

`rc-service foxyn-alpha restart` stopped `foxyn-beta`, then `foxyn-alpha`,
and started both again, in that order (the services' own log). Stopping
`foxyn-beta` by hand while that restart was still bringing it up failed
with `Call to flock failed: Resource temporarily unavailable`: OpenRC's
lock on the service, held by the restart.

## The desktop's services under OpenRC

`foxyn-desktop -o` (with GNUstep from source, not with `-l`) builds
OpenRC with `build-openrc.sh` as the desktop user and installs the
root-owned staged files (files only: the system's directories keep
their owners and modes). DragonFly's init and rc.d still boot the
system: the links OpenRC installs in its own `sysinit`, `boot`,
`default` and `nonetwork` runlevels (file systems, network, syslogd and
so on, which rc.d already runs) are removed. `foxyn-desktop` then adds:

- `/usr/local/etc/init.d/dbus`: DPorts' D-Bus system bus.
- `/usr/local/etc/init.d/foxyn-desktop`: the session that the rc.d
  service `foxyn_desktop` otherwise runs (`foxyn-session`: XLibre with a
  fresh cookie, then the user's `~/.xsession`), with `need dbus`; the
  user is in `/usr/local/etc/conf.d/foxyn-desktop`. Stopping it ends the
  session as Log Out does.
- the runlevel `desktop` with both, and an empty runlevel `off`;
- the rc.d service `foxyn_openrc` (`REQUIRE: LOGIN devd`), enabled in
  `rc.conf` instead of `foxyn_desktop`. At boot it mounts a tmpfs on
  OpenRC's state directory (`/usr/local/libexec/rc/init.d`, on disk
  otherwise: the state from before a reboot would say the services are
  still started), as OpenRC's own BSD `sysinit` does, and runs
  `openrc desktop`. `service foxyn_openrc stop` (also at shutdown) runs
  `openrc off`, which stops the services in reverse order.

Rollback: run `foxyn-desktop` again without `-o`; it sets
`foxyn_desktop_enable` and removes `foxyn_openrc_enable` from
`rc.conf` (by hand: `foxyn_openrc_enable=NO`,
`foxyn_desktop_enable=YES`). OpenRC stays installed but unused.

## Test of the desktop runlevel, 2026-11-10

Same QEMU setup, on the test VM above after removing the test services;
`boot-test.sh --desktop` gained `DESKTOP_OPENRC=1` (setup with `-o`), and
`desktop-session` checks OpenRC's runlevel when `foxyn_openrc` is
enabled.

- `foxyn-desktop -y -o` built and installed OpenRC and enabled
  `foxyn_openrc`.
- Boot: `Starting OpenRC runlevel desktop.`, `Caching service
  dependencies`, `Starting dbus ... [ ok ]`, `Starting foxyn-desktop ...
  [ ok ]`, then the console login; the tmpfs was mounted on the state
  directory.
- `service foxyn_openrc stop` stopped `foxyn-desktop`, then `dbus`;
  `start` started them in the other order, and `desktop-session wait`
  passed: XLibre, WindowManager, Menu, Workspace, `gershwin-session`,
  TextEdit and xterm as `foxyn`, a client without the cookie rejected.
- `desktop-session stop` (Log Out, then `service foxyn_openrc stop`):
  X, the user's processes and the system bus were gone.
- Recovery: with an X configuration that stops the server, the system
  booted to the console login; `rc-status` showed `dbus` started and
  `foxyn-desktop` crashed, and `foxyn-session.log` said `X did not
  start`. After removing the file, `rc-service foxyn-desktop restart`
  from the console started the desktop.
- Rollback: `foxyn-desktop -y` without `-o`, then a reboot: rc.d's
  `foxyn_desktop` ran the session (`desktop-session wait` passed), and
  OpenRC's services stayed stopped, with no system bus.

- End to end: `DESKTOP_OPENRC=1 build.sh desktop`, then `boot-test.sh
  --desktop`, passed: on the fresh image the boot started `dbus` and
  `foxyn-desktop` from the `desktop` runlevel, the session check passed,
  and Log Out then `service foxyn_openrc stop` left no X, no user
  processes and no system bus. (The first such run found that the
  empty runlevel directories were not installed; `foxyn-desktop` now
  creates the staged directories that are missing.)

Limits: after Log Out (or a session that ends by itself) OpenRC shows
`foxyn-desktop` as crashed, since its process exited without OpenRC
stopping it; the console remains and `rc-service foxyn-desktop restart`
starts a new session. LoginWindow (`-l`) still runs from rc.d only. Not
tested on physical hardware.

## Automated order and recovery test, 2026-11-11

`desktop-session openrc` (run by `DESKTOP_OPENRC=1 boot-test.sh
--desktop`) checks, after the session test:

- `service foxyn_openrc start` prints `Starting dbus` before `Starting
  foxyn-desktop`, and the session comes up (`desktop-session wait`);
  `service foxyn_openrc stop` prints `Stopping foxyn-desktop` before
  `Stopping dbus`.
- With an X configuration XLibre refuses (an unterminated section in
  `xorg.conf.d/99-broken.conf`), `service foxyn_openrc start` still
  starts the runlevel: `dbus` is started, `foxyn-desktop` is reported
  `crashed`, no X server runs, the console works (the test runs on it),
  and the new lines of `foxyn-session.log` say `X did not start`.
- Without the file, `rc-service foxyn-desktop restart` brings the
  desktop back (`desktop-session wait`).

Writing it found that `foxyn-session` waited the whole 30 s for X's
socket even when X had already exited, so for that long OpenRC still saw
the service as started; it now stops waiting when X exits.

By hand in QEMU on the `DESKTOP_OPENRC=1 build.sh desktop` image: with
the broken file, the screen showed the console login instead of the
desktop, and after a reboot with the file still there the system came up
the same way: the console login, `dbus` started, `foxyn-desktop`
crashed, `X did not start` in `foxyn-session.log`. After removing the
file, `rc-service foxyn-desktop restart` showed the desktop again.

The same run changed `foxyn-audio`: it tries recording only when
`/dev/sndstat` lists the default device as `play/rec`. On QEMU's
playback-only card, the duplex `jackd` sometimes outlived its 10 s probe
and left a capture source that delivered nothing (`pw-record` got 0 ms).
