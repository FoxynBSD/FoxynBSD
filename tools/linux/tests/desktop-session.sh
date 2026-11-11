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
#	audio	(after wait, with a sound card) play a 4 s 440 Hz tone as
#		the desktop user through the session's PipeWire (JACK sink);
#		boot-test.sh checks what reached the card.  Then as
#		applications do: an 880 Hz tone with paplay, a PulseAudio
#		client, through pipewire-pulse, and a 660 Hz one with
#		AppKit's NSSound (tests/gnustep-sound.m), which plays
#		through libao's OSS driver.  When the card
#		records (a JACK source), also record 3 s and check their
#		length.  `audio HZ`: the card's input plays a HZ tone (such
#		as boot-test.sh's AUDIO_CHECK=capture); the recording must
#		have at least 2 s of sound at HZ ±3% (measured by the
#		median period: QEMU's input loses blocks of frames), and is
#		then played back
#	login	(after stop) Gershwin's LoginWindow, when installed: start
#		foxyn_loginwindow with a test password for the user; check
#		that another account cannot use the display, that a wrong
#		password is refused, that the right one starts the session,
#		that logging out returns to the login window and takes the
#		user's access away, and a second login; then stop the
#		service and remove the password
#	gnustep	(with GNUstep in /System) build and run, as the desktop
#		user, gnustep-mainqueue.m: blocks dispatched to the main
#		queue and NSOperationQueue's main queue run from the run loop
#	clicks	(after wait) build tests/gnustep-clickprobe.m and run it in
#		the session's display as the desktop user; after focusing
#		another window, two instant clicks into it and a key: every
#		-mouseDown: must get its release (return within 1 s) and the
#		key must arrive when typed
#	use	(after wait, Gershwin's session) use it as the desktop user
#		would, by mouse and keyboard: type into TextEdit and save the
#		document (Alt+S, the save panel); create a folder on the
#		desktop (Workspace, File > New Folder) and move it to the
#		Trash (Alt+Backspace, OK); change a setting (System
#		Preferences > Defaults: GSSavePanelShowProgress YES, Set).
#		Each result is checked on disk
#	media STEP LABEL	(after wait, with automount) a USB stick
#		with a FAT file system labelled LABEL, which boot-test.sh
#		plugs in and pulls out through QEMU's monitor:
#		mount: automount mounts it on /media/LABEL as the desktop
#		user (who may unmount it), within 30 s; the user writes a
#		file on it, unless it is there from an earlier mount
#		eject: Eject in its menu on Workspace's desktop (the second
#		icon, under System Disk) unmounts it
#		gone: within 30 s of being pulled out while mounted, it is
#		unmounted (automount's reap) and the kernel survived it
#	openrc	(after stop, with foxyn_openrc) OpenRC's order and recovery:
#		starting the desktop runlevel starts dbus before
#		foxyn-desktop and stopping it stops them the other way; with
#		an X configuration that stops the server, the runlevel still
#		starts, dbus runs, foxyn-desktop is reported crashed and the
#		console keeps working; without it, `rc-service foxyn-desktop
#		restart` brings the desktop back
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
	# Also for the session's sound: on a card that cannot record,
	# foxyn-audio's duplex attempt takes up to 10 s to fail before it
	# starts jackd for playback only, then PipeWire.
	audio=0
	[ -x /System/Library/PipeWire/bin/pipewire ] && [ -c /dev/dsp ] && audio=1
	i=0
	while [ "$i" -lt 90 ]; do
		XAUTHORITY=$(cat /var/run/foxyn-session.xauthority 2>/dev/null)
		xwininfo -root -tree 2>/dev/null | grep -q "\"$appwin\"" &&
		    xwininfo -root -tree | grep -q '"Terminal"' &&
		    { [ "$audio" = 0 ] || pgrep -u "$uid" -x wireplumber >/dev/null; } &&
		    break
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
	# The session's sound (foxyn-audio), with PipeWire and a sound card.
	[ "$audio" = 1 ] && procs="$procs jackd pipewire wireplumber"
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
	# GnuTLS (GNUstep's TLS) finds the system's certificate authorities
	# through p11-kit (foxyn-desktop configures its trust module).
	if command -v trust >/dev/null; then
		n=$(trust list --filter=ca-anchors 2>/dev/null | grep -c 'label:')
		[ "$n" -gt 0 ] &&
		    echo "desktop-session: p11-kit trusts $n certificate authorities" ||
		    fail "p11-kit trusts no certificate authority (HTTPS fails)"
	fi
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
	# running: the session's service runs.  (Asked from OpenRC itself:
	# DragonFly's rc.subr returns 0 from a status_cmd whatever its
	# result, so `service foxyn_openrc status` always succeeds.)
	running() {
		if [ "$svc" = foxyn_openrc ]; then
			rc-service foxyn-desktop status
		else
			service $svc status
		fi
	}
	i=0
	while { pgrep -x Xorg || pgrep -u "$uid" || running; } >/dev/null &&
	    [ "$i" -lt 30 ]; do
		sleep 1; i=$((i + 1))
	done
	pgrep -x Xorg >/dev/null && fail "Xorg still runs"
	pgrep -u "$uid" >/dev/null && fail "processes of $user remain: $(pgrep -u "$uid" -l | tr '\n' ' ')"
	running >/dev/null && fail "$svc still runs"
	if [ "$svc" = foxyn_openrc ]; then
		# After Log Out OpenRC reports the session stopped, not crashed.
		if [ -n "$sup" ]; then
			i=0
			while ! rc-status desktop | grep -q 'foxyn-desktop.*stopped' &&
			    [ "$i" -lt 10 ]; do
				sleep 1; i=$((i + 1))
			done
			rc-status desktop | grep -q 'foxyn-desktop.*stopped' &&
			    echo "desktop-session: after Log Out OpenRC reports foxyn-desktop stopped" ||
			    fail "after Log Out: $(rc-status desktop | grep foxyn-desktop | tr -s ' ')"
		fi
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
	# shown PATTERN: a window of xwininfo's tree matching the awk
	# PATTERN is mapped (the tree also lists unmapped windows)
	shown() {
		for w in $(xwininfo -root -tree 2>/dev/null | awk "/$1/ {print \$1}"); do
			xwininfo -id "$w" | grep -q 'Map State: IsViewable' && return 0
		done
		return 1
	}
	# greeter: wait for the login window to be shown (60 s), and for
	# LoginWindow to settle: typing right after a logout, while it reset
	# its fields, lost characters of the password.
	greeter() {
		i=0
		while [ "$i" -lt 30 ]; do
			if shown '"[^"]*": \("LoginWindow" "LoginWindow"\)  400x370'; then
				sleep 3
				return 0
			fi
			sleep 2; i=$((i + 1))
		done
		return 1
	}
	# session: wait for the user's supervisor and Workspace (180 s)
	session() {
		i=0
		while [ "$i" -lt "${1:-90}" ]; do
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
		# GNUstep spends a click on a button of a window that is not
		# key on making it key: after xdotool's typing the window of a
		# freshly started LoginWindow is not, and the click on Log In
		# was lost (0 of 2 logins, 2 of 2 with this click first).
		xdotool mousemove 640 420 click 1
		sleep 1
		# The Log In button (Return started a second login, which ended
		# the first session, in some runs).
		login_click
	}
	# login_click: press Log In as a person does, for 150 ms
	login_click() {
		xdotool mousemove 765 503 mousedown 1
		sleep 0.15
		xdotool mouseup 1
	}
	# started: wait for the session after type_login.  About one first
	# login in ten, the Log In button stays pressed (it tracks the mouse
	# and misses the release) and nothing happens until the next click;
	# report it, click once more, and wait (in all, 180 s).
	started() {
		session 15 && return 0
		echo "desktop-session: WARN no session 30 s after Log In; clicking it again"
		login_click
		session 75
	}
	# logout: as Menu's Log Out, then wait for LoginWindow's cleanup
	# (the user's processes end, the PAM session closes) and the login
	# window.  (The login window stays in the window tree while the
	# session runs, unmapped: greeter alone does not wait.)
	logout() {
		pkill -TERM -u "$uid" -x gershwin-session
		i=0
		while { pgrep -u "$uid" || [ -d "/var/run/xdg/$user" ]; } >/dev/null &&
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
	if started; then
		echo "desktop-session: the password starts the session as $user"
	else
		fail "no session after logging in"
	fi
	denied nobody && echo "desktop-session: the session's display rejects nobody" ||
	    fail "nobody can use the session's display"
	# The PAM session LoginWindow opened: pam_xdg's runtime directory,
	# and in it the session's sound (Gershwin.sh starts foxyn-audio).
	rt=/var/run/xdg/$user
	if [ -d "$rt" ] && [ "$(stat -f %u:%Lp "$rt")" = "$uid:700" ]; then
		echo "desktop-session: the session has its runtime directory $rt"
	else
		fail "no runtime directory $rt for the session"
	fi
	if [ -x /System/Library/PipeWire/bin/pipewire ] && [ -c /dev/dsp ]; then
		i=0
		# (foxyn-audio's duplex attempt alone can take 10 s.)
		while ! { [ -S "$rt/pipewire-0" ] &&
		    pgrep -u "$uid" -x wireplumber >/dev/null; } && [ "$i" -lt 60 ]; do
			sleep 1; i=$((i + 1))
		done
		if [ -S "$rt/pipewire-0" ] && pgrep -u "$uid" -x wireplumber >/dev/null; then
			echo "desktop-session: PipeWire and WirePlumber run in the session"
			sh "$0" audio || fail "no sound in the LoginWindow session"
		else
			fail "no PipeWire in the session ($(cat "$rt/jackd.log" "$rt/pipewire.log" 2>/dev/null | tail -3 | tr '\n' ' '))"
		fi
	fi
	if logout; then
		echo "desktop-session: logging out shows the login window again"
	else
		fail "no login window after logging out"
	fi
	[ -d "$rt" ] && fail "$rt remains after logging out" ||
	    echo "desktop-session: logging out removed $rt"
	denied "$user" && echo "desktop-session: after logging out $user cannot use the display" ||
	    fail "$user can still use the display"
	pgrep -u "$uid" >/dev/null &&
	    echo "desktop-session: processes of $user remain: $(pgrep -u "$uid" -l | tr '\n' ' ')"
	type_login "$user" "$pass"
	started && echo "desktop-session: a second login starts the session" ||
	    fail "no session after the second login"
	logout >/dev/null
	# A session that fails at once (the user's shell is nologin):
	# LoginWindow reports it, and after OK the system is as before the
	# login: the login window, nothing of the user's left, no access to
	# the display.  (Eau's alert panel: an unnamed window 500 wide.)
	shell=$(pw usershow "$user" | cut -d: -f10)
	pw usermod "$user" -s /usr/sbin/nologin
	alert='\(has no name\): \("LoginWindow" "LoginWindow"\)  500x[0-9]+'
	# reported N: wait up to N seconds for the alert
	reported() {
		i=0
		while ! shown "$alert" && [ "$i" -lt "$1" ]; do sleep 2; i=$((i + 2)); done
		shown "$alert"
	}
	type_login "$user" "$pass"
	if ! reported 30; then
		echo "desktop-session: WARN no report 30 s after Log In; clicking it again"
		login_click
		reported 30
	fi
	if shown "$alert"; then
		echo "desktop-session: a failing session is reported"
	else
		fail "no report of the failing session"
	fi
	# OK
	xdotool mousemove 815 479 mousedown 1
	sleep 0.15
	xdotool mouseup 1
	sleep 3
	pw usermod "$user" -s "$shell"
	if shown '"[^"]*": \("LoginWindow" "LoginWindow"\)  400x370' &&
	    ! pgrep -u "$uid" >/dev/null && [ ! -d "/var/run/xdg/$user" ] &&
	    denied "$user"; then
		echo "desktop-session: after a failing session the login window is back, nothing of $user left"
	else
		fail "after a failing session: processes $(pgrep -u "$uid" -l | tr '\n' ' '), xdg $(ls -d /var/run/xdg/$user 2>/dev/null)"
	fi
	# A wrong password: refused, without an alert (a modal alert
	# blocked LoginWindow until dismissed), and the right password works
	# right after it.
	type_login "$user" wrong-password
	sleep 8
	if pgrep -u "$uid" -x gershwin-session >/dev/null; then
		fail "a wrong password started a session"
	else
		echo "desktop-session: a wrong password is refused"
	fi
	# (Eau's alert panel is an unnamed 500x150 LoginWindow window.)
	alert=0
	for w in $(xwininfo -root -tree 2>/dev/null |
	    awk '/\(has no name\): \("LoginWindow" "LoginWindow"\)  500x150/ {print $1}'); do
		xwininfo -id "$w" | grep -q 'Map State: IsViewable' && alert=1
	done
	if [ "$alert" = 1 ]; then
		fail "a wrong password shows an alert"
	else
		echo "desktop-session: a wrong password shows no alert"
	fi
	type_login "$user" "$pass"
	if started; then
		echo "desktop-session: the right password works after a wrong one"
	else
		fail "no session with the right password after a wrong one"
	fi
	logout >/dev/null
	service foxyn_loginwindow onestop >/dev/null
	pw usermod "$user" -w none
	i=0
	while pgrep -x Xorg >/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
	pgrep -x Xorg >/dev/null && fail "Xorg still runs after stopping LoginWindow"
	[ "$ok" = 1 ] && echo "desktop-session: LoginWindow stopped"
	;;
gnustep)
	if [ ! -r /System/Library/Makefiles/GNUstep.sh ]; then
		echo "desktop-session: no GNUstep in /System"
		exit 0
	fi
	d=$(mktemp -d /tmp/gnustep-test.XXXXXX) || exit 1
	cp "$(dirname "$0")/gnustep-mainqueue.m" "$d/"
	chown -R "$user" "$d"
	cat > "$d/run.sh" <<'RUN'
