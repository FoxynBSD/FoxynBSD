#!/bin/sh
# The desktop that foxyn-desktop(8) installed (boot-test.sh --desktop).
#	wait	wait for the session that rc.d started at boot: X, a window
#		manager (WindowManager or twm), an xterm and the GNUstep
#		application's window (TextEdit's with GNUstep from source in
#		/System, else Sudoku's) and Gershwin's Menu when installed,
#		all clients as the desktop user
#	stop	end the session: as Menu's Log Out does, SIGTERM to the
#		user's gershwin-session when it runs, else `service
#		foxyn_desktop stop`; X, the service and the user's
#		processes must be gone
ok=1
fail() { echo "desktop-session: FAIL $*"; ok=0; }
user=$(sed -n 's/^foxyn_desktop_user="\(.*\)"$/\1/p' /etc/rc.conf | tail -n 1)
[ -n "$user" ] || { echo "desktop-session: FAIL foxyn_desktop_user is not set"; exit 1; }
uid=$(id -u "$user") || exit 1
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
	service foxyn_desktop status | sed 's/^/desktop-session: /'
	echo "desktop-session: X $(sed -n 's/.*scfb(0): Using: \(.*\)/\1/p' /var/log/Xorg.0.log | head -n 1 | tr -s ' ')"
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
	[ -x /System/Library/Tools/Gershwin/Workspace ] &&
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
		service foxyn_desktop stop | sed 's/^/desktop-session: /'
	fi
	i=0
	while { pgrep -x Xorg || pgrep -u "$uid" ||
	    service foxyn_desktop status; } >/dev/null && [ "$i" -lt 30 ]; do
		sleep 1; i=$((i + 1))
	done
	pgrep -x Xorg >/dev/null && fail "Xorg still runs"
	pgrep -u "$uid" >/dev/null && fail "processes of $user remain: $(pgrep -u "$uid" -l | tr '\n' ' ')"
	service foxyn_desktop status >/dev/null && fail "foxyn_desktop still runs"
	[ "$ok" = 1 ] && echo "desktop-session: X and the session stopped"
	;;
*)	echo "usage: desktop-session wait|stop" >&2; exit 2 ;;
esac
[ "$ok" = 1 ]
