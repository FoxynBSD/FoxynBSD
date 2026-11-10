#!/bin/sh
#
# Non-interactive boot test: boot the ESP built by `build.sh esp` under
# QEMU (via qemu.sh) and wait for the kernel to reach the root mount
# prompt, which is as far as a kernel-only boot can get.  With --root, also
# attach the root image from `build.sh rootfs`, wait for the login prompt
# that getty prints once /etc/rc has finished, then log in as root over
# the serial line and check that a shell runs a command, the network
# (dhcpcd, fetch) and TLS.  --disk does the same with the writable disk
# image from `build.sh disk`, and powers the machine off with halt(8) at
# the end, so a second run boots what the first one left on the disk.
# --install boots root.iso with an empty disk ($INSTALLED) as well, logs
# in, runs foxyn-install on it and powers off; --installed then boots that
# disk alone (its own ESP and loader) and runs the --root tests.
# --bsdinstaller logs in as "installer" instead and passes when the BSD
# Installer shows its welcome screen (the image with the world has it).
# --desktop-setup boots a disk ($DISK) with a VGA card, logs in, runs
# foxyn-desktop(8) on it (X and GNUstep from DPorts: needs the internet)
# and powers off; `build.sh desktop` uses it.  --desktop boots the result
# ($OBJDIR/desktop.img by default), checks that the session started at
# boot (X, twm, an xterm and a GNUstep window, as the desktop user),
# saves a screenshot in $OBJDIR/qemu/desktop.ppm, stops the session with
# `service foxyn_desktop stop` and checks that X is gone.
#
# Usage:
#	tools/linux/boot-test.sh [--root|--disk|--install|--installed|--bsdinstaller|--desktop-setup|--desktop] [KERNCONF]
#
# Environment:
#	BOOT_TIMEOUT	seconds to wait (default 300)
#	BOOT_LOG	serial log path (default $OBJDIR/qemu/<KERNCONF>.boot.log)
#	INSTALLED	the disk --install installs on and --installed boots
#			(default $OBJDIR/installed.img, made INSTALL_SIZE big, 4G)
#	INSTALL_ARGS	foxyn-install options for --install (e.g. "-t ufs")
#	PKG_CHECK	1: with --disk or --installed, also bootstrap pkg(8)
#			and install inxi from DragonFly's mirror
#			(/root/tests/pkg-check; needs the internet)
#	DESKTOP_CHECK	1: with --disk or --installed, also install Xorg and
#			GNUstep from DPorts and start a GNUstep application
#			(/root/tests/desktop-check; needs the internet); the
#			machine gets a VGA card and a USB mouse for it
#	AUDIO_CHECK	1: with --disk or --installed, also play a 440 Hz tone
#			through PipeWire, JACK and snd_hda (/root/tests/
#			audio-check; needs the internet); the machine gets an
#			HDA card whose output QEMU writes to $OBJDIR/qemu/
#			audio.wav, and the "audio-wav:" line in the log says
#			how long and at what frequency it sounded
#	DISK		disk for --disk and --desktop-setup (default
#			$OBJDIR/disk.img; --desktop: $OBJDIR/desktop.img)
#	DPORTS_MIRROR	DPorts mirror for audio-check and --desktop-setup
#			(default: pkg's), e.g.
#			https://mirror.sjtu.edu.cn/dragonflybsd/dports
#
# Exit status: 0 if the expected prompt appeared (and, with --root, the
# login worked), 1 otherwise.  The serial
# log is kept either way.

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
# MODE: what the test does after logging in; ROOTARG: what qemu.sh boots.
ROOTARG= SUFFIX= MODE=
case ${1:-} in
--root)	ROOTARG=--root SUFFIX=-root MODE=root; shift ;;
--disk)	ROOTARG=--disk SUFFIX=-disk MODE=disk; shift ;;
--install) ROOTARG=--root SUFFIX=-install MODE=install; shift ;;
--installed) ROOTARG=--installed SUFFIX=-installed MODE=installed; shift ;;
--bsdinstaller) ROOTARG=--root SUFFIX=-bsdinstaller MODE=bsdinstaller; shift ;;
--desktop-setup) ROOTARG=--disk SUFFIX=-desktop-setup MODE=desktopsetup; shift ;;
--desktop) ROOTARG=--disk SUFFIX=-desktop MODE=desktop; shift
	DISK=${DISK:-$OBJDIR/desktop.img}; export DISK ;;