set +u
. /System/Library/Makefiles/GNUstep.sh
cd "$1" || exit 1
libs=/System/Library/Libraries
clang19 $(gnustep-config --objc-flags) -fblocks -o mainqueue gnustep-mainqueue.m \
    $(gnustep-config --base-libs) -ldispatch -L$libs -Wl,-rpath,$libs || exit 2
./mainqueue
RUN
	out=$(su -m "$user" -c "sh $d/run.sh $d" 2>&1)
	rc=$?
	echo "$out" | sed 's/^/desktop-session: /'
	[ "$rc" = 0 ] && echo "desktop-session: GNUstep runs main-queue blocks from the run loop" ||
	    fail "GNUstep's main queue (exit $rc)"
	rm -rf "$d"
	[ "$ok" = 1 ]
	;;
use)
	[ -x /System/Library/Tools/gershwin-session ] ||
	    { echo "desktop-session: no Gershwin session"; exit 0; }
	command -v xdotool >/dev/null || { echo "desktop-session: FAIL no xdotool"; exit 1; }
	XAUTHORITY=$(cat /var/run/foxyn-session.xauthority 2>/dev/null)
	export XAUTHORITY
	home=$(pw usershow "$user" | cut -d: -f9)
	# click X Y: a click as a person makes it (held 150 ms)
	click() {
		xdotool mousemove "$1" "$2" mousedown 1
		sleep 0.15
		xdotool mouseup 1
		sleep 1
	}
	# origin REGEX: the X and Y of the window whose name matches REGEX
	# (its content, below the title bar)
	origin() {
		xdotool search --onlyvisible --name "$1" getwindowgeometry 2>/dev/null |
		    sed -n 's/.*Position: \([0-9]*\),\([0-9]*\).*/\1 \2/p' | head -n 1
	}
	# waitwin REGEX: until such a window exists (30 s)
	waitwin() {
		i=0
		while [ -z "$(origin "$1")" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
		[ -n "$(origin "$1")" ]
	}
	# TextEdit: type, Alt+S, the file name in the save panel, Return.
	f=$home/use-test-$$.txt
	if waitwin '^[*]?UNTITLED$'; then
		xdotool search --name 'UNTITLED' windowactivate --sync >/dev/null 2>&1
		set -- $(origin '^[*]?UNTITLED$')
		click $(($1 + 530)) $(($2 + 300))
		xdotool type --delay 50 "Hello from FoxynBSD"
		sleep 1
		xdotool key alt+s
		if waitwin '^Save Plain Text$'; then
			set -- $(origin '^Save Plain Text$')
			click $(($1 + 213)) $(($2 + 432))
			xdotool type --delay 50 "${f##*/}"
			sleep 1
			xdotool key Return
			sleep 3
		fi
		if [ "$(cat "$f" 2>/dev/null)" = "Hello from FoxynBSD" ]; then
			echo "desktop-session: TextEdit saved what was typed in it (${f##*/})"
		else
			fail "TextEdit: no saved document $f"
		fi
	else
		fail "no TextEdit window"
	fi
	rm -f "$f"
	# Workspace: File > New Folder on the desktop, then Move to Trash.
	rm -rf "$home/Desktop/New Folder" "$home/.Trash/New Folder"
	# Workspace must be the active application before its File menu is
	# used (the menu bar shows the active application's menus): click
	# the desktop until the active window is one of Workspace's: in the
	# same X client id range as its "Desktop" window (GNUstep windows
	# have no _NET_WM_PID).
	desk=$(xdotool search --onlyvisible --name '^Desktop$' | head -n 1)
	i=0
	while [ "$i" -lt 5 ]; do
		click 1000 650
		act=$(xdotool getactivewindow 2>/dev/null)
		[ -n "$act" ] && [ -n "$desk" ] && [ $((act >> 21)) = $((desk >> 21)) ] && break
		sleep 1; i=$((i + 1))
	done
	# File > New Folder: Command-Shift-N (the Command key is Alt)
	xdotool key alt+shift+n
	i=0
	while [ ! -d "$home/Desktop/New Folder" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
	if [ -d "$home/Desktop/New Folder" ]; then
		echo "desktop-session: Workspace made a folder on the desktop"
		sleep 2
		# Select its icon (below System Disk), File > Move to Trash
		# (Command-Backspace), and confirm with the default button.
		click 1231 135
		xdotool key alt+BackSpace
		sleep 2
		xdotool key Return
		i=0
		while [ -e "$home/Desktop/New Folder" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
		if [ ! -e "$home/Desktop/New Folder" ] && [ -d "$home/.Trash/New Folder" ]; then
			echo "desktop-session: Workspace moved it to the Trash"
		else
			fail "Workspace did not move the folder to the Trash"
		fi
	else
		fail "Workspace made no folder on the desktop"
	fi
	rm -rf "$home/.Trash/New Folder"
	# System Preferences (the dock's third icon) > Defaults.
	click 672 767
	# (It opens at the same place; the origins xdotool reports for its
	# window and its panes' differ by the title bar.)
	if waitwin '^System Preferences$'; then
		xdotool mousemove 328 300 click --repeat 2 --delay 150 1
		sleep 3
		if waitwin '^Defaults$'; then
			click 300 451	# GSSavePanelShowProgress
			click 627 482	# its pop-up: NO
			click 627 505	# YES
			click 743 572	# Set
			sleep 1
		fi
	fi
	v=$(su -m "$user" -c "sh -c '. /System/Library/Makefiles/GNUstep.sh; defaults read NSGlobalDomain GSSavePanelShowProgress'" 2>/dev/null)
	case $v in
	*GSSavePanelShowProgress\ 1|*GSSavePanelShowProgress\ YES)
		echo "desktop-session: System Preferences changed a setting ($v)" ;;
	*)	fail "System Preferences: GSSavePanelShowProgress is '$v'" ;;
	esac
	su -m "$user" -c "sh -c '. /System/Library/Makefiles/GNUstep.sh; defaults delete NSGlobalDomain GSSavePanelShowProgress'" >/dev/null 2>&1
	[ "$ok" = 1 ]
	;;
clicks)
	[ -r /System/Library/Makefiles/GNUstep.sh ] ||
	    { echo "desktop-session: no GNUstep in /System"; exit 0; }
	command -v xdotool >/dev/null || { echo "desktop-session: FAIL no xdotool"; exit 1; }
	XAUTHORITY=$(cat /var/run/foxyn-session.xauthority 2>/dev/null)
	export XAUTHORITY
	d=$(mktemp -d /tmp/clickprobe.XXXXXX) || exit 1
	cp "$(dirname "$0")/gnustep-clickprobe.m" "$d/"
	chown -R "$user" "$d"
	cat > "$d/run.sh" <<'RUN'
