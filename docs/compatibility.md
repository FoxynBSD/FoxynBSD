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
| Manual page headers | `FoxynBSD General Commands Manual`, ... (`contrib/mdocml/msec.in`) |
| Login tips (`fortune dragonfly-tips`) | tips about the running system say FoxynBSD; the file keeps its name, which `share/skel` dot files use |
| `/usr/Makefile` (`etc/Makefile.usr`): `make src-create`, `src-update` | clone and update FoxynBSD's repository, branch `dev`; `nrelease` uses the same URL |

## What still says DragonFly, and why

| Where | Why it stays |
|-------|--------------|
| The ELF note stamped into every base binary (`lib/csu/common/notes.h`) | Packages and `pkg`'s ABI string (`dragonfly:6.x:x86:64`) depend on it. See "ABI note and packages" below. |
| `__DragonFly__`, `__DragonFly_version` | About 1,300 places in the tree and most third-party code test them. FoxynBSD's own `__FoxynBSD__` (`<sys/cdefs.h>`) and `__FoxynBSD_version` (`<sys/param.h>`) are defined next to them; see CONTRIBUTING.md. |
| `CPE_NAME` in `/etc/os-release` | Vulnerability data is published for the DragonFly code base. |
| `dsynth` (`OPSYS`, `UNAME_s` for port builds) | DPorts tests for `OPSYS=DragonFly` and dsynth checks the name against the binaries' ELF note, so dsynth maps `FoxynBSD` to `DragonFly`. |
| DPorts and the `pkg` bootstrap in `/usr/Makefile` (`dports-create`, `pkg-bootstrap`) | FoxynBSD runs DragonFly's packages (see below). |
| The `.Dx` macro in manual pages ("first appeared in DragonFly 1.0") | It names the DragonFly releases where things appeared: history, not the running system. |
| Login tips that point to DragonFly's web site, mailing list archives and DPorts | Those resources are DragonFly's and apply to FoxynBSD. |
| Copyright and license notices | The BSD license requires keeping them. They never change. |

## ABI note and packages

Every program carries an ELF note naming its ABI vendor. The kernel uses
it to pick how to run the program, and `pkg` reads the note of a base
binary (its `ABI_FILE` setting) to compute the ABI string that selects a
package repository (`dragonfly:6.x:x86:64`).

The kernel recognises two notes, `DragonFly` and `FoxynBSD`
(`sys/kern/imgact_elf.c`, `sys/cpu/x86_64/misc/elf_machdep.c`). Both
select the same system call interface, so a program behaves the same
whichever note it carries. The root image's `/etc/rc` runs one tiny
program of each kind, and CI checks that both print `ok`.

The base system still stamps the `DragonFly` note. Switching it to
`FoxynBSD` would change `pkg`'s ABI string, and DPorts binary packages
would stop installing. The plan:

1. **Now:** the kernel accepts both notes; base binaries say `DragonFly`;
   `pkg` keeps using DPorts packages unchanged.
2. **When FoxynBSD publishes its own package repository** (built with
   `dsynth` from DPorts): switch `NOTE_VENDOR` in
   `lib/csu/common/notes.h` to `FoxynBSD`, and point `pkg` at the
   FoxynBSD repository by default. DragonFly packages stay installable
   by setting `ABI=dragonfly:6.x:x86:64` in `pkg.conf`, because the
   kernel keeps accepting the `DragonFly` note.
3. **Never:** dropping the `DragonFly` note from the kernel. Existing
   binaries and packages must keep running.

Every upstream merge that touches these files has to keep both notes.

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
