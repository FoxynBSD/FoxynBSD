# Removable media: USB sticks and SD cards on the desktop

`foxyn-desktop` installs vermaden's `automount` (`contrib/automount`, the
devd-based automounter Gershwin's FreeBSD images use) with
`tools/desktop/install-automount.sh`. When a USB stick or SD card with a
file system it knows is plugged in:

- `devd` runs `automount` for the new device nodes (`DEVFS` `CREATE`
  for `da*` and `mmcsd*`).
- `automount` finds the file system with `fstyp(8)` and mounts it as the
  desktop user on `/media/<label>` (`NICENAMES`, `MOUNT_AS_USER`):
  `nosuid` and `nodev`, which the kernel forces for a user's mount. FAT
  files belong to the user.
- Workspace shows the volume on the desktop. Its menu's **Eject**
  unmounts it with a plain `umount` as the user: a user may unmount
  what the user mounted.
- When the stick is pulled out, whether it was ejected first or not,
  `automount` unmounts it and forgets it.

| File | What |
| --- | --- |
| `/usr/local/sbin/automount` | the script, with `tools/desktop/patches/automount-dragonfly.txt` (DragonFly's autofs has its own `/usr/sbin/automount`) |
| `/usr/local/etc/devd/automount.conf` | `tools/desktop/automount-devd.conf` |
| `/usr/local/etc/automount.conf` | the desktop user, its group, `/media`, `NICENAMES=YES`, `MOUNT_AS_USER=YES`; kept when it exists |

## What DragonFly needed

The patch (`automount-dragonfly.txt`):

- **File system type.** It comes from `fstyp(8)`: `file -s` on a disk
  device blocked.
- **Commands.** `mount_msdos(8)`, and `fsck(8)` for UFS.
- **`reap`.** A disk that goes away keeps its device nodes while it is
  mounted, so no `DEVFS` `DESTROY` comes. devd runs `automount umassN
  reap` when a USB mass storage device detaches. `reap` detaches every
  mounted device that no longer reads.
- **`MOUNT_AS_USER`.** The device node and the mount directory go to the
  user, and the mount runs as the user, with `vfs.usermount=1`. For FAT,
  the kernel's character set tables (`-D`, `-L`) can only be loaded by
  root: a read-only mount by root on a scratch directory loads them,
  once a boot.

The kernel needed two changes:

- **`dsclose()` after the disk went away.** Pulling out a mounted stick
  and unmounting it afterwards paged fault in `dsclose()`: once
  `disk_invalidate()` has freed the slices, `diskclose()` passes a NULL
  `d_slice`. `dsclose()` now returns when there are none; `dsisopen()`
  already did.
- **Opening a disk as a user.** Since 2023 (`71e85ce439`, "Disable disk
  media access for RESTRICTEDROOT environments"), `diskopen()` and
  `daopen()` refused every non-root process: `caps_priv_check_self()`
  also tests that the caller is root. The commit was meant for
  RESTRICTEDROOT environments such as jails. Both now pass
  `__SYSCAP_NOROOTTEST`, as `syscons` does:
  - RESTRICTEDROOT environments are still refused;
  - for everyone else the device node's permissions decide again;
  - a user still cannot read the system disk (`root:operator`, 0640).

  This differs from DragonFly's upstream. Without it the user cannot
  mount the stick, and so cannot eject it without privileges: Workspace
  would fall back to `sudo`, which is not installed.

## Tests

`boot-test.sh --desktop` (when the host has `mkfs.fat`) plugs a 64 MB
stick into QEMU's xHCI controller through the monitor. The stick has a
FAT32 file system labelled `FOXYNUSB` on an MBR slice, so it shows up
as `daNs1`. `desktop-session media` then runs:

1. **mount:** within 30 s, `/media/FOXYNUSB` is mounted by the desktop
   user; the user writes a file on it.
2. **eject:** Eject in the volume's menu on Workspace's desktop
   unmounts it. The stick is then pulled out.
3. **mount again:** the stick is plugged in again; it is mounted again,
   with the file.
4. **gone:** the stick is pulled out while mounted; within 30 s it is
   unmounted (`reap`), and the kernel survived.

## Limits

- Only file systems DragonFly mounts itself are supported: FAT, UFS,
  cd9660 and ext2. The script's FUSE-based ones (exFAT, NTFS, ext4,
  HFS, MTP phones) need DPorts' FUSE file systems and were not tried.
- A stick pulled out without Eject may lose data that was not yet
  written: `automount` can only unmount it afterwards.
- After a stick is pulled out, DragonFly's CAM keeps its `/dev/daN`
  nodes for a while. A new one gets the next number.
- Only tested in QEMU, with its USB storage device.
