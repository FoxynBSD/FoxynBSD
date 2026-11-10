#!/bin/sh
# The desktop that foxyn-desktop(8) installed (boot-test.sh --desktop).
#	wait	wait for the session that rc.d (foxyn_desktop) or OpenRC
#		(foxyn_openrc, foxyn-desktop -o) started at boot: X, a window
#		manager (WindowManager or twm), an xterm and the GNUstep
#		application's window (TextEdit's with GNUstep from source in
#		/System, else Sudoku's) and Gershwin's Menu when installed,
#		all clients as the desktop user
#	stop	end the session: as Menu's Log Out does, SIGTERM to the
#		user's gershwin-session when it runs, else `service
#		foxyn_desktop stop`; X, the service and the user's
#		processes must be gone; with OpenRC, then `service
#		foxyn_openrc stop`, which must stop the system bus too
#	login	(after stop) Gershwin's LoginWindow, when installed: start
#		foxyn_loginwindow with a test password for the user; check
#		that another account cannot use the display, that a wrong
#		password is refused, that the right one starts the session,
#		that logging out returns to the login window and takes the
#		user's access away, and a second login; then stop the
#		service and remove the password
ok=1
fail() { echo "desktop-session: FAIL $*"; ok=0; }
user=$(sed -n 's/^foxyn_desktop_user="\(.*\)"$/\1/p' /etc/rc.conf | tail -n 1)
[ -n "$user" ] || { echo "desktop-session: FAIL foxyn_desktop_user is not set"; exit 1; }
uid=$(id -u "$user") || exit 1
svc=foxyn_desktop
grep -q '^foxyn_openrc_enable="YES"' /etc/rc.conf && svc=foxyn_openrc
export DISPLAY=:0 XAUTHORITY=
if [ -x /System/Applications/TextEdit.app/TextEdit ]; then
	app=TextEdit appwin=UNTITLED
else
	app=Sudoku appwin=Sudoku
fi
case ${1:-} in
wait)
	i=0
	while [ "$i" -lt 90 ]; do
		XAUTHORITY=$(cat /var/run/foxyn-session.xauthority 2>/dev/null)
		xwininfo -root -tree 2>/dev/null | grep -q "\"$appwin\"" &&
		    xwininfo -root -tree | grep -q '"Terminal"' && break
		sleep 2; i=$((i + 1))
	done
	service $svc status | sed 's/^/desktop-session: /'
	[ "$svc" = foxyn_openrc ] &&
	    rc-status desktop | sed 's/^/desktop-session: openrc: /'
	echo "desktop-session: X $(sed -n 's/.*scfb(0): Using: \(.*\)/\1/p' /var/log/Xorg.0.log | head -n 1 | tr -s ' ')"
	echo "desktop-session: server $(sed -n 's/^\(XLibre X Server [0-9.]*\).*/\1/p;s/^\(X.Org X Server [0-9.]*\).*/\1/p' /var/log/Xorg.0.log | head -n 1)"
	if pgrep -u "$uid" -x WindowManager >/dev/null; then
		echo "desktop-session: Gershwin WindowManager runs as $user"
	elif pgrep -u "$uid" -x twm >/dev/null; then
		echo "desktop-session: twm runs as $user"
	else
		fail "no window manager runs as $user"
	fi
	procs="xterm $app"
	# Gershwin's menu bar, which foxyn-desktop builds with GNUstep.
	[ -x /System/Library/CoreServices/Applications/Menu.app/Menu ] &&
	    procs="$procs Menu"
	# Gershwin's session: its supervisor and Workspace.
	[ -x /System/Library/Tools/gershwin-session ] && [ -x /System/Library/Tools/Workspace ] &&
	    procs="$procs gershwin-session Workspace"
	for p in $procs; do
		if pgrep -u "$uid" -x "$p" >/dev/null; then
			echo "desktop-session: $p runs as $user"
		else
			fail "$p is not running as $user"
		fi
	done
	pgrep -u 0 -x Xorg >/dev/null || fail "Xorg is not running"
	for w in Terminal "$appwin"; do
		xwininfo -root -tree | grep -q "\"$w\"" &&
		    echo "desktop-session: window \"$w\" is mapped" ||
		    fail "no \"$w\" window"
	done
	# The cookie is the user's: another account cannot connect.
	if su -m nobody -c 'XAUTHORITY=/dev/null xwininfo -root' >/dev/null 2>&1; then
		fail "X accepted a client without the cookie"
	else
		echo "desktop-session: X rejected a client without the cookie"
	fi
	tail -n 10 /var/log/foxyn-session.log | sed 's/^/desktop-session: log: /'
	;;
