# libdispatch for the Gershwin Menu

Gershwin's Menu and its Sound and Network backends include
`<dispatch/dispatch.h>`; DPorts has no libdispatch package.
The desktop image gets it from `tools/desktop/build-gnustep.sh`, which
builds the same revision with the same patch into `/System` before GNUstep
Base (see [desktop-gnustep.md](desktop-gnustep.md)). The standalone helper
below stages it elsewhere, for tests.
`tools/desktop/build-libdispatch.sh` builds the revision pinned in
`contrib/libdispatch` (`95f592ab637c4d7916fa05d4d80cbc1ec7d0b2b8`) from
the upstream archive, whose SHA-256
(`3c3d9496b9698ea5240f0139f59d604599e612972cec43196de932a2b3e69d79`) the
script checks; the archive's tree matched the submodule's. It applies
`tools/desktop/patches/libdispatch-dragonfly.txt` to the extracted copy,
never to the submodule, and stages the installation under the output
directory:

```sh
pkg install cmake ninja llvm19
tools/desktop/build-libdispatch.sh "$HOME/libdispatch-root"
# as root:
cp -R "$HOME/libdispatch-root/usr/local/." /usr/local/
```

The patch makes the waits use `umtx_sleep(2)` and `umtx_wakeup(2)` (the
`rt-umtx` boot test covers these system calls), converts the nanosecond
`EVFILT_TIMER` deadlines to the milliseconds DragonFly's kqueue takes, takes
thread ids from `lwp_gettid(2)`, and adds the `sys/endian.h`, CPU-count and
`LIST_FOREACH_SAFE` cases. It is the port used in the earlier laboratory
GNUstep builds, taken from that tree as a diff against the pinned revision.
The upstream files are Apache-2.0; the patch changes them and is distributed
under the same terms, with the upstream notices unchanged.

On 2026-11-09, on a disposable copy of `desktop.img` (kernel and world from
`69d12dacac`, DPorts `llvm19`, `cmake`, `ninja`), the script built and staged
the library as the unprivileged desktop user. `tools/desktop/tests/
dispatch-smoke.c` (a group of 128 blocks and a 100 ms timer) and
`dispatch-stress.c` (2,000 jobs and a timer), linked against the staged
library, both exited 0, with the timers firing after 102 ms and 169 ms. These
tests do not cover every queue type, sources other than timers, or process
exit with the library loaded; the laboratory saw an abort in a library
finalizer at exit until it relinked with lld. Nothing installs it by default
yet: Menu also needs a newer GNUstep Base than DPorts' 1.29, which lacks
`+[NSThread detachNewThreadWithBlock:]`.