esac
INSTALLED=${INSTALLED:-$OBJDIR/installed.img}
if [ "$MODE" = install ]; then
	# A new empty disk, the third virtio disk (vbd2) after the ESP and
	# root.iso.
	rm -f "$INSTALLED"
	truncate -s "${INSTALL_SIZE:-4G}" "$INSTALLED"
	ROOTDISK=$INSTALLED
	export ROOTDISK
fi
export INSTALLED
CONF=${1:-X86_64_GENERIC}
TIMEOUT=${BOOT_TIMEOUT:-300}
LOG=${BOOT_LOG:-$OBJDIR/qemu/$CONF.boot$SUFFIX.log}
FAIL='panic:|Fatal trap|db>'
if [ -n "$ROOTARG" ]; then
	# getty's prompt, after /etc/rc ran and init went multi-user.
	SUCCESS='^login: '
	FAIL="$FAIL|mountroot>|Manual root filesystem specification|Enter full pathname of shell"
else
	# Reaching any of these means the kernel booted and asks for a root.
	SUCCESS='mountroot>|Manual root filesystem specification'
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

if [ -n "$ROOTARG" ]; then
	# With a root, the test also logs in, so it needs to type on the
	# serial line: QEMU reads $PIPE.in and writes $PIPE.out.  Holding
	# $PIPE.in open read-write on fd 3 never blocks.
	PIPE=$OBJDIR/qemu/$CONF.serial
	rm -f "$PIPE.in" "$PIPE.out"
	mkfifo "$PIPE.in" "$PIPE.out"
	exec 3<>"$PIPE.in"
	cat "$PIPE.out" > "$LOG" &
	catpid=$!
	CONSOLE_ENV="SERIAL_PIPE=$PIPE"
	# The network test fetches http://10.0.2.100/: QEMU's user-mode
	# network runs this for each connection to it, with the connection
	# on its standard input and output.
	HTTPD=$OBJDIR/qemu/http-ok.sh
	cat > "$HTTPD" <<'EOF'
#!/bin/sh
# Read the request up to its empty line, then answer it.
cr=$(printf '\r')
while IFS= read -r l && [ -n "$l" ] && [ "$l" != "$cr" ]; do :; done
printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nfoxynbsd-net-42\n'
EOF
	chmod 755 "$HTTPD"
	case $HTTPD in
	*[,\ ]*) echo ">>> $HTTPD: no commas or spaces in OBJDIR for the network test" >&2
		NETDEV_OPTS= ;;
	*)	NETDEV_OPTS=",guestfwd=tcp:10.0.2.100:80-cmd:$HTTPD" ;;
	esac
	export NETDEV_OPTS
else
	catpid=
	CONSOLE_ENV="SERIAL_LOG=$LOG"
fi

# A USB keyboard on an xHCI controller: check-boot-log.sh usb checks
# that the kernel's xhci driver (xhci.ko, which the loader loads)
# enumerates it.  The desktop test also needs a display and a mouse.
DESKTOP_DEVS=
DESKTOP_OPTION=
USB_DEVS="-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0"
MONITOR_ENV=
if [ "${DESKTOP_CHECK:-0}" = 1 ] || [ "$MODE" = desktopsetup ] ||
    [ "$MODE" = desktop ]; then
    DESKTOP_OPTION=--desktop-devices
    USB_DEVS=
