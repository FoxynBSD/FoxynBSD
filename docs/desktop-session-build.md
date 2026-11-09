# Experimental Gershwin session supervisor build

`tools/desktop/build-session.sh` compiles only the upstream
`gershwin-session.m` supervisor on a FoxynBSD system with a compatible GNUstep
Base and Objective-C runtime. It does not install or start the desktop, and it
is not part of `buildworld` or the Linux cross-build. The separate WindowManager,
Workspace, Menu, X server, services, and their dependencies must already exist.

The helper requires the source file from Gershwin Components revision
`08ca92248d35115c15d7060567ae2000a9222e10` (SHA-256
`300947548e1e15fb384357dab07af44cb5f39b1efbf4f039026200ccd08ccd43`). The
source is BSD-2-Clause; see the upstream source's notice and the component
license before distribution. With the staged source submodule available:

```sh
. /path/to/GNUstep/Makefiles/GNUstep.sh
CC=clang19 tools/desktop/build-session.sh \
    contrib/gershwin-components/gershwin-session/gershwin-session.m \
    /path/to/writable/output/gershwin-session
```

`gnustep-config` supplies compiler and Base library flags; `CFLAGS` and
`LDFLAGS` provide additional toolchain options. The helper checks the source
hash, refuses an existing output and builds in a temporary directory outside
the source tree. It does not pin the compiler, GNUstep or transitive libraries;
the output is not a reproducible package. Do not use an untrusted compiler or
GNUstep environment.

On a disposable FoxynBSD QEMU guest with kernel `a0cc260ef3`, the helper built
the supervisor as a non-root user with the pre-existing laboratory GNUstep,
clang19, lld and `LDFLAGS='-fuse-ld=lld -B/tmp/crt-lab'`. A copy of that
binary supervised the laboratory WindowManager, Workspace and Menu on
XLibre/scfb, with an Xauthority cookie. The desktop appeared, but the Menu
reported that it could not load the desktop application menu during this run.
A driver then sent SIGTERM to the supervisor; its wrapper returned status 0.
This was not graphical logout, installation, a clean build from a new system,
a complete cleanup check, or a physical-hardware test. The component sources
and other laboratory patches remain separate; see issue #13.

Host-side safety checks can be run with
`python3 tools/desktop/tests/build-session-test.py` after initializing the
pinned source. They use a fake compiler and do not replace the target build.
