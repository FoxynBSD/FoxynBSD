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

Not done yet: no FoxynBSD service is managed by OpenRC, nothing starts a
runlevel at boot, and there is no migration or rollback between rc.d
and OpenRC. `foxyn-desktop` does not build OpenRC yet.
