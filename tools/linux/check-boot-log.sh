#!/bin/sh
#
# Check the serial log of `boot-test.sh --root` for what the root image
# is expected to do at boot.  CI runs one check per step (so a failure
# names the step); `all` runs every check and reports each failure.
#
# Usage:
#	tools/linux/check-boot-log.sh [-l LOG] CHECK...
#	tools/linux/check-boot-log.sh [-l LOG] all
#
# Checks:
#	rtld		dynamically linked programs ran (/etc/rc.local's marker)
#	rcd		lists commands the rc.d scripts did not find (not fatal)
#	identity	uname -a and /etc/os-release report FoxynBSD (ID_LIKE
#			dragonfly)
#	basics		terminfo, tmpfs /tmp, login classes, devfs rules after
#			the password database, pwd_mkdb
#	syslogd		a logger(1) message reached /var/log/messages
#	daemons		syslogd, cron and devd still run after login
#	periodic	`periodic daily` finished and found every command
#	cxx		the static C++ exception test
#	runtime		compiler-rt builtins (static and dynamic), C++ across a
#			shared library, dlopen(3)
#	fs		permissions and writable runtime directories
#	abi		programs with either ELF ABI note run
#	kld		kernel modules in the image load and unload (skipped,
#			with a notice, when the image has none)
#
# LOG defaults to $OBJDIR/qemu/X86_64_GENERIC.boot-root.log.  Messages
# use GitHub's ::error:: syntax, which reads fine in a terminal too.

set -eu

OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
LOG=$OBJDIR/qemu/X86_64_GENERIC.boot-root.log
if [ "${1:-}" = -l ]; then LOG=$2; shift 2; fi
[ $# -gt 0 ] || { sed -n '9,28p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -f "$LOG" ] || { echo "::error title=boot log::no log at $LOG"; exit 1; }

fail() { echo "::error title=$1::$2"; return 1; }
has() { grep -aqF "$1" "$LOG"; }
lines() { grep -a "$1" "$LOG" | tr -d '\r'; }

check_rtld() {
	has 'FoxynBSD userland is up' ||
	    fail rtld "/etc/rc saw dynamically linked programs fail"
}

check_rcd() {
	local missing
	missing=$(grep -aoE '[^ :]+: not found' "$LOG" | sort -u | tr '\n' ' ') || :
	[ -z "$missing" ] || echo "::notice title=rc.d::missing in the image: $missing"
}

check_identity() {
	grep -aE '^FoxynBSD foxynbsd [^ ]+ FoxynBSD ' "$LOG" ||
	    fail Identity "uname -a does not report FoxynBSD" || return
	# FoxynBSD by name, DragonFly-compatible for tools that read ID_LIKE.
	grep -aE '^os-release: FoxynBSD .*\(ID=foxynbsd, ID_LIKE=dragonfly\)' "$LOG" ||
	    fail Identity "/etc/os-release does not name FoxynBSD like dragonfly"
}

check_basics() {
	! has 'Cannot read termcap database' ||
	    fail terminfo "sh found no terminal database" || return
	has 'rc: /tmp is writable (tmpfs)' ||
	    fail tmpfs "/tmp was not mounted writable" || return
	! has 'login_getclass: unknown class' ||
	    fail login.conf "init found no login class for /etc/rc" || return
	! grep -aqE 'devfsctl: .*invalid (user|group) name' "$LOG" ||
	    fail devfs "devfs rules ran before the password database" || return
	has 'rc: user database ready (root)' ||
	    fail pwd_mkdb "no password database was built in /var"
}

check_syslogd() {
	has 'rc: syslogd wrote to /var/log/messages' ||
	    fail syslogd "a logger(1) message did not reach /var/log/messages"
}

check_daemons() {
	local line d
	line=$(lines '^daemons-42:' | tail -n 1)
	[ -n "$line" ] || fail daemons "the boot test got no process list" || return
	echo "$line"
	for d in syslogd cron devd; do
		case " $line " in
		*" $d "*) ;;
		*) fail daemons "$d is not running"; return ;;
		esac
	done
}

check_periodic() {
	local missing
	grep -aq '^periodic-42:' "$LOG" ||
	    fail periodic "the boot test got no periodic report" || return
	lines '^daily| '
	grep -aq '^daily| -- End of daily output --' "$LOG" ||
	    fail periodic "daily.log has no end marker" || return
	# No match is the good case.
	missing=$(lines '^daily| .*not found' | sed 's/^daily| //' | sort -u | tr '\n' ';') || :
	[ -z "$missing" ] || fail periodic "commands not found: $missing"
}

check_cxx() {
	has 'c++ exceptions: ok' && return
	lines 'c++ exceptions\|cxx-eh' || :
	fail C++ "the exception test did not unwind"
}

check_runtime() {
	local t n want rc=0 m
	lines 'rt-[a-z]*: \|rc: /root/tests/rt-' || :
	for t in rt-builtins rt-cxx rt-dlopen; do
		n=$(grep -ac "^$t: ok" "$LOG") || :
		# rt-builtins runs twice: static and dynamic.
		want=1; [ $t = rt-builtins ] && want=2
		[ "$n" -ge $want ] || fail runtime "$t did not pass" || rc=1
	done
	for m in 'rt-cxx: atexit handler ran' 'rt-cxx: program destructor ran' \
	    'rt-cxx: library destructor ran'; do
		has "$m" || fail runtime "missing: $m" || rc=1
	done
	return $rc
}

check_fs() {
	lines '^fs-check: ' || :
	grep -aq '^fs-check: ok' "$LOG" ||
	    fail fs-check "$(lines '^fs-check: FAIL' | tr '\n' ';')"
}

check_abi() {
	local b
	for b in FoxynBSD DragonFly; do
		grep -aF "brand $b: ok" "$LOG" ||
		    fail "ABI note" "a binary with the $b note did not run" || return
	done
}

check_kld() {
	lines '^kld-check: ' || :
	if grep -aq '^kld-check: skipped' "$LOG"; then
		echo "::notice title=kld::no kernel modules in the image, not tested"
		return 0
	fi
	grep -aq '^kld-check: ok' "$LOG" ||
	    fail kld "$(lines '^kld-check: FAIL' | tr '\n' ';')"
}

ALL="rtld rcd identity basics syslogd daemons periodic cxx runtime fs abi kld"
[ "$*" = all ] && set -- $ALL
rc=0
for c; do
	case " $ALL " in *" $c "*) ;; *) echo "unknown check: $c" >&2; exit 2 ;; esac
	echo ">>> check $c"
	"check_$c" || rc=1
done
exit $rc
