# Terminal applications on FoxynBSD

## Initial X terminal

On a disposable FoxynBSD QEMU UFS disk, DPorts `xterm-397_2` started as an
unprivileged user on Xorg with the `scfb` driver. Its shell reported that
standard input, output and error were connected to terminals, and the X
window was viewable. This was a QEMU smoke test with an X server started as
root and a temporary local-user access grant; it is not a production X
authorization setup or a test of XLibre, physical hardware or a complete
Gershwin session.

With pkg configured, install `xterm` and `xwininfo`. From a working X
session, run as the session user:

```sh
/path/to/FoxynBSD/tools/desktop/check-xterm.sh /usr/local/bin/xterm
```

The check starts a shell in xterm, verifies its three standard streams are
terminals, and confirms that its uniquely titled window is viewable. It
removes its temporary files and stops the process it started. It does not
exercise interactive input, scrollback, resizing, clipboard or terminal
escape sequences.

## Gershwin Terminal investigation

Gershwin Terminal revision `2c77b9c3f7c8a4b7a200830f5ba81b5f9085be06`
was downloaded from its upstream archive, SHA-256
`ad02595cb63402a7b66a155d9c07e986d4207b295a3fd33b83c386d7a366e1b3`.
On the same guest, its unmodified source was built as an unprivileged user
with GNUstep Make 2.9.2 and DPorts `llvm19-19.1.7_1`. The Preferences
bundle built, but the application build stopped in `TerminalView.m` because
it selected `<termio.h>`, which the guest does not provide. No later build
or runtime behavior has been tested, and this does not establish that a
header change alone is sufficient to port it.

The examined upstream files have GPL notices, including GPL version 2 for
`TerminalView.m` and GPL version 2 or later for `Controller.m`; the archive
includes a GPL version 2 license text. Keep this application as a separate
component and complete a file-level license and provenance review before
distribution. No upstream source was incorporated into the FoxynBSD tree
or modified in this experiment.
