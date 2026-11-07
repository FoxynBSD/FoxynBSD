#!/bin/sh
# Run only on a disposable X display with no existing window manager.
set -eu

[ "$#" -eq 2 ] || { echo "usage: $0 WindowManager TextEdit" >&2; exit 2; }
wm=$1
app=$2
: "${DISPLAY:?set DISPLAY to a disposable X display}"
[ -x "$wm" ] && [ -x "$app" ] || { echo 'window manager or application is not executable' >&2; exit 2; }
for tool in xprop xwininfo mktemp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing command: $tool" >&2; exit 2; }
done
existing=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || :)
case $existing in
    *'window id #'*) echo 'a window manager is already advertised on this display' >&2; exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/foxyn-wm-check.XXXXXXXX")
wm_pid= app_pid=
cleanup() {
    [ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null || :
    [ -z "$wm_pid" ] || kill "$wm_pid" 2>/dev/null || :
    [ -z "$app_pid" ] || wait "$app_pid" 2>/dev/null || :
    [ -z "$wm_pid" ] || wait "$wm_pid" 2>/dev/null || :
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "wm-check: FAIL $*" >&2
    [ ! -s "$work/wm.log" ] || tail -20 "$work/wm.log" >&2
    exit 1
}
printf 'FoxynBSD window manager test\n' > "$work/wm-check.txt"
"$wm" -dc > "$work/wm.log" 2>&1 & wm_pid=$!
i=0
while [ "$i" -lt 30 ]; do
    kill -0 "$wm_pid" 2>/dev/null || fail 'window manager exited during startup'
    if xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id # 0x[1-9a-fA-F]'; then break; fi
    sleep 1; i=$((i + 1))
done
[ "$i" -lt 30 ] || fail 'window manager did not advertise itself'
"$app" "$work/wm-check.txt" > "$work/app.log" 2>&1 & app_pid=$!
i=0
while [ "$i" -lt 30 ]; do
    kill -0 "$wm_pid" 2>/dev/null || fail 'window manager exited after application launch'
    kill -0 "$app_pid" 2>/dev/null || fail 'application exited during startup'
    if xwininfo -root -tree 2>/dev/null | grep -q 'wm-check.txt'; then break; fi
    sleep 1; i=$((i + 1))
done
[ "$i" -lt 30 ] || fail 'application window did not appear'
# Allow expose and titlebar painting to run after the window appears.
sleep 5
kill -0 "$wm_pid" 2>/dev/null || fail 'window manager exited after application window appeared'
kill -0 "$app_pid" 2>/dev/null || fail 'application exited after its window appeared'
echo 'wm-check: ok'
