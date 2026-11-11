# The network in the desktop session

What the desktop user's programs get from the network, and how it is
checked (issue #13).

## What is there

- **The connection.** `dhcpcd(8)` from the base system configures the
  wired interface at boot: an address, the default route and the name
  server in `/etc/resolv.conf`. The desktop adds nothing to it; the
  session uses the system's connection.
- **Command-line programs.** `fetch(1)`, with LibreSSL for HTTPS.
- **GNUstep applications.** Foundation's `NSURLSession` (GNUstep Base,
  through libcurl) and GNUstep's own HTTP client behind `NSURL` and
  `-[NSData initWithContentsOfURL:]`. HTTPS goes through GnuTLS, which
  reads the system's certificate authorities through p11-kit:
  `foxyn-desktop` points p11-kit's trust module at `ca_root_nss`'s bundle,
  since DPorts' p11-kit is built without a path and trusted nothing.

## The check

`desktop-session net [URL]`, run by `boot-test.sh --desktop` after the
session is up (the `dnet-42` line), as the desktop user:

1. `vtnet0` has a lease: an address, the default route and a name server.
2. `fetch(1)` loads `http://10.0.2.100/`, which `boot-test.sh` has QEMU's
   user-mode network answer (`foxynbsd-net-42`), without the internet.
3. `tools/linux/tests/gnustep-fetch.m`, built in the guest, loads the same
   page with `NSURLSession` and with `NSData`, and must find
   `foxynbsd-net-42` in both replies.
4. With `NET_URL` (for example `NET_URL=https://www.dragonflybsd.org/`),
   it loads that URL too: a name to resolve and HTTPS with certificate
   checks. This needs the internet, so it is not done by default.

## Tested

QEMU (KVM), 2026-11-11, the desktop image of `build.sh desktop`:

```
desktop-session: vtnet0 10.0.2.15, gateway 10.0.2.2, nameserver 10.0.2.3
desktop-session: foxyn fetched http://10.0.2.100/
desktop-session: gnustep-fetch: NSURLSession: 16 bytes
desktop-session: gnustep-fetch: NSData: 16 bytes
desktop-session: gnustep-fetch: NSURLSession: 10738 bytes
desktop-session: gnustep-fetch: NSData: 10738 bytes
desktop-session: a GNUstep program of foxyn loaded http://10.0.2.100/ and https://www.dragonflybsd.org/
dnet-42: 0
```

## Not covered

- Only the wired interface that `dhcpcd` configures at boot. There is no
  graphical network configuration was tested: no Wi-Fi selection and no
  static addresses from the desktop.
- IPv6 was not checked.
- Physical network cards were not tested; QEMU's `virtio-net` only.
- A browser: Ladybird is being built from source for this (issue #13).
