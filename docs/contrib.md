# Third-party software in `contrib/`

`contrib/` holds the third-party sources that the base system builds:
compilers, libraries and programs from other projects. The build glue
(the BSD makefiles, `config.h`, the options) lives in the directory that
builds the program, for example `usr.bin/less` for `contrib/less`.

A package is in `contrib/` in one of two forms.

| Form | What `contrib/<name>` is | Record |
|------|--------------------------|--------|
| Vendored | A copy of the upstream sources, often trimmed and sometimes patched, committed to this repository | `contrib/<name>/README.DRAGONFLY` (and `README.DELETED`) |
| Submodule | A git submodule: upstream's own repository, pinned to a release tag | `contrib/<name>.README.DRAGONFLY`, next to it |

The 49 packages that came from DragonFly BSD are vendored. New imports
are submodules where they can be. A vendored package can move to a
submodule later, one at a time.

## Getting the sources

Clone with the submodules:

```sh
git clone --recurse-submodules https://github.com/FoxynBSD/FoxynBSD.git
```

In a clone that was made without them, and after a pull that moves one:

```sh
git submodule update --init --recursive
```

`tools/linux/build.sh` and `make buildworld` check this first, with
`tools/linux/check-submodules.sh -r`. They stop with that command if a
submodule is missing, is at a commit other than the one the tree
records, or has local changes. `build.sh doctor` reports the same
problems. On a DragonFly host, `make src-create` and `make src-update`
in `/usr` fetch the submodules too.

## Rules for a submodule

- It goes directly under `contrib/` and points at upstream's own
  repository (`url` in `.gitmodules`, with `shallow = true`), checked out
  at a release tag. Do not point it at a branch. If a fix that the base
  needs is only on upstream's main branch, pin that commit and say why
  in the README, then move to the next release tag when it comes out.
- Nothing in it is changed, and the build never writes into it. What
  `configure` would generate, and any portability code (a missing libc
  function, for example), goes in the build directory. For Cronie,
  `usr.sbin/cron/include/config.h` and `usr.sbin/cron/cron/compat.c` do
  this.
- Files the base does not need stay in the submodule and are just not
  built. Generated files such as man pages with this system's paths are
  made in the object directory.
- If a change to upstream's code cannot be avoided, keep the package
  vendored or send the change upstream first. A submodule has no place for
  local patches. A fork under the FoxynBSD organization is the last
  resort.
- `contrib/<name>.README.DRAGONFLY` records `url =`, `tag =`, `commit =`
  and `date =`. It also says what is built and from where, what is not
  built, the licence, and what to check on an upgrade. The lint workflow
  runs `tools/linux/check-submodules.sh`, which checks that the
  `commit =` line is the commit the tree records and that `url =` matches
  `.gitmodules`.
- The licence of every file that is built must be compatible with the
  base (BSD, ISC, MIT and similar). A GPL part of a package can stay in
  the submodule if it is not built. Say so in the README.

## Adding a package as a submodule

```sh
git submodule add https://example.org/upstream/pkg.git contrib/pkg
git config -f .gitmodules submodule.contrib/pkg.shallow true
git -C contrib/pkg checkout <release tag>
$EDITOR contrib/pkg.README.DRAGONFLY      # url, tag, commit, date, ...
git add .gitmodules contrib/pkg contrib/pkg.README.DRAGONFLY
tools/linux/check-submodules.sh -r
```

Then write the build glue in the directory that builds it. In its
`Makefile.inc` or `Makefile`, stop with a clear message if the sources are
not there, as `usr.sbin/cron/Makefile.inc` does:

```make
.if !exists(${CRONIE}/src/cron.c)
.error contrib/cronie is a git submodule and is not checked out: run "git submodule update --init contrib/cronie"
.endif
```

## Upgrading a submodule

```sh
git -C contrib/pkg fetch --tags
git -C contrib/pkg checkout <new tag>
$EDITOR contrib/pkg.README.DRAGONFLY      # tag, commit, date
git add contrib/pkg contrib/pkg.README.DRAGONFLY
```

Before committing, check upstream's build files for new sources and new
`configure` options. The README lists what to look at.

## Current submodules

| Path | Upstream | Tag | Built in |
|------|----------|-----|----------|
| `contrib/cronie` | <https://github.com/cronie-crond/cronie> | `cronie-1.7.2` + 35 (master, for the `crontab` backup fix) | `usr.sbin/cron`: `cron(8)`, `crontab(1)` |
