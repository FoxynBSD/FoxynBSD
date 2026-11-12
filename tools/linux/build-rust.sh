#!/bin/sh
#
# build-rust.sh: cross-build Rust (rustc, cargo, the standard library and
# its source, rustfmt, clippy) to run on FoxynBSD, on a Linux host, with
# the tree's sysroot and xcc.  Rust publishes no toolchain that runs on
# DragonFly (x86_64-unknown-dragonfly is a tier 3 target), and DPorts'
# is older than what current Rust programs need (Ladybird: 1.98).
#
# Usage: tools/linux/build-rust.sh	(tools/linux/build.sh rust runs it)
#
# Environment: OBJDIR (as build.sh), RUST_JOBS (default: the CPU count).
#
# The source is the release's rustc-<version>-src.tar.xz from
# static.rust-lang.org, checked by SHA-256: it carries the vendored
# crates and LLVM that the build needs and the tag of rust-lang/rust
# (contrib/rust.README.DRAGONFLY) does not.  x.py builds LLVM and a
# stage 1 compiler for the Linux host, then LLVM, rustc and the tools for
# DragonFly with $OBJDIR/rust/bin/dfly-cc and dfly-c++: xcc, with C++
# against gcc 12's libstdc++ (base /usr/lib/gcc120; gcc 8's is the
# default but too old for LLVM).  Cargo has OpenSSL, curl and libgit2
# built in (cargo-native-static).
#
# Output: $OBJDIR/rust/build/dist/*-x86_64-unknown-dragonfly.tar.xz, the
# usual Rust dist tarballs (install.sh --prefix=...), with prefix
# /System/Library/Rust.  About 1.5 hours on 8 cores, 25 GB of disk.
set -eu

version=1.99.1
sha256=6451598a99e77f07571960f6b21d577399d3a30f33e80cbd2e3a4aae6535d265
prefix=/System/Library/Rust
target=x86_64-unknown-dragonfly

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
SYSROOT=$OBJDIR/sysroot
XCC=$OBJDIR/host/bin/xcc
work=$OBJDIR/rust
src=$work/rustc-$version-src

msg() { echo ">>> $*" >&2; }
die() { echo "build-rust.sh: $*" >&2; exit 1; }

[ -x "$XCC" ] || die "no $XCC: run tools/linux/build.sh tools first"
[ -f "$SYSROOT/usr/lib/libc.so" ] && [ -f "$SYSROOT/usr/lib/gcc120/libstdc++.so" ] ||
    die "no world in $SYSROOT (libc, gcc 12's libstdc++): run tools/linux/build.sh world"
for t in curl sha256sum tar python3 perl make cmake ninja llvm-ar llvm-ranlib cc c++; do
	command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
case $work in *[[:space:]]*) die "OBJDIR must not contain spaces: $OBJDIR" ;; esac

mkdir -p "$work/bin"
tarball=$work/rustc-$version-src.tar.xz
if [ ! -d "$src" ]; then
	if [ ! -f "$tarball" ] || [ "$(sha256sum < "$tarball" | cut -d' ' -f1)" != "$sha256" ]; then
		msg "rust: fetching rustc-$version-src.tar.xz"
		curl -fL --retry 3 -o "$tarball.part" \
		    "https://static.rust-lang.org/dist/rustc-$version-src.tar.xz"
		mv "$tarball.part" "$tarball"
	fi
	[ "$(sha256sum < "$tarball" | cut -d' ' -f1)" = "$sha256" ] ||
	    die "rustc-$version-src.tar.xz: checksum mismatch"
	msg "rust: unpacking"
	tar -xf "$tarball" -C "$work"
fi

# The vendored OpenSSL that cargo builds in (openssl-src) enables the
# devcrypto engine on every BSD, but DragonFly has no /dev/crypto or
# <crypto/cryptodev.h> (removed with opencrypto): configure it with
# no-devcryptoeng on DragonFly.  Cargo checks vendored crates against
# .cargo-checksum.json, so record the changed file's checksum there.
for d in "$src"/vendor/openssl-src-*; do
	[ -f "$d/src/lib.rs" ] || continue
	grep -q 'FoxynBSD: no /dev/crypto' "$d/src/lib.rs" && continue
	python3 -I - "$d" <<'PY' || die "cannot patch ${d##*/}"