fi
# The audio test: an HDA card whose output QEMU writes to a WAV file.
WAV=$OBJDIR/qemu/audio.wav
if [ "${AUDIO_CHECK:-0}" = 1 ]; then
	rm -f "$WAV"
	DESKTOP_DEVS="$DESKTOP_DEVS -device intel-hda
	    -device hda-output,audiodev=snd0 -audiodev wav,id=snd0,path=$WAV"
fi
# --desktop takes its screenshot through the QEMU monitor.
MONITOR=$OBJDIR/qemu/$CONF.monitor
if [ "$MODE" = desktop ]; then
	rm -f "$MONITOR"
	MONITOR_ENV="MONITOR_SOCKET=$MONITOR"
fi
# shellcheck disable=SC2086
env OBJDIR="$OBJDIR" "$CONSOLE_ENV" $MONITOR_ENV "$SRCDIR/tools/linux/qemu.sh" \
    --serial ${ROOTARG:---kernel-only} $DESKTOP_OPTION \
    "$CONF" -- $USB_DEVS $DESKTOP_DEVS </dev/null >/dev/null 2>"$LOG.stderr" &
pid=$!

result=1
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
	if grep -Eq "$SUCCESS" "$LOG" 2>/dev/null; then
		result=0
		break
	fi
	if grep -Eq "$FAIL" "$LOG" 2>/dev/null; then
		break
	fi
	kill -0 "$pid" 2>/dev/null || break
	sleep 5
	elapsed=$((elapsed + 5))
done

# Log in as root (no password) and run a command whose output differs
# from its echo, so seeing it proves PAM let root in and a shell ran.
# Commands go through sh -c: root's login shell is csh in an image with
# the whole world, sh in the base image.
# Repeat the command in case it was typed before the shell read input.
LOGIN_OK='login-ok-42 root'
# --bsdinstaller: the installer user's shell is /usr/sbin/installer.  It
# asks for the terminal type on a serial console, then the curses front
# end and the back end start and show the welcome screen.
if [ "$result" -eq 0 ] && [ "$MODE" = bsdinstaller ]; then
	result=1
	printf 'installer\r' >&3
	tries=0
	while [ "$tries" -lt 36 ]; do
		sleep 5
		if grep -aq 'Welcome to the FoxynBSD Live CD' "$LOG"; then
			result=0
			break
		fi
		grep -Eq "$FAIL|Login incorrect|Command Failed" "$LOG" && break
		grep -aq 'What is your terminal type' "$LOG" &&
		    ! grep -aq 'set new TERM' "$LOG" && printf 'vt100\r' >&3
		tries=$((tries + 1))
	done
	[ "$result" -eq 0 ] || echo ">>> the BSD Installer did not start" >&2
	MODE=done
fi
if [ "$result" -eq 0 ] && [ -n "$ROOTARG" ] && [ "$MODE" != done ]; then
	result=1
	printf 'root\r' >&3
	tries=0
	while [ "$tries" -lt 12 ]; do
		sleep 5
		if grep -aFq "$LOGIN_OK" "$LOG"; then
			result=0
			break
		fi
		grep -Eq "$FAIL|Login incorrect" "$LOG" && break
		printf "sh -c 'echo login-ok-\$((6*7)) \$(id -un)'\r" >&3
		tries=$((tries + 1))
	done
	[ "$result" -eq 0 ] || echo ">>> logging in as root FAILED" >&2
fi

# --install: install on the empty disk, which this boot sees as vbd2,
# for booting alone (vbd0).  foxyn-install prints "foxyn-install: done"
# when it finished.
if [ "$result" -eq 0 ] && [ "$MODE" = install ]; then
	printf "sh -c 'foxyn-install -y ${INSTALL_ARGS:-} vbd2; echo install-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 120 ] && ! grep -aq '^install-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	grep -aq '^install-42: 0' "$LOG" ||
	    { echo ">>> foxyn-install FAILED" >&2; result=1; }
fi

