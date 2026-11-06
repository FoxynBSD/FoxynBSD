# Hardware reports

A hardware report records what a machine has and what FoxynBSD does with
it: which devices it found, which driver took each one, and whether that
works. Reports from many machines are what a hardware compatibility list
is built from. This page says how to make one and what to remove before
sharing it.

## What you need

A FoxynBSD system with a writable root (an installed disk, not the live
CD) and a network connection. inxi and Perl come from DragonFly's
packages; they are not part of the base system:

    # make -C /usr pkg-bootstrap      # once: installs pkg
    # pkg install inxi                # brings Perl

The raw inventory below uses only base programs and works without them.

## Making the report

Run these as root, so that the programs can read every device. The first
command creates a new private directory; stop if it fails. The `umask`
also makes files created by this shell private.

    # report_dir=$(mktemp -d /tmp/hw.XXXXXXXX) && cd "$report_dir" && umask 077
    # inxi -Fxxxz -c 0 > inxi.txt 2>&1
    # pciconf -lv > pciconf.txt
    # usbconfig > usb.txt 2>&1; usbconfig dump_device_desc >> usb.txt 2>&1
    # kldstat > kldstat.txt
    # devinfo -v > devinfo.txt
    # cp /var/run/dmesg.boot dmesg.txt
    # uname -a > uname.txt; sysctl hw.model hw.ncpu hw.physmem >> uname.txt

inxi's summary is easy to read; the other files are the authoritative
record. `pciconf -lv` gives each PCI device's vendor and device IDs
(`vendor=0x8086 device=0x9a49`) and the driver attached to it (`vga0@`,
`none3@` when no driver took it); `usbconfig` does the same for USB;
`kldstat` lists the loaded kernel modules; `dmesg.txt` has the kernel's
messages from boot, including devices that failed to attach.

Then note, for each device, whether it works: the display, keyboard and
touchpad, wired and wireless network, sound, suspend and resume, USB
ports, card reader, webcam. Write **unknown** for what you did not test
and for what inxi does not report: inxi's support for the BSDs is
incomplete (under QEMU it shows no disk and no graphics device), so a
missing line in its output does not mean the hardware is unsupported.

## Before you share it

`inxi -z` hides MAC and IP addresses and some serial numbers, but the
other files are unfiltered. These identify your machine or network:

* serial numbers: disks (`serial number:` and `serno` in dmesg,
  `/dev/serno/...`), the system board and chassis, USB devices
  (`iSerialNumber`);
* MAC addresses (`ether xx:xx:xx:xx:xx:xx` in dmesg) and IP addresses;
* the host name (in `uname.txt` and dmesg) and user names;
* on a kernel you built yourself, your user name, host name and
  directory (`you@host:/path/...` in `uname -v` and dmesg);
* UUIDs of disks and partitions.

The following uses Ruby from base to make filtered copies in a new
`share` directory, leaving the originals in place. Run it from the report
directory created above (`$report_dir`).
It filters common IPv4 and IPv6 addresses, MAC addresses, UUIDs, serial
numbers, the current host name and kernel builder paths. It cannot identify
every private value: **read every copy before sharing it** and remove any
remaining identifiers. Four-part version numbers can be mistaken for IPv4
addresses; restore those by hand when they are needed for diagnosis.

    ruby <<'RUBY'
    require 'ipaddr'
    require 'socket'

    files = Dir.glob('*.txt')
    abort 'No report files found' if files.empty?
    host = Socket.gethostname
    abort 'Cannot determine host name' if host.empty?
    names = [host, host.split('.').first].uniq.sort_by { |name| -name.length }
    host_pattern = /(?<![A-Za-z0-9._-])(?:#{names.map { |name| Regexp.escape(name) }.join('|')})(?:\.[A-Za-z0-9_-]+)*(?![A-Za-z0-9._-])/i
    Dir.mkdir('share', 0700) # Refuse to overwrite an existing report.

    files.each do |file|
      text = File.binread(file)
      text.gsub!(/(iSerialNumber[^\r\n<]*?)<[^>\r\n]*>/i, '\\1<serial>')
      text.gsub!(/((?:serial[ \t]*number|serial|serno)[ \t]*[:=\/][ \t]*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,<]+)/i, '\\1<serial>')
      text.gsub!(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i, '<uuid>')
      text.gsub!(/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:\/[^\s]+/, '<builder>')
      text.gsub!(/(?<![A-Za-z0-9_.])[0-9a-f:.]*:[0-9a-f:.]+(?![A-Za-z0-9_.])/i) do |candidate|
        address = candidate.sub(/\.+\z/, '')
        punctuation = candidate[address.length..]
        begin
          IPAddr.new(address).ipv6? ? "<ip>#{punctuation}" : candidate
        rescue IPAddr::InvalidAddressError
          candidate
        end
      end
      text.gsub!(/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/i, '<mac>')
      text.gsub!(/[0-9]{1,3}(?:\.[0-9]{1,3}){3}/, '<ip>')
      text.gsub!(host_pattern, '<host>')
      File.open(File.join('share', file), 'wb', 0600) { |out| out.write(text) }
    end
    RUBY

Share only the reviewed copies from `share`, with your notes, in a GitHub
issue on the FoxynBSD repository. Name the machine's maker and model, and
the FoxynBSD build (`uname -v`).
