#!/bin/sh
#
# Non-interactive boot test: boot the ESP built by `build.sh esp` under
# QEMU (via qemu.sh) and wait for the kernel to reach the root mount
# prompt, which is as far as a kernel-only boot can get.
#
# Usage:
#	tools/linux/boot-test.sh [KERNCONF]
#
# Environment:
#	BOOT_TIMEOUT	seconds to wait (default 300)
#	BOOT_LOG	serial log path (default $OBJDIR/qemu/<KERNCONF>.boot.log)
#
# Exit status: 0 if the expected prompt appeared, 1 otherwise.  The serial
# log is kept either way.

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
CONF=${1:-X86_64_GENERIC}
TIMEOUT=${BOOT_TIMEOUT:-300}
LOG=${BOOT_LOG:-$OBJDIR/qemu/$CONF.boot.log}
# Reaching any of these means the kernel booted and is asking for a root.
SUCCESS='mountroot>|Manual root filesystem specification'

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

OBJDIR=$OBJDIR SERIAL_LOG=$LOG "$SRCDIR/tools/linux/qemu.sh" "$CONF" \
    </dev/null >/dev/null 2>"$LOG.stderr" &
pid=$!

result=1
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
	if grep -Eq "$SUCCESS" "$LOG" 2>/dev/null; then
		result=0
		break
	fi
	if grep -Eq 'panic:|Fatal trap|db>' "$LOG" 2>/dev/null; then
		break
	fi
	kill -0 "$pid" 2>/dev/null || break
	sleep 5
	elapsed=$((elapsed + 5))
done

kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :

if [ "$result" -eq 0 ]; then
	echo ">>> boot test passed: kernel reached the root mount prompt" >&2
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
	[ -s "$LOG.stderr" ] && { echo ">>> qemu stderr:" >&2; cat "$LOG.stderr" >&2; }
fi
exit "$result"
