# FoxynBSD and DragonFly compatibility

FoxynBSD is derived from DragonFly BSD. It has its own name, but it keeps
DragonFly's binary interface, so DragonFly programs and DPorts packages
keep working. This page lists where the system says "FoxynBSD", where it
deliberately still says "DragonFly", and how to get the DragonFly answer
when a tool needs it.

## What says FoxynBSD

| Where | Value |
|-------|-------|
| `uname -s`, `sysctl kern.ostype` | `FoxynBSD` (`sys/conf/newvers.sh`) |
| Kernel banner, `uname -v` | `FoxynBSD 6.5-DEVELOPMENT #...` |
| `/etc/os-release` | `ID=foxynbsd`, `ID_LIKE=dragonfly`, `NAME=FoxynBSD` |
| `/etc/motd` first line | `FoxynBSD ...`; `rc.d/motd` also still updates a motd that starts with `DragonFly` |
| Release snapshot names (`vers.txt`) | `FoxynBSD-<machine>-<date>-...` |

## What still says DragonFly, and why

| Where | Why it stays |
|-------|--------------|
| The ELF note in every binary (`lib/csu/common/notes.h`) and the kernel's ELF brand | Packages, `pkg`'s ABI string (`dragonfly:6.x:x86:64`) and existing binaries depend on it. Changing it is issue #5. |
| `__DragonFly__`, `__DragonFly_version` | About 1,300 places in the tree and most third-party code test them. FoxynBSD adds its own macros next to them (issue #4). |
| `CPE_NAME` in `/etc/os-release` | Vulnerability data is published for the DragonFly code base. |
| `dsynth` (`OPSYS`, `UNAME_s` for port builds) | DPorts tests for `OPSYS=DragonFly` and dsynth checks the name against the binaries' ELF note, so dsynth maps `FoxynBSD` to `DragonFly`. |
| Copyright and license notices | The BSD license requires keeping them. They never change. |

## Software that checks `uname -s`

Build scripts that recognise the system by `uname -s` (autoconf's
`config.guess`, CMake's `CMAKE_SYSTEM_NAME`, hand-written scripts) see
`FoxynBSD` and may not know it. Until they do, give them the DragonFly
answer:

- for one command: `UNAME_s=DragonFly ./configure`
- for the whole system: `varsym -s UNAME_s=DragonFly` (see `uname(1)` and
  `varsym(1)`; remove it with `varsym -su UNAME_s`)

Port builds through `dsynth` already get `DragonFly`.

### Known places that test for DragonFly by name

These compare against the string `DragonFly` and are reviewed as part of
the identity work (issue #1):

- `bin/csh/csh/host.defs`: compile-time `hosttype`/`ostype` values for
  csh's `$HOSTTYPE` and `$OSTYPE`.
- `nrelease/root/etc/dhcpd.conf`: PXE vendor class `DragonFly` (issue #2).
- `usr.sbin/makefs/cd9660.c`: ISO system identifier.
- `usr.sbin/mergemaster/mergemaster.sh`: `CVS_ID_TAG=DragonFly`, the
  `$DragonFly$` version-control tag, which stays.
