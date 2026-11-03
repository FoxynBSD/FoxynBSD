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
> What works now is building the kernel, its modules and the EFI boot
> loader on Linux, and booting that kernel under QEMU. See [Status](#status) before you plan anything around it.

## Status

| Area | State |
|------|-------|
| Kernel (`X86_64_GENERIC`) and all modules | Build on Linux with GCC 16 |
| EFI boot loader (`loader.efi`) | Builds on Linux |
| Boot under QEMU | Kernel boots to the root prompt (`mountroot>`), checked in CI on every push |
| Userland (`world`) | Builds only on a DragonFly host; Linux build in progress |
| Installable image / ISO | Not available yet |
| Desktop defaults | Planned |
| FoxynBSD identity (name, `uname`, ABI) | In progress, tracked in issues |

Plans and progress are tracked in
[issues](https://github.com/FoxynBSD/FoxynBSD/issues), and ideas are
discussed in [Discussions](https://github.com/FoxynBSD/FoxynBSD/discussions).

## Try it: build and boot the kernel from Linux

This path was developed on Omarchy (Arch Linux).
Other distributions should work if they provide the same tools.

1. Install the host tools:

   ```sh
   sudo pacman -S --needed base-devel flex bison libbsd qemu-base edk2-ovmf
   ```

2. Build the kernel and the EFI loader, and assemble a boot tree:

   ```sh
   tools/linux/build.sh kernel
   tools/linux/build.sh loader
   tools/linux/build.sh esp
   ```

   The kernel takes a few minutes on an 8-core machine. Output goes to
   `~/.cache/foxynbsd` by default.

3. Boot it under QEMU on the serial console:

   ```sh
   tools/linux/qemu.sh
   ```

   No root filesystem is attached yet, so a successful kernel-only boot
   ends at the `mountroot>` prompt. Quit with `Ctrl-A X`.

   To watch the boot in a QEMU window on the video console instead of the
   terminal, run `tools/linux/qemu.sh --gui`.

Details, extra commands (`modules`, `sysroot`, `env`) and the reasons
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
