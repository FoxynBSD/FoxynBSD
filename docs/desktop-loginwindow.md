# LoginWindow: graphical login

`foxyn-desktop -l` makes Gershwin's LoginWindow the display manager: the
`foxyn_loginwindow` rc.d service starts it at boot instead of the desktop
user's automatic session (`foxyn_desktop`, still the default, which the
automated boot test uses). LoginWindow authenticates through PAM's
`login` service, the one the console's login(1) uses, and runs Gershwin's
`/System/Library/Scripts/Gershwin.sh` as the user: the session
supervisor with Workspace, Menu and WindowManager. After Log Out it shows
the login window again.

LoginWindow is built by `tools/desktop/build-menu.sh` from
`contrib/gershwin-components` (`08ca92248d35115c15d7060567ae2000a9222e10`)
into `/System/Library/CoreServices/Applications/LoginWindow.app`; its own
install target, which also writes an rc.d script outside `/System`, is
not used. `install-gershwin-system.sh` installs `Gershwin.sh` from
`contrib/gershwin-system`. `Gershwin.sh` finds the supervised programs on
`$PATH` in `/System/Library/Tools`, where GNUstep Make links Workspace and
Menu and `foxyn-desktop` writes a WindowManager wrapper (`-dc`: no
compositing without GL).

## Display access

Upstream's LoginWindow (`LoginWindow_main.m`) starts
`/usr/local/bin/Xorg` with `-auth /var/run/xauth`, a file it never
writes. The server then had no working authorization: tested in QEMU,
the unprivileged account `nobody` could connect to the login screen's
display, so any local user could read what is typed into it, the
password included. The session's clients connected the same way.

On FoxynBSD, `/usr/local/libexec/foxyn-loginwindow` (the service's
program) starts the server itself before LoginWindow: XLibre when it is
installed (with the input configuration from `foxyn-xinput`), else
DPorts' Xorg, with a fresh MIT-MAGIC-COOKIE in `/var/run/xauth` (mode
0600, root's), and runs LoginWindow with that cookie; LoginWindow uses a
running `Xorg` instead of starting its own. `loginwindow-dragonfly.txt`
then makes LoginWindow grant the user who logs in access to the display
by user id (server-interpreted `localuser:<name>`) just before it starts
the session, and withdraw it when the session ends. The patch also puts
XLibre first in LoginWindow's other X server search path and adds
DragonFly's `kinfo_proc` field names (`kp_*`).

## Test, 2026-11-10

QEMU with KVM, `-vga std`, xHCI USB keyboard and mouse, kernel and world
from `69d12dacac`, on a copy of the `build.sh desktop` image, after
`foxyn-desktop -y -l` and a password for `foxyn`. Text was typed through
QEMU's USB keyboard (`sendkey`); `xdotool` with root's cookie only moved
the pointer into the password field and clicked Menu's items.

- Before the change: the login screen ran on DPorts' Xorg with no
  authorization, and `nobody` connected to it.
- After: the server was `/System/Library/XLibre/bin/Xorg :0 -nolisten
  tcp -auth /var/run/xauth vt9`; `nobody` was rejected before login,
  during the session and after logout.
- A wrong password (with the user name `foxynwrong`) showed
  "Authentication failed" without other detail.
- `foxyn` with the right password: the session started (`gershwin-session`,
  Workspace, Menu, WindowManager and their helpers as `foxyn`).
- Menu's Log Out ended it: the login window came back, and `foxyn`
  without a cookie could no longer connect to the display.
- Logging in again started the session again.

Limits: the Tab key did not move from the user name to the password
field; Workspace's `ddbd` was still running after Log Out; the session
took over 45 seconds to appear after the password was accepted; a
failing session, other users, the Shut Down and Restart buttons and
physical hardware were not tested. The automated boot test still uses
the automatic session.
