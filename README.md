<p align="center">
  <img src="docs/media/foxynbsd-mark.svg" alt="FoxynBSD fox mark" width="96">
</p>

<h1 align="center">FoxynBSD</h1>

<p align="center">
  A modern desktop BSD, built on DragonFly BSD and developed in the open on GitHub.
</p>

FoxynBSD is a BSD operating system that aims to work as a ready-to-use
desktop. It starts from the DragonFly BSD source tree: its SMP kernel, the
HAMMER2 filesystem and the DPorts package collection. On top of that,
FoxynBSD adds its own identity, defaults and tooling. Development happens
on GitHub through issues, pull requests and CI ("Forge First"), and the
system can be built from an ordinary Linux machine.

> [!WARNING]
> **FoxynBSD is at an early stage.** There is no installable image yet,
> and the desktop experience is the goal, not something you can use today.
> What works now is building the whole system (kernel, modules, EFI
> boot loader and the complete userland) on Linux and booting it under
> QEMU to a login prompt. See [Status](#status) before you plan anything
> around it.

## Status

| Area | State |
|------|-------|
| Kernel (`X86_64_GENERIC`, `MINI64`, `LINT64`, `VKERNEL64`) and all modules | Build on Linux with gcc (default) or clang |
| EFI boot loader (`loader.efi`) | Builds on Linux |
| Userland (`world`) | The whole world builds on Linux with clang, compiler runtime included |
| Boot under QEMU | The full system boots through `rc.d` to a login prompt from a read-only root image; kernel-only boots stop at `mountroot>`. Checked in CI on every push |
| Linux hosts | Omarchy, Arch Linux, Debian and Ubuntu |
| Installable image / ISO | Not available yet |
| Desktop defaults | Planned |
| FoxynBSD identity | Name, boot menu fox, `os-release`, `__FoxynBSD__`; `uname -s` stays `DragonFly` for compatibility ([docs/compatibility.md](docs/compatibility.md)) |

Plans and progress are tracked in
[issues](https://github.com/FoxynBSD/FoxynBSD/issues), and ideas are
discussed in [Discussions](https://github.com/FoxynBSD/FoxynBSD/discussions).

## Try it: build and boot from Linux

This path was developed on Omarchy (Arch Linux).
Other distributions should work if they provide the same tools.

1. Get the sources, with the submodules in `contrib/` (see
   [`docs/contrib.md`](docs/contrib.md)):

   ```sh
   git clone --recurse-submodules https://github.com/FoxynBSD/FoxynBSD.git
   cd FoxynBSD
   ```

   In a clone made without `--recurse-submodules`, run
   `git submodule update --init --recursive` (`build.sh` says so if a
   submodule is missing).

2. Install the host tools and check them:

   ```sh
   sudo pacman -S --needed base-devel flex bison libbsd libtirpc \
       clang lld libisoburn ncurses qemu-desktop edk2-ovmf
   tools/linux/build.sh doctor
   ```

   On Debian or Ubuntu: `build-essential flex bison libfl-dev libbsd-dev
   libtirpc-dev pkg-config clang lld xorriso ncurses-bin qemu-system-x86
   qemu-system-gui ovmf`.

3. Build the whole system:

   ```sh
   tools/linux/build.sh
   ```

   This builds the kernel, the EFI loader, the whole userland and a root
   image with it. The first run takes a while (the kernel is about ten
   minutes on an 8-core machine, the world longer). Output goes to
   `~/.cache/foxynbsd` (set `OBJDIR` to put it elsewhere).

4. Boot it:

   ```sh
   tools/linux/qemu.sh
   ```

   A QEMU window opens. Wisdom, the FoxynBSD fox, greets you in the boot
   menu, and the boot ends at a `login:` prompt: log in as `root` with no
   password. `halt -p` powers off. `tools/linux/qemu.sh --serial` runs on
   the terminal instead (quit with `Ctrl-A X`), and `--kernel-only` boots
   just the kernel, which stops at the `mountroot>` prompt.

Details, extra commands (`modules`, `subdir`, `env`) and the reasons
behind the compiler wrapper are in [`tools/linux/README.md`](tools/linux/README.md).

## Build on a DragonFly host

The traditional BSD build still works on a DragonFly BSD machine:

```sh
make buildworld && make buildkernel
make installkernel && make installworld && make upgrade
```

See [`README.DragonFly`](README.DragonFly), [`UPDATING`](UPDATING) and
`build(7)` for the full procedure.

## Contributing

Pull requests target the `dev` branch. `master` mirrors upstream DragonFly
BSD and only receives upstream syncs. Commit messages follow the tree's
`area: short summary` style. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. Report security problems as described in
[SECURITY.md](SECURITY.md), not in public issues.

## Relationship to DragonFly BSD

FoxynBSD is an independent derivative of [DragonFly BSD](https://www.dragonflybsd.org/)
and is not affiliated with or endorsed by The DragonFly Project. Upstream
changes are merged regularly. Fixes that are not specific to FoxynBSD are
worth sending upstream as well.

## License

FoxynBSD is distributed under the BSD-style terms in [`COPYRIGHT`](COPYRIGHT).
Individual components under `contrib/` and elsewhere carry their own
licenses. Copyright notices from DragonFly BSD and earlier BSD projects
are kept as the license requires.