set +u
. /System/Library/Makefiles/GNUstep.sh
cd "$1" || exit 1
libs=/System/Library/Libraries
clang19 $(gnustep-config --objc-flags) -o clickprobe gnustep-clickprobe.m \
    $(gnustep-config --gui-libs) -L$libs -Wl,-rpath,$libs || exit 2
exec ./clickprobe > clickprobe.log 2>&1
RUN
	# Detached (daemon -f: a session of its own, no controlling
	# terminal): a background su took the console over.
	env DISPLAY=:0 XAUTHORITY="$XAUTHORITY" \
	    daemon -f su -m "$user" -c "sh $d/run.sh $d"
	i=0
	while ! xwininfo -root -tree 2>/dev/null | grep -q '"clickprobe"' && [ "$i" -lt 60 ]; do
		sleep 2; i=$((i + 2))
	done
	sleep 2
	# Another window first (the session's xterm), so the click into the
	# probe activates it; then the clicks as xdotool makes them, press
	# and release back to back.
	xdotool search --name '^Terminal$' windowactivate --sync >/dev/null 2>&1
	sleep 1
	xdotool mousemove 1000 400 click 1; sleep 1
	xdotool mousemove 1000 400 click 1; sleep 1
	typed=$(date +%s)
	xdotool type x
	sleep 3
	pkill -u "$uid" -x clickprobe
	log=$d/clickprobe.log
	stuck=$(awk '/mouseDown enter/ {t=$2} /mouseDown return/ && t {if ($2 - t > 1) n++; t=0}
	    END {print n + 0}' "$log")
	open=$(awk '/mouseDown enter/ {o++} /mouseDown return/ {o--} END {print o + 0}' "$log")
	key=$(awk '/keyDown x/ {print int($2); exit}' "$log")
	if [ "$stuck" = 0 ] && [ "$open" = 0 ] && [ -n "$key" ] && [ $((key - typed)) -le 1 ]; then
		echo "desktop-session: GNUstep gets every click's release; a key arrives when typed"
	else
		fail "clicks: $stuck mouse-downs waited for a release, $open never returned, key at ${key:-never} (typed at $typed)"
		sed 's/^/desktop-session: /' "$log" | tail -8
	fi
	rm -rf "$d"
	[ "$ok" = 1 ]
	;;
openrc)
	if ! grep -q '^foxyn_openrc_enable="YES"' /etc/rc.conf; then
		echo "desktop-session: OpenRC does not run the desktop"
		exit 0
	fi
	# order WORD FIRST SECOND FILE: "WORD FIRST" comes before "WORD
	# SECOND" in OpenRC's output
	order() {
		a=$(grep -n "$1 $2" "$4" | head -n 1 | cut -d: -f1)
		b=$(grep -n "$1 $3" "$4" | head -n 1 | cut -d: -f1)
		[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
	}
	service foxyn_openrc start > /tmp/openrc-start.log 2>&1
	sh "$0" wait > /tmp/openrc-wait.log 2>&1 ||
	    fail "no desktop from OpenRC: $(grep FAIL /tmp/openrc-wait.log | tr '\n' ' ')"
	order Starting dbus foxyn-desktop /tmp/openrc-start.log &&
	    echo "desktop-session: OpenRC starts dbus, then foxyn-desktop" ||
	    fail "OpenRC's start order: $(tr '\n' ' ' < /tmp/openrc-start.log)"
	service foxyn_openrc stop > /tmp/openrc-stop.log 2>&1
	order Stopping foxyn-desktop dbus /tmp/openrc-stop.log &&
	    echo "desktop-session: OpenRC stops foxyn-desktop, then dbus" ||
	    fail "OpenRC's stop order: $(tr '\n' ' ' < /tmp/openrc-stop.log)"
	# The graphical stack fails: a configuration X refuses.
	xconf=/System/Library/XLibre/etc/X11/xorg.conf.d
	[ -d $xconf ] || xconf=/usr/local/etc/X11/xorg.conf.d
	printf 'Section "Broken"\n' > $xconf/99-broken.conf
	lines=$(wc -l < /var/log/foxyn-session.log)
	service foxyn_openrc start > /tmp/openrc-broken.log 2>&1
	i=0
	while [ "$i" -lt 45 ]; do
		st=$(rc-status desktop 2>/dev/null)
		echo "$st" | grep -q 'foxyn-desktop.*crashed' && break
		sleep 3; i=$((i + 3))
	done
	if echo "$st" | grep -q 'dbus.*started' &&
	    echo "$st" | grep -q 'foxyn-desktop.*crashed' &&
	    ! pgrep -x Xorg >/dev/null; then
		# (this runs on the console)
		echo "desktop-session: with X broken, dbus runs, foxyn-desktop is reported crashed, the console works"
	else
		fail "with X broken: $(echo "$st" | tr -s ' \n' ' ')"
	fi
	tail -n +$((lines + 1)) /var/log/foxyn-session.log | grep -q 'X did not start' &&
	    echo "desktop-session: foxyn-session.log says why: X did not start" ||
	    fail "no reason in foxyn-session.log"
	rm -f $xconf/99-broken.conf
	rc-service foxyn-desktop restart > /tmp/openrc-restart.log 2>&1
	if sh "$0" wait > /tmp/openrc-wait2.log 2>&1; then
		echo "desktop-session: rc-service foxyn-desktop restart brings the desktop back"
	else
		fail "no desktop after the restart: $(grep FAIL /tmp/openrc-wait2.log | tr '\n' ' ')"
	fi
	sh "$0" stop >/dev/null 2>&1
	# LoginWindow from OpenRC (foxyn-desktop -o -l runs it instead of
	# foxyn-desktop): the login window on an X server with a cookie,
	# and stopping the service ends both.
	if [ -x /usr/local/etc/init.d/foxyn-loginwindow ] &&
	    [ -x /System/Library/CoreServices/Applications/LoginWindow.app/LoginWindow ]; then
		rc-service dbus start >/dev/null 2>&1
		rc-service foxyn-loginwindow start > /tmp/openrc-lw.log 2>&1
		i=0 shown=0
		while [ "$i" -lt 60 ]; do
			for w in $(env DISPLAY=:0 XAUTHORITY=/var/run/xauth xwininfo -root -tree 2>/dev/null |
			    awk '/"[^"]*": \("LoginWindow" "LoginWindow"\)  400x370/ {print $1}'); do
				env DISPLAY=:0 XAUTHORITY=/var/run/xauth xwininfo -id "$w" |
				    grep -q 'IsViewable' && shown=1
			done
			[ "$shown" = 1 ] && break
			sleep 2; i=$((i + 2))
		done
		if [ "$shown" = 1 ] &&
		    ! su -m nobody -c 'env DISPLAY=:0 XAUTHORITY=/dev/null xwininfo -root' >/dev/null 2>&1; then
			echo "desktop-session: OpenRC's foxyn-loginwindow shows the login window; nobody cannot use the display"
		else
			fail "OpenRC's foxyn-loginwindow: shown=$shown $(tr '\n' ' ' < /tmp/openrc-lw.log)"
		fi
		rc-service foxyn-loginwindow stop >/dev/null 2>&1
		rc-service dbus stop >/dev/null 2>&1
		i=0
		while pgrep -x 'Xorg|LoginWindow' >/dev/null && [ "$i" -lt 20 ]; do
			sleep 1; i=$((i + 1))
		done
		pgrep -x 'Xorg|LoginWindow' >/dev/null &&
		    fail "X or LoginWindow still runs after rc-service foxyn-loginwindow stop" ||
		    echo "desktop-session: rc-service foxyn-loginwindow stop ends LoginWindow and X"
	fi
	[ "$ok" = 1 ]
	;;
audio)
	[ -c /dev/dsp ] || { echo "desktop-session: FAIL no sound card"; exit 1; }
	pw=/System/Library/PipeWire/bin
	[ -x $pw/pw-play ] || { echo "desktop-session: FAIL no PipeWire"; exit 1; }
	# The automatic session's runtime directory (foxyn-session), else
	# that of a LoginWindow session (pam_xdg).
	rt=/var/run/user/$uid
	[ -d "$rt" ] || rt=/var/run/xdg/$user
	# tone HZ SECONDS FILE: a 48 kHz mono WAV of a sine
	tone() {
		ruby -e 'hz, s = ARGV[0].to_i, ARGV[1].to_i; r = 48000
		    d = (0...r * s).map { |i| (Math.sin(2 * Math::PI * hz * i / r) * 12000).to_i }.pack("s<*")
		    File.binwrite(ARGV[2], ["RIFF", 36 + d.size, "WAVE", "fmt ", 16, 1, 1, r, r * 2, 2, 16, "data", d.size].pack("a4Va4a4VvvVVvva4V") + d)' "$@"
		chmod 644 "$3"
	}
	tone 440 4 /tmp/tone.wav
	sink=$(su -m "$user" -c "env XDG_RUNTIME_DIR=$rt $pw/wpctl inspect @DEFAULT_AUDIO_SINK@" 2>&1 |
	    sed -n 's/.*node.description = "\(.*\)"/\1/p')
	echo "desktop-session: default sink: ${sink:-none}"
	if su -m "$user" -c "env XDG_RUNTIME_DIR=$rt timeout 30 $pw/pw-play /tmp/tone.wav" \
	    > /tmp/pw-play.log 2>&1; then
		echo "desktop-session: $user played a 440 Hz tone through PipeWire"
	else
		sed 's/^/desktop-session: /' /tmp/pw-play.log
		fail "pw-play"
	fi
	# A PulseAudio application: paplay (libpulse from contrib/pulseaudio)
	# through pipewire-pulse, which PipeWire starts.
	if [ -x $pw/paplay ]; then
		tone 880 3 /tmp/tone880.wav
		server=$(su -m "$user" -c "env XDG_RUNTIME_DIR=$rt $pw/pactl info" 2>/dev/null |
		    sed -n 's/^Server Name: //p')
		echo "desktop-session: PulseAudio server: ${server:-none}"
		if su -m "$user" -c "env XDG_RUNTIME_DIR=$rt timeout 30 $pw/paplay /tmp/tone880.wav" \
		    > /tmp/paplay.log 2>&1; then
			echo "desktop-session: $user played an 880 Hz tone with paplay (PulseAudio)"
		else
			sed 's/^/desktop-session: /' /tmp/paplay.log
			fail "paplay"
		fi
	fi
	# A GNUstep application: NSSound (libao's OSS driver: a virtual
	# channel of the card, next to jackd's).
	if [ -r /System/Library/Makefiles/GNUstep.sh ] &&
	    [ -d /System/Library/Bundles/AudioOutput.nssound ]; then
		d=$(mktemp -d /tmp/gnustep-sound.XXXXXX) || exit 1
		cp "$(dirname "$0")/gnustep-sound.m" "$d/"
		tone 660 3 "$d/tone660.wav"
		chown -R "$user" "$d"
		cat > "$d/run.sh" <<'RUN'
