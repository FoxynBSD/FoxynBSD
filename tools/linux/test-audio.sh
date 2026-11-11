#!/bin/sh
#
# A private PipeWire on the Linux host for sound tests: a microphone that
# plays a known tone and a speaker that is recorded, for QEMU's HDA card
# (qemu.sh AUDIO=pipewire).  It does not touch the host's own sound
# server or devices: it runs its own pipewire and WirePlumber, without
# D-Bus and without hardware, in DIR.
#
# Usage:
#	tools/linux/test-audio.sh start DIR [HZ]
#	tools/linux/test-audio.sh stop DIR
#
# start makes DIR (keep its path short: PipeWire's socket must fit in
# 108 bytes), starts the daemons and prints the environment for qemu.sh:
#	PIPEWIRE_RUNTIME_DIR=DIR AUDIO_IN=foxyn-mic AUDIO_OUT=foxyn-speaker
# The microphone (foxyn-mic, a loopback of the sink foxyn-mic-in) plays
# a HZ sine (default 1000) at about -9 dBFS until stop; what reaches the
# speaker is recorded to DIR/speaker.wav (16-bit stereo, 44.1 kHz, like
# QEMU's WAV backend).  stop ends the recording first, so the file is
# complete, then the rest; the logs stay in DIR.
#
# Host packages: pipewire, wireplumber, python3 (Arch: pipewire
# wireplumber python; Debian/Ubuntu: pipewire pipewire-bin wireplumber
# python3).
set -eu

die() { echo "test-audio: $*" >&2; exit 1; }

[ "$#" -ge 2 ] || die "usage: $0 start DIR [HZ] | stop DIR"
cmd=$1 dir=$2 hz=${3:-1000}

stop_pid()
{
	[ -f "$dir/$1.pid" ] || return 0
	pid=$(cat "$dir/$1.pid")
	if kill -"$2" "$pid" 2>/dev/null; then
		tries=0
		while [ "$tries" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
			sleep 0.25
			tries=$((tries + 1))
		done
		kill -KILL "$pid" 2>/dev/null || :
	fi
	rm -f "$dir/$1.pid"
}

case $cmd in
stop)
	[ -d "$dir" ] || die "no $dir"
	# SIGINT: pw-record then writes the WAV header's sizes.
	stop_pid speaker INT
	stop_pid tone TERM
	stop_pid tonegen TERM
	stop_pid wireplumber TERM
	stop_pid pipewire TERM
	exit 0
	;;
start) ;;
*)	die "usage: $0 start DIR [HZ] | stop DIR" ;;
esac

case $hz in
''|*[!0-9]*) die "HZ must be a number" ;;
esac
for tool in pipewire wireplumber pw-play pw-record python3; do
	command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done
[ "${#dir}" -le 90 ] || die "$dir: path too long for PipeWire's socket"
mkdir -p "$dir/wireplumber/wireplumber/wireplumber.conf.d" "$dir/state"
[ ! -e "$dir/pipewire-0" ] || die "$dir: a PipeWire already runs there (stop it first)"

cat > "$dir/pipewire.conf" <<'EOF'
# Written by tools/linux/test-audio.sh.
context.properties = {
    core.daemon = true
    core.name = pipewire-0
    support.dbus = false
    default.clock.rate = 48000
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-access }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
    # The microphone: what is played to foxyn-mic-in comes out of the
    # source foxyn-mic.
    { name = libpipewire-module-loopback
        args = {
            audio.position = [ FL FR ]
            capture.props = {
                node.name = foxyn-mic-in
                media.class = Audio/Sink
            }
            playback.props = {
                node.name = foxyn-mic
                media.class = Audio/Source
            }
        }
    }
]
context.objects = [
    # No hardware: this clocks the graph.
    { factory = spa-node-factory
        args = {
            factory.name = support.node.driver
            node.name = Dummy-Driver
            node.group = pipewire.dummy
            priority.driver = 20000
        }
    }
    { factory = adapter
        args = {
            factory.name = support.null-audio-sink
            node.name = foxyn-speaker
            media.class = Audio/Sink
            audio.position = [ FL FR ]
        }
    }
]
EOF
# WirePlumber links the streams; no hardware monitors, D-Bus or state.
cat > "$dir/wireplumber/wireplumber/wireplumber.conf.d/foxyn-test.conf" <<'EOF'
# Written by tools/linux/test-audio.sh.
wireplumber.profiles = {
  foxyn-test = {
    inherits = [ policy, mixin.systemwide-session, mixin.stateless ]
    support.dbus = disabled
  }
}
EOF
cat > "$dir/tone.py" <<'EOF'
# One second of a sine, 16-bit mono at 48 kHz, written until the reader
# goes away.
import math, struct, sys
hz = int(sys.argv[1])
sec = b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * hz * i / 48000)))
              for i in range(48000))
out = sys.stdout.buffer
try:
    while True:
        out.write(sec)
        out.flush()
except BrokenPipeError:
    pass
EOF

export PIPEWIRE_RUNTIME_DIR="$dir"
unset PIPEWIRE_REMOTE

# start NAME COMMAND...: run in the background, pid in DIR/NAME.pid.
start()
{
	name=$1; shift
	"$@" > "$dir/$name.log" 2>&1 &
	echo $! > "$dir/$name.pid"
}
start pipewire pipewire -c "$dir/pipewire.conf"
tries=0
while [ ! -S "$dir/pipewire-0" ]; do
	tries=$((tries + 1))
	[ "$tries" -lt 40 ] || die "pipewire did not start (see $dir/pipewire.log)"
	sleep 0.25
done
start wireplumber env XDG_CONFIG_HOME="$dir/wireplumber" \
    XDG_STATE_HOME="$dir/state" wireplumber -p foxyn-test
# Its nodes appear once WirePlumber runs; then the tone and the recording.
sleep 2
kill -0 "$(cat "$dir/wireplumber.pid")" 2>/dev/null ||
    die "wireplumber did not start (see $dir/wireplumber.log)"
rm -f "$dir/tone.fifo"
mkfifo "$dir/tone.fifo"
python3 -I "$dir/tone.py" "$hz" > "$dir/tone.fifo" 2> "$dir/tonegen.log" &
echo $! > "$dir/tonegen.pid"
pw-play --raw --rate 48000 --channels 1 --format s16 --target foxyn-mic-in - \
    < "$dir/tone.fifo" > "$dir/tone.log" 2>&1 &
echo $! > "$dir/tone.pid"
rm -f "$dir/speaker.wav"
start speaker pw-record --target foxyn-speaker -P '{ stream.capture.sink = true }' \
    --rate 44100 --channels 2 --format s16 "$dir/speaker.wav"
sleep 1
for name in tone speaker; do
	kill -0 "$(cat "$dir/$name.pid")" 2>/dev/null ||
	    die "$name did not start (see $dir/$name.log)"
done
echo "PIPEWIRE_RUNTIME_DIR=$dir AUDIO_IN=foxyn-mic AUDIO_OUT=foxyn-speaker"
