# Gershwin TextEdit on FoxynBSD

This is an exploratory build, not an installed desktop package. On a
disposable FoxynBSD QEMU UFS disk with Xorg using the `scfb` framebuffer
driver, Gershwin TextEdit commit
`f7dc768641c1a23609cfb53e6cf17c2ea7f0c898` built and created X windows as
an unprivileged user. The test used GNUstep Make 2.9.2 and DPorts
`llvm19-19.1.7_1`; GNUstep Make was configured to invoke `clang19`.
The FoxynBSD image used kernel `a0cc260ef3` (built November 6, 2026).

On a writable installation with pkg configured, install the build and
runtime dependencies as root:

```sh
pkg install gnustep gmake git-lite llvm19 dejavu
```

In a user's working directory, obtain the exact source revision and build:

```sh
git clone https://github.com/gershwin-desktop/gershwin-textedit.git
cd gershwin-textedit
git checkout --detach f7dc768641c1a23609cfb53e6cf17c2ea7f0c898
. /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
gmake
```

From a working X session with the same GNUstep environment, run
`./TextEdit.app/TextEdit`. The QEMU experiment started Xorg as root and
granted a temporary account local X access with `xhost`; it confirmed the
TextEdit process belonged to that account and `xwininfo` listed its windows.
The window listing does not verify their map state or usability. That access
grant was only for the isolated experiment, not a recommended
authorization setup for a shared desktop.

The DPorts packages and their dependencies are not pinned by this recipe;
the test does not establish reproducible package builds, installation or
upgrades. Editing and saving, application integration, XLibre, a complete
Gershwin session, and physical hardware remain untested. The application
reported GNUstep style-offset and hyphenation warnings at startup.

## Source and license review

The source was fetched from the Gershwin TextEdit repository at the commit
above. Its root `LICENSE` is MIT, but that does not describe every file:
`STScriptingSupport.h` and `STScriptingSupport.m` contain StepTalk notices
under LGPL version 2 or later, and several files have no individual license
notice. Other files carry NeXT copyright and permission notices. No source
files were copied into the FoxynBSD tree or patched for this experiment.
ScanCode was not available; file-level provenance, asset licenses and
distribution obligations still need review before packaging. In particular,
do not label the entire application MIT based only on its root license.
