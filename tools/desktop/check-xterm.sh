#!/bin/sh
# Smoke-test a non-root X terminal and its pseudoterminal-backed shell.
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 /path/to/xterm" >&2; exit 2; }
terminal=$1
: "${DISPLAY:?set DISPLAY to an X display}"
[ -x "$terminal" ] || { echo "terminal is not executable: $terminal" >&2; exit 2; }
command -v xwininfo >/dev/null 2>&1 || { echo 'missing command: xwininfo' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/foxyn-xterm-check.XXXXXXXX")
pid=
cleanup() {
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || :
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || :
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "xterm-check: FAIL $*" >&2
    [ ! -s "$work/log" ] || tail -20 "$work/log" >&2
    exit 1
}
# Include the unpredictable directory name in the title, so an existing
# terminal cannot satisfy the window check.
title=${work##*/}
"$terminal" -title "$title" -e /bin/sh -c '
    test -t 0 && test -t 1 && test -t 2 || exit 1
    printf "pty-shell-ok\n" > "$1"
    sleep 30
' sh "$work/result" > "$work/log" 2>&1 & pid=$!
i=0
while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || fail 'terminal exited before shell check'
    if [ -f "$work/result" ] && xwininfo -root -tree 2>/dev/null | grep -Fq "\"$title\""; then break; fi
    sleep 1; i=$((i + 1))
done
[ "$i" -lt 20 ] || fail 'terminal window or shell result missing'
[ "$(cat "$work/result")" = pty-shell-ok ] || fail 'shell did not report a terminal on all standard streams'
window=$(xwininfo -root -tree | awk -v title="\"$title\"" 'index($0, title) {print $1; exit}')
[ -n "$window" ] || fail 'cannot identify terminal window'
xwininfo -id "$window" | grep -q 'Map State: IsViewable' || fail 'terminal window is not viewable'
echo 'xterm-check: ok'