# --desktop-setup: install the desktop (foxyn-desktop: lines, dsetup-42).
if [ "$result" -eq 0 ] && [ "$MODE" = desktopsetup ]; then
	printf "sh -c 'foxyn-desktop -y ${DPORTS_MIRROR:+-m $DPORTS_MIRROR}; echo dsetup-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 360 ] && ! grep -aq '^dsetup-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	grep -aq '^dsetup-42: 0' "$LOG" ||
	    { echo ">>> foxyn-desktop FAILED" >&2; result=1; }
fi
# --desktop: the session rc.d started at boot (desktop-session: lines,
# dsession-42), a screenshot of it, then stopping it.
if [ "$result" -eq 0 ] && [ "$MODE" = desktop ]; then
	printf "sh -c 'sh /root/tests/desktop-session wait; echo dsession-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 60 ] && ! grep -aq '^dsession-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	grep -aq '^dsession-42: 0' "$LOG" || result=1
	# What the video console shows: the screen QEMU's VGA card scans out.
	rm -f "$OBJDIR/qemu/desktop.ppm"
	python3 -I - "$MONITOR" "$OBJDIR/qemu/desktop.ppm" <<'EOF' || :
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b"screendump " + sys.argv[2].encode() + b"\n")
time.sleep(2)
s.close()
EOF
	if [ -s "$OBJDIR/qemu/desktop.ppm" ]; then
		echo "desktop-screenshot: $OBJDIR/qemu/desktop.ppm" >> "$LOG"
	else
		echo ">>> no screenshot from the QEMU monitor" >&2; result=1
	fi
	printf "sh -c 'sh /root/tests/desktop-session stop; echo dstop-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 12 ] && ! grep -aq '^dstop-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	grep -aq '^dstop-42: 0' "$LOG" || result=1
	[ "$result" -eq 0 ] || echo ">>> the desktop session check FAILED" >&2
fi

# List the running programs once, for CI to check the daemons rc.d
# started ("daemons-42: init syslogd cron ...").
if [ "$result" -eq 0 ] && [ -n "$ROOTARG" ] && [ "$MODE" != install ] &&
    [ "$MODE" != done ] && [ "$MODE" != desktopsetup ] &&
    [ "$MODE" != desktop ]; then
	printf "sh -c 'echo daemons-\$((6*7)): \$(ps -axo comm= | tr \"\\\\n\" \" \")'\r" >&3
	tries=0
	while [ "$tries" -lt 6 ] && ! grep -aq '^daemons-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# cron(8): install the jobs now; cron-check wait (after the
	# compilers, which take minutes) checks that they ran.
	printf "sh -c 'sh /root/tests/cron-check start; echo cronstart-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 6 ] && ! grep -aq '^cronstart-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# The network (dhcpcd's lease, a TCP connection out through QEMU)
	# and TLS (LibreSSL through fetch(1)): /root/tests/net-check prints
	# "net-check:" and "tls-check:" lines and ends with net-42.
	printf "sh -c 'sh /root/tests/net-check; echo net-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 24 ] && ! grep -aq '^net-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# The image's own compilers (gcc 12 and gcc 8): /root/tests/cc-check
	# prints "cc-check:" lines and ends with cc-42.
	printf "sh -c 'sh /root/tests/cc-check; echo cc-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 60 ] && ! grep -aq '^cc-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# Ruby (the image with the world): /root/tests/ruby-check prints
	# "ruby-check:" lines and ends with ruby-42.
	printf "sh -c 'sh /root/tests/ruby-check; echo ruby-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 24 ] && ! grep -aq '^ruby-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# The cron jobs installed above have run ("cron-check:" lines, cron-42).
	printf "sh -c 'sh /root/tests/cron-check wait; echo cron-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 36 ] && ! grep -aq '^cron-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# Run the daily periodic(8) jobs and print their report, each line
	# prefixed with "daily| ", for CI to check.
	printf "sh -c 'periodic daily; sed \"s/^/daily| /\" /var/log/daily.log; echo periodic-\$((6*7)): \$?'\r" >&3
	tries=0
	while [ "$tries" -lt 24 ] && ! grep -aq '^periodic-42:' "$LOG"; do
		sleep 5
		tries=$((tries + 1))
	done
	# Packages from DragonFly's mirror (pkg-check: lines, pkg-42): only
	# on request, as it needs the internet, and on a writable root.
	if [ "${PKG_CHECK:-0}" = 1 ] &&
	    { [ "$MODE" = disk ] || [ "$MODE" = installed ]; }; then
		printf "sh -c 'sh /root/tests/pkg-check; echo pkg-\$((6*7)): \$?'\r" >&3
		tries=0
		while [ "$tries" -lt 180 ] && ! grep -aq '^pkg-42:' "$LOG"; do
			sleep 5
			tries=$((tries + 1))
		done
	fi
	# Xorg and a GNUstep application from DPorts (desktop-check: lines,
	# desktop-42), on request like the packages.
	if [ "${DESKTOP_CHECK:-0}" = 1 ] &&
	    { [ "$MODE" = disk ] || [ "$MODE" = installed ]; }; then
		printf "sh -c 'sh /root/tests/desktop-check; echo desktop-\$((6*7)): \$?'\r" >&3
		tries=0
		while [ "$tries" -lt 240 ] && ! grep -aq '^desktop-42:' "$LOG"; do
			sleep 5
			tries=$((tries + 1))
		done
	fi
	# PipeWire to the HDA card (audio-check: lines, audio-42); what
	# reached the card is checked in the WAV file after QEMU exits.
	if [ "${AUDIO_CHECK:-0}" = 1 ] &&
	    { [ "$MODE" = disk ] || [ "$MODE" = installed ]; }; then
		printf "sh -c 'sh /root/tests/audio-check ${DPORTS_MIRROR:-}; echo audio-\$((6*7)): \$?'\r" >&3
		tries=0
		while [ "$tries" -lt 240 ] && ! grep -aq '^audio-42:' "$LOG"; do
			sleep 5
			tries=$((tries + 1))
		done
	fi
