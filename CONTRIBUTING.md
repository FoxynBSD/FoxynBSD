# Contributing to FoxynBSD

FoxynBSD is developed on GitHub ("Forge First"). Bugs, plans and design
discussions live in issues and Discussions, and every change lands through
a pull request that CI has checked.

## Branches

| Branch   | Purpose |
|----------|---------|
| `dev`    | Default branch. All FoxynBSD work lands here through pull requests. |
| `master` | Mirror of upstream DragonFly BSD. Only receives upstream syncs; never commit FoxynBSD work to it. |

Upstream changes reach `dev` by merging `master` into `dev` after a sync.

## Before you start

- **Bugs and small fixes:** open a pull request directly, or file an issue
  first if you are not sure it is a bug.
- **Larger changes** (new features, defaults, anything touching the
  system identity or ABI): open an issue or a Discussion first, so the
  approach can be agreed before you write the code.
- **Security problems:** do not open a public issue. See [SECURITY.md](SECURITY.md).

## Building and testing

From a Linux host (see [`tools/linux/README.md`](tools/linux/README.md)):

```sh
tools/linux/build.sh kernel     # kernel
tools/linux/build.sh modules    # kernel modules
tools/linux/build.sh loader     # EFI loader
tools/linux/build.sh esp && tools/linux/qemu.sh   # boot under QEMU
```

On a DragonFly host, the usual `make buildworld` / `make buildkernel` flow
also works.

CI builds the kernel, the modules, the EFI loader and a minimal userland
on every pull request, and boots them under QEMU twice: kernel-only (to
`mountroot>`) and from a root image (to a shell). `dev` only accepts
changes through pull requests whose three checks (`Kernel, loader and
boot tree`, `Kernel modules`, `Userland and boot to a shell`) are green.
Repository administrators can push to `dev` directly; that is for
maintenance work, and CI still runs on those pushes.

## Commits

Follow the existing style in the tree:

```
area: short imperative summary

Explain what was wrong and why this change fixes it. Wrap at about 72
columns. Mention upstream commits or bug reports when relevant.
```

`area` is the component you changed, for example `kernel`, `hammer2`,
`config(8)`, `tools/linux` or `drm/radeon`. Keep unrelated changes in
separate commits.

## FoxynBSD or DragonFly in code

FoxynBSD keeps DragonFly's API and ABI. The compiler predefines
`__DragonFly__`, and `<sys/param.h>` defines `__DragonFly_version`. Keep
using them for anything that is true of DragonFly too.

For code that is specific to FoxynBSD, use the FoxynBSD macros:

- `__FoxynBSD__` is defined by `<sys/cdefs.h>`, which every system header
  includes. Test it after including a system header.
- `__FoxynBSD_version` (`<sys/param.h>`) counts changes specific to
  FoxynBSD that programs can see. When you add one, bump it by one and
  describe the change in the list above its definition.

```c
#include <sys/param.h>

#if defined(__FoxynBSD__) && __FoxynBSD_version >= 1
/* FoxynBSD-only code */
#endif
```

Do not replace or remove `__DragonFly__` checks. See
[docs/compatibility.md](docs/compatibility.md) for what else keeps the
DragonFly name.

## Code style

Follow the surrounding code. Kernel and base system C code uses the
BSD style described in `style(9)` (`share/man/man9/style.9`).

## Copyright and licensing

- Keep existing copyright and license notices. Never remove or rewrite
  a DragonFly, FreeBSD, NetBSD, OpenBSD or other upstream notice, even
  when rebranding text around it.
- New files should carry a BSD-style license compatible with
  [`COPYRIGHT`](COPYRIGHT).
- Code taken from other projects must keep its original notice, and its
  license must be compatible. Do not bring GPL code into the kernel.

## Sending fixes upstream

If a fix is not specific to FoxynBSD, consider also sending it to
DragonFly BSD. Keeping the difference from upstream small makes every
future sync cheaper.