import hashlib, json, os, sys
d = sys.argv[1]
f = os.path.join(d, "src", "lib.rs")
s = open(f).read()
# Before the first musl case, among the other configure options.
anchor = '        if target.contains("musl") {\n'
if anchor not in s or "configure.arg" not in s:
    sys.exit(0)  # another layout (openssl-src 1.1.1): not used by cargo
s = s.replace(anchor,
    '        // FoxynBSD: no /dev/crypto (cryptodev) on DragonFly.\n'
    '        if target.contains("dragonfly") {\n'
    '            configure.arg("no-devcryptoeng");\n'
    '        }\n' + anchor, 1)
open(f, "w").write(s)
c = os.path.join(d, ".cargo-checksum.json")
j = json.load(open(c))
j["files"]["src/lib.rs"] = hashlib.sha256(s.encode()).hexdigest()
json.dump(j, open(c, "w"))
PY
done

# The target's C and C++ compilers (and linker).  -fPIC: LLVM and the
# compiler's own libraries go into shared objects (librustc_driver).
cat > "$work/bin/dfly-cc" <<EOF
#!/bin/sh
# Also the linker of rustc and its libraries, which use gcc 12's
# libstdc++ (LLVM): find it before gcc 8's, which has the same soname
# (libstdc++.so.9) but not the newer symbols, at link and at run time.
exec "$XCC" -fPIC -L"$SYSROOT/usr/lib/gcc120" -Wl,-rpath,/usr/lib/gcc120 "\$@"
EOF
cat > "$work/bin/dfly-c++" <<EOF
#!/bin/sh
# gcc 12's libstdc++ (base /usr/lib/gcc120), not the default gcc 8's.
exec "$XCC" --driver-mode=g++ -fPIC -nostdinc++ \\
	-isystem "$SYSROOT/usr/include/c++/12.0" \\
	-L"$SYSROOT/usr/lib/gcc120" -Wl,-rpath,/usr/lib/gcc120 \\
	-fsized-deallocation "\$@"
EOF
chmod 755 "$work/bin/dfly-cc" "$work/bin/dfly-c++"

cat > "$src/bootstrap.toml" <<EOF
# FoxynBSD (tools/linux/build-rust.sh): rustc and cargo for $target,
# cross-built on a Linux host.
change-id = "ignore"
profile = "dist"
[build]
build = "x86_64-unknown-linux-gnu"
host = ["$target"]
target = ["$target"]
build-dir = "$work/build"
extended = true
# cargo with OpenSSL, curl and libgit2 built in (vendored, static), as
# Rust's own dists: the base LibreSSL is private (libprivate_ssl,
# /usr/include/priv), not an interface for programs outside base.
cargo-native-static = true
tools = ["cargo", "src", "rustfmt", "clippy"]
docs = false
vendor = true
locked-deps = true
jobs = ${RUST_JOBS:-$(nproc)}
[install]
prefix = "$prefix"
[llvm]
download-ci-llvm = false
targets = "X86"
experimental-targets = ""
ninja = true
link-shared = false
[rust]
channel = "stable"
debuginfo-level = 0
jemalloc = false
lld = false
llvm-tools = false
[target.$target]
cc = "$work/bin/dfly-cc"
cxx = "$work/bin/dfly-c++"
ar = "$(command -v llvm-ar)"
ranlib = "$(command -v llvm-ranlib)"
linker = "$work/bin/dfly-cc"
[dist]
compression-formats = ["xz"]
EOF

msg "rust: x.py dist ($target; log: $work/dist.log)"
cd "$src"
python3 x.py dist rustc cargo rust-std rust-src rustfmt clippy \
    > "$work/dist.log" 2>&1 || { tail -n 30 "$work/dist.log" >&2; die "x.py dist failed (see $work/dist.log)"; }
ls "$work/build/dist/"*"-$target.tar.xz" >&2
msg "rust: done"