fi

# A disk is shut down cleanly, so the next boot finds its file system
# clean and what this one wrote on it.
if [ "$result" -eq 0 ] && [ "$MODE" != root ] && [ "$MODE" != done ] &&
    [ -n "$MODE" ]; then
	printf 'halt -p\r' >&3
	tries=0
	while [ "$tries" -lt 24 ] && kill -0 "$pid" 2>/dev/null; do
		sleep 5
		tries=$((tries + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		echo ">>> halt -p did not power the machine off" >&2
		result=1
	fi
fi

kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :
[ -n "$catpid" ] && { kill "$catpid" 2>/dev/null || :; wait "$catpid" 2>/dev/null || :; }

# What the HDA card played: QEMU's WAV is 16-bit stereo at 44100 Hz.  In
# 0.1 s windows of the left channel, those louder than RMS 1000 count as
# sound; the frequency is the median over them of half the window's zero
# crossings per second.
if [ "${AUDIO_CHECK:-0}" = 1 ] && [ -f "$WAV" ]; then
	od -An -v -td2 -w4 -j44 "$WAV" | awk '
	{ x = $1; sq += x * x; if ((x < 0) != (p < 0)) zc++; p = x; n++
	  if (n == 4410) { if (sq / n > 1000000) print zc * 5
	      n = 0; sq = 0; zc = 0 } }' | sort -n | awk '{ f[NR] = $1 }
	END { printf "audio-wav: %.1f s of sound", NR / 10
	      if (NR) printf ", %d Hz", f[int((NR + 1) / 2)]
	      printf "\n" }' >> "$LOG"
	grep -a '^audio-wav:' "$LOG" >&2
fi

if [ "$result" -eq 0 ]; then
	if [ "$MODE" = disk ]; then
		echo ">>> boot test passed: disk.img booted to a login prompt and powered off" >&2
		tail -n 4 "$LOG" >&2
	elif [ "$MODE" = desktopsetup ]; then
		echo ">>> boot test passed: foxyn-desktop installed the desktop on $DISK" >&2
	elif [ "$MODE" = desktop ]; then
		echo ">>> boot test passed: the desktop session started at boot and stopped" >&2
		grep -a '^desktop-s' "$LOG" >&2
	elif [ "$MODE" = done ]; then
		echo ">>> boot test passed: the BSD Installer started (welcome screen)" >&2
	elif [ "$MODE" = install ]; then
		echo ">>> boot test passed: foxyn-install installed on $INSTALLED" >&2
		grep -a '^foxyn-install: ' "$LOG" | tail -n 3 >&2
	elif [ "$MODE" = installed ]; then
		echo ">>> boot test passed: $INSTALLED booted alone to a login prompt and powered off" >&2
		tail -n 4 "$LOG" >&2
	elif [ -n "$ROOTARG" ]; then
		echo ">>> boot test passed: root.iso booted to a login prompt" >&2
		tail -n 4 "$LOG" >&2
	else
		echo ">>> boot test passed: kernel reached the root mount prompt" >&2
	fi
else
	echo ">>> boot test FAILED after ${elapsed}s; last serial output:" >&2
	tail -n 40 "$LOG" >&2
	# On a kernel trap, resolve the faulting instruction to a source line
	# and keep the result next to the log ($LOG.fault) for CI to report.
	kdebug=$OBJDIR/sys/$CONF/kernel.debug
	ip=$(sed -n 's/.*instruction pointer[[:space:]]*=[[:space:]]*0x[0-9a-f]*:0x\([0-9a-f]*\).*/\1/p' "$LOG" | head -n 1)
	if [ -n "$ip" ] && [ -f "$kdebug" ] && command -v addr2line >/dev/null; then
		{
			echo "faulting instruction 0x$ip:"
			addr2line -f -i -C -e "$kdebug" "0x$ip" || :
			objdump -d --no-show-raw-insn "$kdebug" 2>/dev/null |
			    grep -B 8 -A 2 "^ *$ip:" || :
		} > "$LOG.fault"
		cat "$LOG.fault" >&2
	fi
	# User faults (machdep.print_user_faults, set by qemu.sh --root) inside
	# the runtime linker: show the code there.  The base comes from the
	# LD_DEBUG trace when there is one; else DragonFly's usual 0x800205000.
	rtld=$OBJDIR/world$SRCDIR/libexec/rtld-elf/ld-elf.so.2
	if [ -n "$ROOTARG" ] && [ -f "$rtld" ] &&
	    grep -q ' rip [0-9a-f]* rsp ' "$LOG"; then
		base=$(sed -n 's/.*ld-elf.so.2 is initialized, base address = 0x\([0-9a-f]*\).*/\1/p' "$LOG" | head -n 1)
		base=$((0x${base:-800205000}))
		size=$(stat -c %s "$rtld")
		{
			grep ' rip [0-9a-f]* rsp ' "$LOG" | sort -u | head -n 5
			for rip in $(sed -n 's/.* rip \([0-9a-f]*\) rsp .*/\1/p' "$LOG" | sort -u | head -n 3); do
				off=$((0x$rip - base))
				[ "$off" -ge 0 ] && [ "$off" -lt $((size * 4)) ] || continue
				printf 'rip %s = ld-elf.so.2+0x%x:\n' "$rip" "$off"
				addr2line -f -i -e "$rtld" "$(printf 0x%x "$off")" || :
				objdump -d --no-show-raw-insn "$rtld" 2>/dev/null |
				    grep -B 12 -A 3 "^ *$(printf %x "$off"):" || :
			done
		} >> "$LOG.fault"
		cat "$LOG.fault" >&2
	fi
	[ -s "$LOG.stderr" ] && { echo ">>> qemu stderr:" >&2; cat "$LOG.stderr" >&2; }
fi
exit "$result"
