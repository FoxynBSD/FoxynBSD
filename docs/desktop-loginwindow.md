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

## Automated test and fixes, 2026-11-10 (later)

`desktop-session login` (run by `LOGIN_CHECK=1 boot-test.sh --desktop`)
drives the login window with `xdotool`, which `foxyn-desktop` now
installs: it starts `foxyn_loginwindow` with a temporary password,
checks that `nobody` cannot use the display, logs in, logs out, logs in
again, tries a wrong password, then stops the service (which now also
stops the X server it started) and removes the password. Writing it
found:

- Eau crashed LoginWindow (SIGSEGV, stack overflow) on Return:
  `-[NSSearchField(EauTheme) eau:keyDown:]` and `-[NSButton keyDown:]`
  called each other until the stack ran out. Eau exchanged the
  implementation of `keyDown:` that NSSearchField inherits, which swapped
  the superclass's for every view. `eau-searchfield-keydown.txt` adds the
  method to NSSearchField first, as Eau's own NSButton swizzle does;
  `build-eau.sh` applies it. No crash was seen after it.
- The login window has no window manager and gets no keyboard focus by
  itself: until it is given focus, text typed into a field is not drawn
  and a triple click does not select the old text, so new text is added
  to it (a failed password stayed in the field). The test focuses the
  window first.
- `loginwindow-dragonfly.txt` adds Workspace's `ddbd` and `fswatcher`
  to the daemons LoginWindow ends at logout, like `gpbs` and `gdnc`.
  Not verified yet: the test VM still had these daemons, and D-Bus
  daemons, left from the sessions that ended abnormally.

Not resolved: in the automated runs, the first login of a freshly
started LoginWindow did not reliably start a session. In some runs the
session started and its supervisor received a shutdown signal about a
second later; in another, the click on Log In did not start an
authentication at all (no `fork` in a ktrace of LoginWindow). Logging
out and in again in the same run worked every time, and logging in by
hand through QEMU's keyboard worked. The step is therefore opt-in
(`LOGIN_CHECK=1`).

Limits: the Tab key did not move from the user name to the password
field; the session
took over 45 seconds to appear after the password was accepted; a
failing session, other users, the Shut Down and Restart buttons and
physical hardware were not tested. The automated boot test still uses
the automatic session.

## Session cleanup, PAM session and the first login, 2026-11-10 (night)

Found while adding sound to LoginWindow sessions (see
`desktop-pipewire.md`), in QEMU on the `build.sh desktop` image with the
patched LoginWindow rebuilt in the VM:

- **No PAM session.** LoginWindow authenticated through PAM but never
  called `pam_open_session` for a password login (only
  `pam_close_session`), so no session module ran. It now opens the
  session as root before starting the user's session; with `pam_xdg` in
  `/etc/pam.d/login` the session gets `XDG_RUNTIME_DIR`.
- **Logout without cleanup.** Once LoginWindow has run an NSTask,
  GNUstep's SIGCHLD handler reaps every child with `waitpid(-1)`, the
  session too. `monitorSession` then got `ECHILD` and showed the login
  window again without ending the user's processes, closing the PAM
  session or withdrawing the user's access to the display: after Log Out,
  `foxyn` could still connect to the display and its daemons kept
  running. The patch treats `ECHILD` as the end of the session.
- **Sound daemons.** `jackd`, `pipewire` and `wireplumber` run in
  sessions of their own and are now ended at logout with LoginWindow's
  other detached daemons.
- **Alert at every start.** `foxyn-loginwindow` set `umask 077` for the X
  cookie, and LoginWindow inherited it: the preferences it writes after a
  login (`/Local/Library/Preferences/LoginWindow.plist`) were mode 0600,
  and LoginWindow refuses such a file with a modal "Autologin File
  Permission Error" at its next start, i.e. after every reboot. The umask
  now applies to the cookie only.
- **Stopping the service.** `service foxyn_loginwindow stop` during a
  session left the user's `gershwin-session` running, which restarted the
  applications after X ended. The service now ends the session first, as
  Log Out does, and gives LoginWindow time to clean up.
- **The first login.** After the test's `xdotool` typing, the login
  window of a freshly started LoginWindow is no longer GNUstep's key
  window, and GNUstep spends a click on a button of a window that is not
  key on making it key (`acceptsFirstMouse:` is NO for buttons): the click
  on Log In did nothing (0 of 2 tries). With a click on the window's
  background first, 2 of 2 first logins started the session; after a
  logout LoginWindow activates itself again, which is why later logins
  always worked. The test now clicks the window first. Whether a person
  using a real mouse hits this was not tested (earlier logins by hand
  through QEMU's keyboard worked). The earlier failure mode, a session
  ended about two seconds after it started, was not seen after these
  changes and is not explained.

With these changes `desktop-session login` passed in the VM: the first
login started the session, which had `/var/run/xdg/foxyn` and sound;
logging out ended the user's processes, removed the directory and
withdrew display access; a second login and a wrong password behaved as
before.

## Wrong password, 2026-11-11

A wrong password showed a modal "Authentication Error" alert. LoginWindow
treats a failure whose text contains "Authentication failure",
Linux-PAM's text for `PAM_AUTH_ERR`, as a wrong password and only shakes
the window; OpenPAM's text is "authentication error". The alert blocked
LoginWindow until it was dismissed, so the right password typed next did
nothing (the earlier "a login typed right after a failed one did not
start a session"). `LoginWindowPAM.m` now reports `PAM_AUTH_ERR`,
`PAM_USER_UNKNOWN` and `PAM_MAXTRIES` with the same text, so a wrong
password and an unknown user look alike: "Authentication failed" in the
window, the password field cleared, no alert. Other failures (account
management, for example) still show their alert.

`desktop-session login` now checks that a wrong password shows no alert
(a mapped, unnamed 500x150 LoginWindow window, Eau's alert panel) and that
the right password works right after it. In QEMU on the `build.sh
desktop` image, with the old LoginWindow both checks failed; with the
patched one built in the VM both passed. The unknown user `nosuchuser`
gave the same window as a wrong password.

