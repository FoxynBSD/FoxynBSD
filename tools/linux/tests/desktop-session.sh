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
#		boot-test.sh checks what reached the card.  When the card
#		records (a JACK source), also record 3 s and check their
#		length
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
		# GNUstep spends a click on a button of a window that is not
		# key on making it key: after xdotool's typing the window of a
		# freshly started LoginWindow is not, and the click on Log In
		# was lost (0 of 2 logins, 2 of 2 with this click first).
		xdotool mousemove 640 420 click 1
		sleep 1
		# The Log In button (Return started a second login, which ended
		# the first session, in some runs).
		xdotool mousemove 765 503 click 1
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
	if session; then
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
audio)
	[ -c /dev/dsp ] || { echo "desktop-session: FAIL no sound card"; exit 1; }
	pw=/System/Library/PipeWire/bin
	[ -x $pw/pw-play ] || { echo "desktop-session: FAIL no PipeWire"; exit 1; }
	# The automatic session's runtime directory (foxyn-session), else
	# that of a LoginWindow session (pam_xdg).
	rt=/var/run/user/$uid
	[ -d "$rt" ] || rt=/var/run/xdg/$user
	ruby -e 'r = 48000; d = (0...r * 4).map { |i| (Math.sin(2 * Math::PI * 440 * i / r) * 12000).to_i }.pack("s<*")
	    File.binwrite("/tmp/tone.wav", ["RIFF", 36 + d.size, "WAVE", "fmt ", 16, 1, 1, r, r * 2, 2, 16, "data", d.size].pack("a4Va4a4VvvVVvva4V") + d)'
	chmod 644 /tmp/tone.wav
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
	if su -m "$user" -c "env XDG_RUNTIME_DIR=$rt $pw/wpctl inspect @DEFAULT_AUDIO_SOURCE@" \
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
	else
		echo "desktop-session: no audio source (the card does not record)"
	fi
	[ "$ok" = 1 ]
	;;
*)	echo "usage: desktop-session wait|stop|audio|login" >&2; exit 2 ;;
esac
[ "$ok" = 1 ]