set +u
. /System/Library/Makefiles/GNUstep.sh
cd "$1" || exit 1
libs=/System/Library/Libraries
clang19 $(gnustep-config --objc-flags) -o sound gnustep-sound.m \
    $(gnustep-config --gui-libs) -L$libs -Wl,-rpath,$libs || exit 3
./sound tone660.wav 2>/dev/null
RUN
		out=$(env DISPLAY=:0 XAUTHORITY="$(cat /var/run/foxyn-session.xauthority 2>/dev/null)" \
		    su -m "$user" -c "sh $d/run.sh $d" 2>&1)
		rc=$?
		echo "$out" | sed 's/^/desktop-session: /'
		[ "$rc" = 0 ] &&
		    echo "desktop-session: $user played a 660 Hz tone with NSSound (GNUstep)" ||
		    fail "NSSound (exit $rc)"
		rm -rf "$d"
	fi
	# (Only a card that records: "play/rec" in /dev/sndstat.)
	if grep 'default' /dev/sndstat | grep -q 'rec' &&
	    su -m "$user" -c "env XDG_RUNTIME_DIR=$rt $pw/wpctl inspect @DEFAULT_AUDIO_SOURCE@" \
	    > /tmp/pw-source.log 2>&1; then
		rm -f /tmp/rec.wav
		su -m "$user" -c "env XDG_RUNTIME_DIR=$rt timeout 3 $pw/pw-record --rate 48000 --channels 2 --format s16 /tmp/rec.wav" \
		    > /tmp/pw-record.log 2>&1
		# 4 bytes a frame after the 44-byte header: 2.5 to 3.5 s.
		size=$(stat -f %z /tmp/rec.wav 2>/dev/null || echo 0)
		ms=$(( (size - 44) / 192 ))
		if [ "$ms" -ge 2500 ] && [ "$ms" -le 3500 ]; then
			echo "desktop-session: $user recorded ${ms} ms through PipeWire (JACK Source)"
		else
			sed 's/^/desktop-session: /' /tmp/pw-record.log
			fail "pw-record: ${ms} ms in 3 s"
		fi
		# What was recorded, left channel: sound is 0.1 s windows
		# louder than RMS 1000; the frequency is 48 kHz over the
		# median distance between rising zero crossings in them.
		# QEMU's input loses blocks of frames: a lost block shortens
		# one period, and the median ignores it.  od prints 8
		# samples, 4 frames, a line.
		if [ -n "${2:-}" ]; then
			heard=$(od -An -v -td2 -j44 /tmp/rec.wav | awk '
			{ for (i = 1; i <= NF; i += 2) { x = $i; sq += x * x; k++
			      if (p < 0 && x >= 0) { if (last) d[nd++] = k - last; last = k }
			      p = x; n++
			      if (n == 4800) { if (sq / n > 1000000) { s++
				      for (c = 0; c < nd; c++) h[d[c]]++
				      m += nd }
				  n = 0; sq = 0; nd = 0 } } }
			END { for (l = 1; cum < m / 2 && l < 48000; l++) cum += h[l]
			      printf "%.1f %d", s / 10, (m && l > 1) ? 48000 / (l - 1) : 0 }')
			echo "desktop-session: the recording has ${heard% *} s of sound, at ${heard#* } Hz"
			[ "$(echo "$heard" | awk -v hz="$2" '{ print ($1 >= 2 && $2 >= hz * 0.97 && $2 <= hz * 1.03) }')" = 1 ] ||
			    fail "the card's $2 Hz input did not reach the recording"
			su -m "$user" -c "env XDG_RUNTIME_DIR=$rt timeout 30 $pw/pw-play /tmp/rec.wav" \
			    > /tmp/pw-play.log 2>&1 &&
			    echo "desktop-session: $user played the recording back" ||
			    fail "pw-play of the recording"
		fi
	elif [ -n "${2:-}" ]; then
		fail "no audio source, but the card's input plays $2 Hz"
	else
		echo "desktop-session: no audio source (the card does not record)"
	fi
	[ "$ok" = 1 ]
	;;
media)
	label=${3:-}
	[ -n "$label" ] || { echo "usage: desktop-session media mount|eject|gone LABEL" >&2; exit 2; }
	[ -x /usr/local/sbin/automount ] || { echo "desktop-session: FAIL no automount"; exit 1; }
	mnt=/media/$label
	# mounted: "mounted by USER" in mount -v when the user mounted it
	mounted() { mount -v | grep -q " on $mnt (.*mounted by $user"; }
	case ${2:-} in
	mount)
		i=0
		while ! mounted && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
		if ! mounted; then
			mount | grep media | sed 's/^/desktop-session: /'
			tail -n 5 /var/log/automount.log | sed 's/^/desktop-session: /'
			fail "$label is not mounted on $mnt by $user"
		elif [ -f "$mnt/foxyn-test.txt" ]; then
			echo "desktop-session: $label mounted again on $mnt by $user, with the file written before: $(cat "$mnt/foxyn-test.txt")"
		else
			echo "desktop-session: automount mounted $label on $mnt as $user ($(mount | sed -n "s|.* on $mnt (\(.*\))|\1|p"))"
			printf 'echo written by %s > %s/foxyn-test.txt\n' "$user" "$mnt" > /tmp/media-write.sh
			chmod 644 /tmp/media-write.sh
			if su -m "$user" -c "sh /tmp/media-write.sh" &&
			    [ "$(cat "$mnt/foxyn-test.txt")" = "written by $user" ]; then
				echo "desktop-session: $user wrote a file on $label"
			else
				fail "$user cannot write on $label"
			fi
		fi
		;;
	eject)
		command -v xdotool >/dev/null || { echo "desktop-session: FAIL no xdotool"; exit 1; }
		XAUTHORITY=$(cat /var/run/foxyn-session.xauthority 2>/dev/null)
		export XAUTHORITY
		# GNUstep's context menu stays up while the right button is
		# held; Eject is its fourth item.
		xdotool mousemove 1231 135 mousedown 3
		sleep 1.5
		xdotool mousemove 1180 215
		sleep 0.3
		xdotool mouseup 3
		i=0
		while mount | grep -q " on $mnt " && [ "$i" -lt 15 ]; do sleep 1; i=$((i + 1)); done
		if mount | grep -q " on $mnt "; then
			fail "Workspace's Eject did not unmount $mnt"
		else
			echo "desktop-session: Workspace's Eject unmounted $label as $user"
		fi
		;;
	gone)
		i=0
		while mount | grep -q " on $mnt " && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
		if mount | grep -q " on $mnt "; then
			tail -n 5 /var/log/automount.log | sed 's/^/desktop-session: /'
			fail "$mnt is still mounted after the stick was pulled out"
		else
			echo "desktop-session: pulled out while mounted, $label was unmounted ($(grep -c reap /var/log/automount.log) reap)"
		fi
		;;
	*)	echo "usage: desktop-session media mount|eject|gone LABEL" >&2; exit 2 ;;
	esac
	[ "$ok" = 1 ]
	;;
*)	echo "usage: desktop-session wait|stop|audio|login|media" >&2; exit 2 ;;
esac
[ "$ok" = 1 ]
