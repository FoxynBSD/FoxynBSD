# PipeWire: the desktop's sound

`foxyn-desktop` (with GNUstep from source, the default) builds PipeWire
and its session manager WirePlumber with `tools/desktop/build-pipewire.sh`
and starts them with the desktop session.

| Component | Source | Installed in |
| --- | --- | --- |
| PipeWire 1.6.11 | `contrib/pipewire` (`4287f31510`) | `/System/Library/PipeWire` |
| WirePlumber 0.5.19 | `contrib/wireplumber` (`4ab992fa29`) | `/System/Library/PipeWire` |
| epoll-shim 0.0.20240608 | GitHub archive (SHA-256 in the script) | `/System/Library/PipeWire/lib` |
| JACK (jackd) | DPorts' `jackit` | `/usr/local` |

The helper fetches GitLab's archives of the two tags (identical to the
submodules, checked by SHA-256), builds as the desktop user while
`/System` is writable by that user, with DPorts' meson, ninja, cmake,
clang19, glib, lua54, libinotify, libsndfile, readline and dbus, and
links everything with a runpath to `/System/Library/PipeWire/lib`.

## How the sound reaches the card

PipeWire has no OSS backend, and its ALSA plugin is Linux's. FoxynBSD's
sound drivers (`snd_hda`, loaded by devd for an HDA controller) offer
OSS's `/dev/dsp`, which JACK's `jackd` uses. So:

```
application -> PipeWire (JACK Sink: module-jack-tunnel) -> jackd -d oss -> /dev/dsp -> snd_hda
```

`/System/Library/PipeWire/etc/pipewire/pipewire.conf.d/10-foxyn.conf`
loads the JACK tunnel as a sink and starts WirePlumber.
`/usr/local/libexec/foxyn-audio`, started by the session's `.xsession`
as the desktop user, starts `jackd` on `/dev/dsp` (48 kHz, playback
only), then `pipewire`; it does nothing without a sound card. Logs go to
the user's `XDG_RUNTIME_DIR`, `/var/run/user/<uid>`, which
`foxyn-session` now creates (mode 0700) for the session and removes
after it, when it also ends `jackd`, `pipewire` and `wireplumber`.

## Why epoll-shim is built here

PipeWire needs epoll-shim on the BSDs. DPorts' `libepoll-shim` was built
without `eventfd(2)` (FoxynBSD's is native, `54de09b38c`) and emulates
it with kqueue descriptors, which `SCM_RIGHTS` refuses to pass, so
PipeWire's clients were cut off (issue #13). Built on FoxynBSD, epoll-shim
finds the native `eventfd` (the helper checks this) and leaves it to
libc. It is installed with PipeWire, so DPorts' copy, which libinput
uses, stays.

## FoxynBSD changes

`tools/desktop/patches/pipewire-dragonfly.txt`:

- Meson knew FreeBSD and MidnightBSD only: DragonFly gets the same
  dependencies (epoll-shim, libinotify, OpenSSL).
- Peer credentials through `LOCAL_PEERCRED`'s `xucred`, whose first group
  is the effective group (DragonFly's has no `cr_gid`) and which has no
  pid; thread ids from `lwp_gettid()`; the program name from
  `getprogname()`; `pthread_np.h`, `sys/endian.h`, `sys/sysctl.h`.
- No `memfd_create(2)` nor `SHM_ANON`: memory comes from files in
  `/dev/shm`, PipeWire's generic path.
- Missing on DragonFly: `ECHRNG` and `EBADFD` (mapped to `ERANGE` and
  `EBADF`), the Linux-only resource limits in PipeWire's table, `malloc.h`
  (its glibc functions are already optional), `SCHED_RESET_ON_FORK`
  (0, as PipeWire's RT module already allows), `SO_PASSCRED` (the RTP PTP
  management socket is not created), `O_PATH`, `MAP_LOCKED` and
  `CLOCK_MONOTONIC_RAW`.
- `<netinet/in.h>` in `network-utils.h`, and `<limits.h>` instead of
  `<linux/limits.h>` in a SPA benchmark that is built even without tests.
- The JACK tunnel looks for `libjack.so.0` in `/usr/local/lib` too, where
  DPorts installs it.

`tools/desktop/patches/wireplumber-dragonfly.txt`: `gettid()` is
`lwp_gettid()`.

`build-pipewire.sh` gives WirePlumber a `python3` (DPorts installs only
`python3.11`, Meson's own interpreter) and the compiler `/usr/local`'s
headers and libraries.

`build-workspace.sh` now hides `sys/inotify.h` from Workspace's
configure: with DPorts' `libinotify` installed (PipeWire uses it),
configure also built Workspace's inotify file system watcher, which
failed to link (`inotify_rm_watch`), and its `--without-inotify` is
overridden by its own header check. Workspace keeps its kqueue watcher.

## Tests, 2026-11-10

QEMU with KVM, kernel and world from `69d12dacac`. `qemu.sh` takes
`AUDIO=host` (an Intel HDA card played through the host) or
`AUDIO=<file>.wav` (what the guest plays, recorded); `boot-test.sh` with
`AUDIO_CHECK=1` gives the machine such a card and reports what reached
it (`audio-wav:`).

- Test VM, by hand: as `foxyn`, `jackd` on `/dev/dsp`, PipeWire 1.6.11
  with the JACK tunnel and WirePlumber 0.5.19; `wpctl status` showed
  `JACK Sink` as the default sink, and `pw-play` played a 4 s 440 Hz
  tone; QEMU's recording had 3.9 s of sound at about 440 Hz.
- Test VM, the session: after `foxyn-desktop` built PipeWire, the
  session started `jackd`, `pipewire` and `wireplumber` as `foxyn`;
  `desktop-session audio` played the tone through the default sink
  (`JACK Sink`); logging out ended them and removed
  `/var/run/user/1001`.
- End to end: `AUDIO_CHECK=1 build.sh desktop`, then
  `AUDIO_CHECK=1 boot-test.sh --desktop`:

  ```
  desktop-session: jackd runs as foxyn
  desktop-session: pipewire runs as foxyn
  desktop-session: wireplumber runs as foxyn
  dsession-42: 0
  desktop-session: default sink: JACK Sink
  desktop-session: foxyn played a 440 Hz tone through PipeWire
  daudio-42: 0
  audio-wav: 4.1 s of sound, 440 Hz
  ```

  In the first boot of the image, after Log Out TextEdit (not part of the
  sound) was still running 30 seconds later, and the stop check failed;
  the second boot of the same image passed it (`dstop-42: 0`). Not
  resolved.

## Limits

- Playback only: `jackd` runs without capture channels, so recording,
  PipeWire sources and duplex use are not set up; volume control through
  `wpctl` was not verified on the card.
- One sound card, the first OSS device, at 48 kHz; no hot plug, no
  Bluetooth, no ALSA or PulseAudio compatibility layers (`pipewire-pulse`
  is not configured), no realtime scheduling (no RTKit; `jackd` and
  PipeWire run without it).
- The sound starts with the automatic session's `.xsession`: tested with
  the rc.d service `foxyn_desktop`; OpenRC's `foxyn-desktop` runs the same
  `foxyn-session` but was not tested with sound. A session started by
  LoginWindow (`Gershwin.sh`) does not start it yet.
- PipeWire's error messages print `m` where they mean the error's text:
  DragonFly's `printf` has no glibc `%m`.
- Only the HDA card in QEMU was tested; no physical hardware.
