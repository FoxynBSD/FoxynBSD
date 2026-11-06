#!/bin/sh
# Exercise the documented report collection and redaction in a disposable VM.
set -u
umask 077
dir=$(mktemp -d /tmp/hardware-report.XXXXXXXX) || exit 1
trap 'rm -rf "$dir"' EXIT HUP INT TERM
cd "$dir" || exit 1

inxi -Fxxxz -c 0 > inxi.txt 2>&1 || exit 1
pciconf -lv > pciconf.txt 2>&1 || exit 1
usbconfig > usb.txt 2>&1 || exit 1
usbconfig dump_device_desc >> usb.txt 2>&1 || exit 1
kldstat > kldstat.txt 2>&1 || exit 1
devinfo -v > devinfo.txt 2>&1 || exit 1
cp /var/run/dmesg.boot dmesg.txt || exit 1
uname -a > uname.txt || exit 1
sysctl hw.model hw.ncpu hw.physmem >> uname.txt || exit 1
printf 'Serial Number: SYNTHETIC-SECRET-123\n' > synthetic.txt

ruby /root/tests/hardware-redact.rb >/dev/null 2>&1 || exit 1
ruby -e '
  files = Dir.glob("*.txt")
  abort unless files.length == 8
  files.each do |file|
    out = File.join("share", file)
    abort unless File.file?(out) && (File.stat(out).mode & 0777) == 0600
  end
  abort unless File.read("synthetic.txt").include?("SYNTHETIC-SECRET-123")
  filtered = File.read("share/synthetic.txt")
  abort if filtered.include?("SYNTHETIC-SECRET-123")
  abort unless filtered.include?("<serial>")
' || exit 1
echo 'pkg-check: filtered hardware report ok'
