#!/bin/sh
#
# Non-interactive boot test: boot the ESP built by `build.sh esp` under
# QEMU (via qemu.sh) and wait for the kernel to reach the root mount
# prompt, which is as far as a kernel-only boot can get.  With --root, also
# attach the root image from `build.sh rootfs` and wait for the login
# prompt that getty prints once /etc/rc has finished.
#
# Usage:
#	tools/linux/boot-test.sh [--root] [KERNCONF]
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
ROOTARG=
if [ "${1:-}" = "--root" ]; then ROOTARG=--root; shift; fi
CONF=${1:-X86_64_GENERIC}
TIMEOUT=${BOOT_TIMEOUT:-300}
LOG=${BOOT_LOG:-$OBJDIR/qemu/$CONF.boot${ROOTARG:+-root}.log}
FAIL='panic:|Fatal trap|db>'
if [ -n "$ROOTARG" ]; then
	# getty's prompt, after /etc/rc ran and init went multi-user.
	SUCCESS='login: '
	FAIL="$FAIL|mountroot>|Manual root filesystem specification"
else
	# Reaching any of these means the kernel booted and asks for a root.
	SUCCESS='mountroot>|Manual root filesystem specification'
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

OBJDIR=$OBJDIR SERIAL_LOG=$LOG "$SRCDIR/tools/linux/qemu.sh" $ROOTARG "$CONF" \
    </dev/null >/dev/null 2>"$LOG.stderr" &
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

kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :

if [ "$result" -eq 0 ]; then
	if [ -n "$ROOTARG" ]; then
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
