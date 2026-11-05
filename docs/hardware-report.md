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

Run these as root, so that the programs can read every device:

    # mkdir -p /tmp/hw && cd /tmp/hw
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

This removes the common ones; read the files afterwards all the same
(it also turns four-part version numbers such as `1.21.1.16` into `<ip>`):

    # sed -i '' -E \
        -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g' \
        -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
        -e 's/(serial number|serno|SerialNumber|serial)( *[:=/] *)[^ ,<]+/\1\2<serial>/g' \
        -e 's/(iSerialNumber.*)<[^>]*>/\1<serial>/' \
        -e 's/[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}/<uuid>/g' \
        -e 's/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:\/[^ ]*/<builder>/g' \
        -e "s/$(hostname -s)/<host>/g" \
        *.txt

Share the files, with your notes, in a GitHub issue on the FoxynBSD
repository. Name the machine's maker and model, and the FoxynBSD build
(`uname -v`).