stop)
	sup=$(pgrep -u "$uid" -x gershwin-session)
	if [ -n "$sup" ]; then
		echo "desktop-session: logging out (SIGTERM to gershwin-session $sup)"
		kill -TERM $sup
	else
		service $svc stop | sed 's/^/desktop-session: /'
	fi
	i=0
	while { pgrep -x Xorg || pgrep -u "$uid" ||
	    service $svc status; } >/dev/null && [ "$i" -lt 30 ]; do
		sleep 1; i=$((i + 1))
	done
	pgrep -x Xorg >/dev/null && fail "Xorg still runs"
	pgrep -u "$uid" >/dev/null && fail "processes of $user remain: $(pgrep -u "$uid" -l | tr '\n' ' ')"
	service $svc status >/dev/null && fail "$svc still runs"
	if [ "$svc" = foxyn_openrc ]; then
		service foxyn_openrc stop 2>&1 | sed 's/^/desktop-session: /'
		pgrep -f 'dbus-daemon --system' >/dev/null &&
		    fail "the system bus still runs"
		rc-status desktop | sed 's/^/desktop-session: openrc: /'
	fi
	[ "$ok" = 1 ] && echo "desktop-session: X and the session stopped"
	;;
login)
	lw=/System/Library/CoreServices/Applications/LoginWindow.app/LoginWindow
	if [ ! -x "$lw" ] || [ ! -x /usr/local/etc/rc.d/foxyn_loginwindow ]; then
		echo "desktop-session: no LoginWindow installed"
		exit 0
	fi
	command -v xdotool >/dev/null || { echo "desktop-session: FAIL no xdotool"; exit 1; }
	pass=foxyn-test-$$
	echo "$pass" | pw usermod "$user" -h 0
	service foxyn_loginwindow onestart >/dev/null
	export XAUTHORITY=/var/run/xauth
	# denied: whether an account without a cookie can use the display
	denied() {
		! su -m "$1" -c 'env DISPLAY=:0 XAUTHORITY=/dev/null xwininfo -root' \
		    >/dev/null 2>&1
	}
	# greeter: wait for the login window (60 s)
	greeter() {
		i=0
		while [ "$i" -lt 30 ]; do
			xwininfo -root -tree 2>/dev/null |
			    grep -q '("LoginWindow" "LoginWindow")' && return 0
			sleep 2; i=$((i + 1))
		done
		return 1
	}
	# session: wait for the user's supervisor and Workspace (180 s)
	session() {
		i=0
		while [ "$i" -lt 90 ]; do
			pgrep -u "$uid" -x gershwin-session >/dev/null &&
			    pgrep -u "$uid" -x Workspace >/dev/null && return 0
			sleep 2; i=$((i + 1))
		done
		return 1
	}
	# type_login NAME PASSWORD: fill the fields (at 1280x800) and log in
	type_login() {
		# Without a window manager the login window gets no keyboard
		# focus by itself: give it, else a triple click does not select
		# a field's old text and the typing is added to it.
		xdotool search --name '^'"$(hostname -s)"'$' windowfocus --sync
		sleep 1
		xdotool mousemove 695 270 click --repeat 3 --delay 100 1
		xdotool type --delay 50 "$1"
		# (a failed attempt leaves the password in the field)
		xdotool mousemove 695 300 click --repeat 3 --delay 100 1
		xdotool type --delay 50 "$2"
		# The Log In button (Return started a second login, which ended
		# the first session, in some runs).
		xdotool mousemove 765 503 click 1
	}
	# logout: as Menu's Log Out, then wait for the login window again
	logout() {
		pkill -TERM -u "$uid" -x gershwin-session
		i=0
		while pgrep -u "$uid" -x 'gershwin-session|Workspace|Menu' >/dev/null &&
		    [ "$i" -lt 30 ]; do
			sleep 1; i=$((i + 1))
		done
		greeter
	}
	if greeter; then
		echo "desktop-session: LoginWindow shows the login window"
	else
		fail "no login window"
	fi
	denied nobody && echo "desktop-session: the login window's display rejects nobody" ||
	    fail "nobody can use the login window's display"
	type_login "$user" "$pass"
	if session; then
		echo "desktop-session: the password starts the session as $user"
	else
		fail "no session after logging in"
	fi
	denied nobody && echo "desktop-session: the session's display rejects nobody" ||
	    fail "nobody can use the session's display"
	if logout; then
		echo "desktop-session: logging out shows the login window again"
	else
		fail "no login window after logging out"
	fi
	denied "$user" && echo "desktop-session: after logging out $user cannot use the display" ||
	    fail "$user can still use the display"
	pgrep -u "$uid" >/dev/null &&
	    echo "desktop-session: processes of $user remain: $(pgrep -u "$uid" -l | tr '\n' ' ')"
	type_login "$user" "$pass"
	session && echo "desktop-session: a second login starts the session" ||
	    fail "no session after the second login"
	logout >/dev/null
	# Last, a wrong password.  (A login typed right after a failed one
	# did not start a session in this test, while the same by hand did;
	# not resolved.)
	type_login "$user" wrong-password
	sleep 8
	if pgrep -u "$uid" -x gershwin-session >/dev/null; then
		fail "a wrong password started a session"
	else
		echo "desktop-session: a wrong password is refused"
	fi
	service foxyn_loginwindow onestop >/dev/null
	pw usermod "$user" -w none
	i=0
	while pgrep -x Xorg >/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
	pgrep -x Xorg >/dev/null && fail "Xorg still runs after stopping LoginWindow"
	[ "$ok" = 1 ] && echo "desktop-session: LoginWindow stopped"
	;;
*)	echo "usage: desktop-session wait|stop|login" >&2; exit 2 ;;
esac
[ "$ok" = 1 ]
