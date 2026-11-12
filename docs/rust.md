# Rust on FoxynBSD

`tools/linux/build.sh rust` (`tools/linux/build-rust.sh`) cross-builds a
Rust toolchain that runs on FoxynBSD, on the Linux build host. Rust
publishes none for DragonFly: `x86_64-unknown-dragonfly` is a tier 3
target. DPorts has Rust 1.85, older than what current programs need; for
example, Ladybird (issue #13's browser) needs 1.98.

## What it builds

Rust 1.99.1 (`contrib/rust`, tag `1.99.1`), from the release's source
tarball, checked by SHA-256. The results are Rust's usual dist tarballs in
`$OBJDIR/rust/build/dist/`, with prefix `/System/Library/Rust`:

| Tarball | Contents |
| --- | --- |
| `rustc-1.99.1-x86_64-unknown-dragonfly` | the compiler, `rustdoc`, LLVM linked in |
| `cargo-1.99.1-x86_64-unknown-dragonfly` | cargo, with OpenSSL 3, curl and libgit2 inside |
| `rust-std-1.99.1-x86_64-unknown-dragonfly` | the standard library for the target |
| `rust-src-1.99.1` | its source (for `-Zbuild-std` and IDEs) |
| `rustfmt-…`, `clippy-…` | the formatter and the linter |

## How

`x.py dist` with `build = x86_64-unknown-linux-gnu` and `host = target =
x86_64-unknown-dragonfly`:

1. It builds LLVM and a stage 1 compiler for the Linux host.
2. It builds LLVM, `rustc` and the tools for DragonFly, with the tree's
   compilers:
   - `dfly-cc` is `xcc`;
   - `dfly-c++` is `xcc` in C++ mode against gcc 12's libstdc++.

The build needs the world in the sysroot (`build.sh world`), the internet
(the source), and on the host `cmake`, `ninja`, `perl` and `llvm-ar`. It
takes about 1.5 hours on 8 cores and 25 GB of disk.

Things found on the way:

- **libstdc++.** LLVM needs gcc 12's libstdc++ (base `/usr/lib/gcc120`).
  gcc 8's, the default, has the same soname (`libstdc++.so.9`) but lacks
  symbols LLVM uses:

  ```
  undefined reference: std::__throw_bad_array_new_length()
  ```

  Both drivers therefore search `/usr/lib/gcc120` first and record it as
  a run path. `librustc_driver.so` needs it in its own `RUNPATH`; the
  executable's does not apply to it.
- **OpenSSL for cargo.** The base LibreSSL is private (`libprivate_ssl`,
  headers in `/usr/include/priv`), not an interface for programs outside
  base. Cargo is built `cargo-native-static`, as Rust's own dists are, with
  OpenSSL, curl and libgit2 inside.
- **`/dev/crypto`.** The vendored OpenSSL enables its `devcrypto` engine
  on every BSD, but DragonFly removed `/dev/crypto` and opencrypto
  (`c1ba328190`, `056e2ccc0b`). The script configures it with
  `no-devcryptoeng` on DragonFly, a change to the vendored `openssl-src`
  crate in the build directory. Cargo checks vendored crates by checksum,
  so the script updates the crate's `.cargo-checksum.json` too.

## Installing

Without bash, which Rust's `install.sh` needs, copy each component's
directory:

```sh
P=/System/Library/Rust; mkdir -p $P
for c in rustc cargo rust-std; do tar xf $c-1.99.1-x86_64-unknown-dragonfly.tar.xz; done
for d in rustc-*/rustc cargo-*/cargo rust-std-*/rust-std-x86_64-unknown-dragonfly; do
	(cd $d && find . ! -name manifest.in | cpio -pdmu $P)
done
export PATH=$P/bin:$PATH
```

## Tested

QEMU (KVM), 2026-11-11, on the desktop image, as the desktop user in the
Gershwin session's terminal:

- `rustc --version`, `cargo --version`: 1.99.1.
- `rustc -O` of a program that joins four threads: it runs
  (`hello from Rust on dragonfly, threads sum 14`).
- `cargo new` with the `itoa` crate from crates.io: cargo fetched it over
  HTTPS (its own OpenSSL), built it and ran it (`itoa says 1999`).

What was checked:

- The dists come from an incremental run of the same configuration that
  `build-rust.sh` writes. Its `bootstrap.toml` was compared with the one
  that build used, and differs only in the header comment.
- A clean run of `build-rust.sh` from nothing was not done here, for lack
  of disk.

## Known issues

- **gold.** `rustc` warns that the gold linker is deprecated: the base `cc`
  links with `ld.gold` by default. Programs build and run; `-C
  link-arg=-fuse-ld=bfd` selects `ld.bfd`, which the base also has.
- **A console message.** While cargo downloads, the kernel prints
  `poll index 0 no-action 0/0 events=00000000 kevpfilt=-1/00000005`. It is
  DragonFly's rate-limited diagnostic for a `pollfd` that asks for no
  events (`sys_generic.c`), which curl passes; it is harmless.
- **Install.** No package or `build.sh desktop` step installs the
  toolchain yet. Ladybird's build will.
