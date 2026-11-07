# Gershwin TextEdit on FoxynBSD

This is an exploratory build, not an installed desktop package. On a
disposable FoxynBSD QEMU UFS disk with Xorg using the `scfb` framebuffer
driver, Gershwin TextEdit commit
`f7dc768641c1a23609cfb53e6cf17c2ea7f0c898` built and ran as an
unprivileged user. The test used GNUstep Make 2.9.2 and DPorts
`llvm19-19.1.7_1`; GNUstep Make was configured to invoke `clang19`.
The FoxynBSD image used kernel `a0cc260ef3` (built November 6, 2026).

On a writable installation with pkg configured, install the build and
runtime dependencies as root:

```sh
pkg install gnustep gmake llvm19 dejavu
```

In a user's working directory, run the build script from this source tree:

```sh
/path/to/FoxynBSD/tools/desktop/build-textedit.sh
```

The script downloads the pinned source archive, checks its SHA-256 and
builds `TextEdit.app` in the current directory. It refuses to overwrite an
existing output; an alternate output path can be supplied as its argument.
From a working X session, run:

```sh
. /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
./TextEdit.app/TextEdit
```

The QEMU experiment started Xorg as root and
granted a temporary account local X access with `xhost`; it confirmed the
TextEdit process belonged to that account and the document window was
viewable. With a virtual USB keyboard, the test opened a plain-text file,
inserted text and selected Document > Save; the changed content was read
back from the file. That access grant was only for the isolated experiment,
not a recommended
authorization setup for a shared desktop.

The DPorts packages and their dependencies are not pinned by this recipe;
the test does not establish reproducible package builds, installation or
upgrades. Other editing operations, application integration, XLibre, a
complete Gershwin session, and physical hardware remain untested. The application
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
