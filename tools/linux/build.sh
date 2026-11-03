#!/bin/sh
#
# Build FoxynBSD pieces on a Linux host (developed on Omarchy / Arch Linux).
#
# This does not use the top-level Makefile's buildworld/buildkernel flow,
# which expects a DragonFly host.  Instead it bootstraps the handful of
# host tools the kernel build needs (bmake, config(8), mkdep, file2c,
# uudecode) with the Linux compiler, then drives sys/ directly.
#
# Usage:
#	tools/linux/build.sh tools
#	tools/linux/build.sh kernel [KERNCONF]	(default X86_64_GENERIC)
#	tools/linux/build.sh modules [KERNCONF]
#	tools/linux/build.sh sysroot		(stage DragonFly headers)
#	tools/linux/build.sh libc		(userland: csu + libc, with clang)
#	tools/linux/build.sh base		(rtld, init, sh, core utilities)
#	tools/linux/build.sh rootfs		(minimal root tree and root.iso)
#	tools/linux/build.sh subdir DIR...	(build and install world dirs)
#	tools/linux/build.sh loader		(EFI loader.efi)
#	tools/linux/build.sh esp [KERNCONF]	(boot tree for QEMU;
#					 WITH_MODULES=1 to add .ko)
#	tools/linux/build.sh env		(print an env for manual make runs)
#
# Environment:
#	OBJDIR	output directory (default ${XDG_CACHE_HOME:-~/.cache}/foxynbsd)
#	JOBS	parallel jobs (default: nproc)
#	HOST_CC, HOST_CFLAGS	compiler and flags for the host tools (gcc, -O2)
#
# Host packages needed (Arch/Omarchy):
#	base-devel flex bison libbsd
#	clang lld libtirpc		(for the userland: sysroot, libc)

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
HOSTBIN=$OBJDIR/host/bin
HOSTOBJ=$OBJDIR/host/obj
# Compiler and flags for the host tools themselves (not the kernel).
HOST_CC=${HOST_CC:-gcc}
HOST_CFLAGS=${HOST_CFLAGS:--O2}
SYSROOT=$OBJDIR/sysroot

die() { echo "build.sh: $*" >&2; exit 1; }
msg() { echo ">>> $*" >&2; }

need() {
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
	done
}

# Wrapper around the host gcc so it behaves like DragonFly's base
# compiler for kernel purposes: no PIE/CET defaults, no Linux predefines,
# __DragonFly__ defined.  Warnings introduced by compilers newer than the
# in-tree gcc120 stay warnings instead of failing -Werror.  Format strings
# that are not literals are always an error, as with Debian/Ubuntu gcc, so
# every Linux host catches the same problems as CI.
write_cc_wrapper() {
	local hostgcc
	hostgcc=$(command -v "${HOST_GCC:-gcc}") || die "no host gcc"
	cat > "$HOSTBIN/cc" <<EOF
#!/bin/sh
exec "$hostgcc" \\
	-fno-pie -fno-pic -no-pie \
	-Wl,--no-as-needed -Wl,-z,lazy -Wl,-z,norelro \
	-fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE \
	-U__linux__ -U__linux -Ulinux -U__gnu_linux__ -D__DragonFly__ \
	-Wno-error=dangling-pointer -Wno-error=enum-int-mismatch \
	-Wno-error=maybe-uninitialized -Wno-error=array-bounds \
	-Wformat -Werror=format-security \
	"\$@"
EOF
	chmod 755 "$HOSTBIN/cc"
}

build_bmake() {
	local o=$HOSTOBJ/bmake v
	mkdir -p "$o"
	v=$(sed -n 's/^_MAKE_VERSION=//p' "$SRCDIR/contrib/bmake/VERSION")
	# The in-tree config.h was generated on DragonFly; drop what glibc lacks.
	sed -e 's|^#define HAVE_RANLIB_H 1|/* no ranlib.h */|' \
	    -e 's|^#define HAVE_DECL_SYS_SIGLIST 1|#define HAVE_DECL_SYS_SIGLIST 0|' \
	    "$SRCDIR/usr.bin/bmake/config.h" > "$o/config.h"
	srcs=""
	for f in arch buf compat cond dir for hash job lst main make \
	    make_malloc meta metachar parse str suff targ trace util var \
	    stresep; do
		srcs="$srcs $SRCDIR/contrib/bmake/$f.c"
	done
	$HOST_CC $HOST_CFLAGS -w -I"$o" -I"$SRCDIR/contrib/bmake" \
	    -DHAVE_CONFIG_H -DNO_PWD_OVERRIDE -DUSE_META \
	    -DMAKE_VERSION="\"$v\"" \
	    -D_PATH_DEFSYSPATH="\"$SRCDIR/share/mk\"" \
	    -DDFVER="\"600000\"" -DOSREL="\"6.0\"" \
	    -DMACHINE="\"x86_64\"" -DMACHINE_ARCH="\"x86_64\"" \
	    $srcs -o "$HOSTBIN/bmake"
	ln -sf bmake "$HOSTBIN/make"
}

build_config() {
	local o=$HOSTOBJ/config
	rm -rf "$o"; mkdir -p "$o"
	cp "$SRCDIR"/usr.sbin/config/*.[chyl] "$o/"
	( cd "$o" &&
	  bison -y -d config.y &&
	  flex lang.l &&
	  $HOST_CC $HOST_CFLAGS -I. y.tab.c lex.yy.c main.c mkioconf.c \
	      mkmakefile.c mkheaders.c mkoptions.c -lfl -o "$HOSTBIN/config" )
}

build_small_tools() {
	local bsd
	bsd=$(pkg-config --cflags --libs libbsd-overlay) ||
	    die "libbsd not found (pacman -S libbsd)"
	$HOST_CC $HOST_CFLAGS -o "$HOSTBIN/file2c" \
	    "$SRCDIR/usr.bin/file2c/file2c.c" $bsd
	$HOST_CC $HOST_CFLAGS -o "$HOSTBIN/uudecode" \
	    "$SRCDIR/usr.bin/uudecode/uudecode.c" $bsd -lresolv
	install -m 755 "$SRCDIR/usr.bin/mkdep/mkdep.sh" "$HOSTBIN/mkdep"
	# bsd.lib.mk orders archives with `lorder ... | tsort -q`; GNU tsort
	# has no -q (quiet about cycles), so drop it and silence stderr.
	# GNU mktemp -t wants XXXXXX in the template, which lorder.sh omits.
	sed 's/mktemp -t \(_[a-z]*_\)/mktemp -t \1.XXXXXX/' \
	    "$SRCDIR/usr.bin/lorder/lorder.sh" > "$HOSTBIN/lorder"
	chmod 755 "$HOSTBIN/lorder"
	cat > "$HOSTBIN/tsort" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
exec /usr/bin/tsort "$@" 2>/dev/null
EOF
	chmod 755 "$HOSTBIN/tsort"
}

# Tools that only the world (userland) build needs, plus BSD-compatible
# shims for sed(1) and install(1) so the stock share/mk rules work.
build_world_tools() {
	local bsd compat tirpc
	bsd=$(pkg-config --cflags --libs libbsd-overlay)
	compat="-include $SRCDIR/tools/linux/host-compat.h"
	tirpc=$(pkg-config --cflags libtirpc 2>/dev/null) ||
	    die "libtirpc headers not found (pacman -S libtirpc / apt install libtirpc-dev)"
	$HOST_CC $HOST_CFLAGS $compat $tirpc -o "$HOSTBIN/rpcgen" \
	    "$SRCDIR"/usr.bin/rpcgen/*.c $bsd
	# unifdef uses "constexpr" as an identifier, a keyword in C23.
	$HOST_CC $HOST_CFLAGS -std=gnu17 $compat -I"$SRCDIR/usr.bin/unifdef" \
	    -o "$HOSTBIN/unifdef" "$SRCDIR/usr.bin/unifdef/unifdef.c" $bsd

	# gencat writes BSD message catalogs, not glibc ones.  It needs the
	# BSD <nl_types.h> catalog structures and the BSD NL_*MAX limits
	# (include/limits.h).
	mkdir -p "$HOSTOBJ/inc/machine"
	cp "$SRCDIR/include/nl_types.h" "$HOSTOBJ/inc/"
	echo '#include <stdint.h>' > "$HOSTOBJ/inc/machine/stdint.h"
	$HOST_CC $HOST_CFLAGS $compat -I"$HOSTOBJ/inc" \
	    -DNL_SETMAX=255 -DNL_MSGMAX=32767 \
	    -o "$HOSTBIN/gencat" "$SRCDIR/usr.bin/gencat/gencat.c" $bsd

	# BSD `ln -h` (do not follow a symlinked target) is GNU `ln -n`;
	# bsd.incs.mk uses `ln -fhs` for header links such as util.h.
	cat > "$HOSTBIN/ln" <<'EOF'
#!/bin/sh
n=$#
while [ "$n" -gt 0 ]; do
	a=$1; shift; n=$((n - 1))
	case $a in
	--)	set -- "$@" "$a"; break ;;
	-*h*)	a=$(printf '%s' "$a" | tr h n) ;;
	esac
	set -- "$@" "$a"
done
while [ "$n" -gt 0 ]; do a=$1; shift; n=$((n - 1)); set -- "$@" "$a"; done
exec /usr/bin/ln "$@"
EOF
	chmod 755 "$HOSTBIN/ln"

	# BSD `sed -i ""` means "in place, no backup"; GNU sed would take ""
	# as a file name.
	cat > "$HOSTBIN/sed" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-i" ] && [ "${2+x}" = x ] && [ -z "$2" ]; then
	shift 2; exec /usr/bin/sed -i "$@"
fi
exec /usr/bin/sed "$@"
EOF
	# BSD install(1) for unprivileged staging: drop owner, group and
	# file-flag options (they need root or do not exist in GNU install),
	# BSD-only switches, and -C/-b/-B (GNU refuses -C together with -s);
	# pass everything else to the host install.
	cat > "$HOSTBIN/install" <<'EOF'
#!/bin/sh
n=$#
while [ "$n" -gt 0 ]; do
	a=$1; shift; n=$((n - 1))
	case $a in
	-o|-g|-f|-B)	shift; n=$((n - 1)) ;;
	-o?*|-g?*|-f?*|-B?*|-U|-S|-l?*|-C|-b) ;;
	*)		set -- "$@" "$a" ;;
	esac
done
exec /usr/bin/install "$@"
EOF
	# File flags (schg, ...) do not exist here and need root anyway.
	printf '#!/bin/sh\nexit 0\n' > "$HOSTBIN/chflags"
	chmod 755 "$HOSTBIN/sed" "$HOSTBIN/install" "$HOSTBIN/chflags"
}

# Cross compiler for the world: host clang targeting DragonFly, against the
# staged sysroot, linking with lld.
write_xcc_wrapper() {
	local clang xtool=$OBJDIR/xtool
	if ! clang=$(command -v "${HOST_CLANG:-clang}") ||
	    ! command -v ld.lld >/dev/null 2>&1; then
		msg "clang/ld.lld not found: skipping xcc (needed only for the userland)"
		rm -f "$HOSTBIN/xcc"
		return 0
	fi
	# clang's DragonFly driver looks for crt*.o and libraries in
	# <its own dir>/../lib, i.e. the host's /usr/lib.  Run a copy of the
	# (small) driver binary from $OBJDIR/xtool/bin, with xtool/lib
	# pointing into the sysroot, so only target files are ever found.
	# The driver's resource dir then resolves through
	# $SYSROOT/usr/lib/clang, which points at the host's clang headers.
	rm -rf "$xtool"; mkdir -p "$xtool/bin" "$SYSROOT/usr/lib"
	cp "$(readlink -f "$clang")" "$xtool/bin/clang"
	ln -sfn "$SYSROOT/usr/lib" "$xtool/lib"
	ln -sfn "$("$clang" -print-resource-dir)/.." "$SYSROOT/usr/lib/clang"
	cat > "$HOSTBIN/xcc" <<EOF
#!/bin/sh
# Drop gcc-only options that the gcc runtime makefiles pass.
n=\$#
while [ "\$n" -gt 0 ]; do
	a=\$1; shift; n=\$((n - 1))
	case \$a in
	-fbuilding-libgcc|-finhibit-size-directive) ;;
	*) set -- "\$@" "\$a" ;;
	esac
done
# --undefined-version: like GNU ld, accept version scripts that name
# symbols a given configuration does not build (e.g. hesiod in libc).
exec "$xtool/bin/clang" --target=x86_64-unknown-dragonfly \\
	--sysroot="$SYSROOT" -fuse-ld=lld -Wl,--undefined-version \\
	-Qunused-arguments -Wno-unknown-warning-option "\$@"
EOF
	chmod 755 "$HOSTBIN/xcc"
}

do_tools() {
	need gcc flex bison awk pkg-config objcopy ld nm
	mkdir -p "$HOSTBIN" "$HOSTOBJ"
	msg "bootstrapping host tools into $HOSTBIN"
	write_cc_wrapper
	build_bmake
	build_config
	build_small_tools
	build_world_tools
	write_xcc_wrapper
	echo "$TOOLS_STAMP" > "$HOSTBIN/.done"
}

# Bump when the host tools or shims change, so an existing $OBJDIR gets
# them rebuilt instead of failing with old ones (install -C/-B, chflags).
TOOLS_STAMP=2

kenv() {
	[ "$(cat "$HOSTBIN/.done" 2>/dev/null)" = "$TOOLS_STAMP" ] || do_tools
	PATH=$HOSTBIN:$PATH
	MACHINE=x86_64 MACHINE_ARCH=x86_64 MACHINE_PLATFORM=pc64
	CCVER=gcc120 HOST_CCVER=gcc120 HOST_BINUTILSVER=binutils234
	export PATH MACHINE MACHINE_ARCH MACHINE_PLATFORM CCVER HOST_CCVER \
	    HOST_BINUTILSVER
}

do_kernel() {
	local conf=${1:-X86_64_GENERIC} kobj
	kenv
	kobj=$OBJDIR/sys/$conf
	[ -f "$SRCDIR/sys/config/$conf" ] || die "no such KERNCONF: $conf"
	msg "configuring $conf in $kobj"
	rm -rf "$kobj"; mkdir -p "$OBJDIR/sys"
	( cd "$SRCDIR/sys/config" && config -d "$kobj" "$conf" )
	msg "make depend"
	( cd "$kobj" && make KERNEL=kernel depend )
	msg "make all (-j$JOBS)"
	( cd "$kobj" && make -j"$JOBS" NO_MODULES=1 KERNEL=kernel all )
	msg "kernel: $kobj/kernel.debug"
}

do_modules() {
	local conf=${1:-X86_64_GENERIC} kobj
	kenv
	kobj=$OBJDIR/sys/$conf
	[ -f "$kobj/kernel.debug" ] || do_kernel "$conf"
	msg "building modules (-j$JOBS)"
	( cd "$kobj" && make -j"$JOBS" KERNEL=kernel modules )
}

# Stage the DragonFly headers the way include/Makefile's "copies" target
# does, into $SYSROOT/usr/include.  Done by hand because that target needs
# mtree(8), cpdup(1) and BSD install(1) semantics.
do_sysroot() {
	local inc=$SYSROOT/usr/include s=$SRCDIR/sys d mk ldirs lsubdirs
	msg "staging headers into $inc"
	rm -rf "$inc"; mkdir -p "$inc"
	mk=$SRCDIR/include/Makefile
	# Pull the directory lists straight out of include/Makefile.
	ldirs=$(sed -n 's/^LDIRS=[[:space:]]*//p' "$mk")
	lsubdirs=$(awk '/^LSUBDIRS=/{f=1;next} f{ if ($0 !~ /\\$/) {print; f=0} else {sub(/\\$/,""); print} }' "$mk" | tr '\n' ' ')

	cp "$SRCDIR"/include/*.h "$inc/"
	for d in arpa protocols rpc rpcsvc xlocale; do
		mkdir -p "$inc/$d"
		cp "$SRCDIR"/include/$d/*.h "$inc/$d/" 2>/dev/null || :
	done
	for d in $ldirs $lsubdirs; do
		mkdir -p "$inc/$d"
		cp "$s"/$d/*.h "$inc/$d/" 2>/dev/null || :
	done
	mkdir -p "$inc/dev/acpica" "$inc/dev/misc/evdev" "$inc/compat/linux"
	cp "$s/dev/acpica/acpiio.h" "$inc/dev/acpica/"
	cp "$s"/dev/misc/evdev/input.h "$s"/dev/misc/evdev/input-event-codes.h \
	    "$inc/dev/misc/evdev/"
	# cpu/ first, then machine/ = cpu/ overlaid with the platform headers.
	mkdir -p "$inc/cpu" "$inc/machine/pc"
	cp "$s"/cpu/x86_64/include/*.h "$inc/cpu/"
	cp "$s"/cpu/x86_64/include/*.h "$inc/machine/"
	cp "$s"/platform/pc64/include/*.h "$inc/machine/"
	[ -d "$s/platform/pc64/include/pc" ] &&
	    cp "$s"/platform/pc64/include/pc/*.h "$inc/machine/pc/"
	for f in soundcard.h joystick.h; do
		ln -sf ../sys/$f "$inc/machine/$f"
	done
	for f in aio.h errno.h fcntl.h linker_set.h poll.h sched.h syslog.h \
	    ucontext.h; do
		ln -sf sys/$f "$inc/$f"
	done
	# Library headers that stand/ needs (lib/libz INCS).
	cp "$SRCDIR/lib/libz/zconf.h" "$SRCDIR/contrib/zlib/zlib.h" "$inc/"
	ln -sf netproto/smb "$inc/netsmb"
	ln -sf ieeefp.h "$inc/floatingpoint.h"
	{
		echo "#ifdef _KERNEL"
		echo '#error "osreldate.h must not be used in the kernel, use sys/param.h"'
		echo "#else"
		echo "#undef __DragonFly_version"
		awk '/^#define[[:space:]]+__DragonFly_version/ {print "#define __DragonFly_version " $3}' \
		    "$s/sys/param.h"
		echo "#endif"
	} > "$inc/osreldate.h"

	# The rest is what buildworld's "includes" stage does: create the
	# directory tree from the mtree spec (mtree(8) is not available on
	# Linux, so read the spec with awk), then let every directory under
	# include/ and lib/ install its own headers.  Generated headers, such
	# as the rpcgen output for include/rpc, come from the same rules.
	mtree_dirs "$SRCDIR/etc/mtree/BSD.root.dist" "$SYSROOT"
	mtree_dirs "$SRCDIR/etc/mtree/BSD.usr.dist" "$SYSROOT/usr"
	mtree_dirs "$SRCDIR/etc/mtree/BSD.include.dist" "$inc"
	(
	wenv
	for d in include/arpa include/protocols include/rpc include/rpcsvc \
	    include/xlocale lib; do
		msg "installing headers from $d"
		( cd "$SRCDIR/$d" && make obj >/dev/null &&
		  make -j"$JOBS" DESTDIR="$SYSROOT" buildincludes &&
		  make DESTDIR="$SYSROOT" installincludes )
	done
	)
	echo "$HEADERS_STAMP" > "$SYSROOT/.headers_done"
}

# Bump when do_sysroot stages headers differently, so sysroots made by an
# older build.sh are restaged instead of silently missing files (e.g. the
# rpcsvc/*.x that libc's `make depend` needs).
HEADERS_STAMP=3
headers_ok() {
	[ "$(cat "$SYSROOT/.headers_done" 2>/dev/null)" = "$HEADERS_STAMP" ]
}

# Create the directories listed in an mtree(8) specification.
mtree_dirs() {
	awk '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ || /^\/set/ { next }
	{
		name = $1
		if (name == "..") { n--; next }
		if (name == ".") { n = 0; next }
		path[++n] = name
		p = path[1]
		for (i = 2; i <= n; i++) p = p "/" path[i]
		print p
	}' "$1" | while read -r d; do
		mkdir -p "$2/$d"
	done
}

# Environment for building the world (userland) with xcc.  CCVER is not
# a gcc version, so share/mk does not add gcc-only flags or -Werror; clang
# warnings stay warnings.
wenv() {
	kenv
	CCVER=clang
	CC=xcc
	MAKEOBJDIRPREFIX=$OBJDIR/world
	# Build-time helpers (ncurses' make_keys, ...) run on this host, so
	# the "native" compiler is the host's; its default NXENV would also
	# reset PATH and drop the shims.
	NXENV=
	NXCC=$HOST_CC
	NXCC_LINK=$HOST_CC
	# Where buildworld's makefiles look for already-installed libraries
	# and private headers (e.g. usr/include/priv/ncurses).
	_SHLIBDIRPREFIX=$SYSROOT
	export CCVER CC MAKEOBJDIRPREFIX NXENV NXCC NXCC_LINK _SHLIBDIRPREFIX
	mkdir -p "$MAKEOBJDIRPREFIX"
}

# Userland libraries, starting from the bottom: csu, then libc.
do_libc() {
	headers_ok || do_sysroot
	wenv
	[ -x "$HOSTBIN/xcc" ] ||
	    die "xcc missing: install clang and lld, then run build.sh tools"
	world_lib lib/csu
	install_compiler_rt
	world_lib lib/libc
}

# The smallest userland that boots to a shell, in build order: the runtime
# linker and the libraries first, then init, sh and a few utilities.
BASE_LIBS="lib/libc_rtld libexec/rtld-elf lib/libutil lib/libcrypt
	lib/libncurses lib/libedit lib/libm lib/libkvm"
BASE_PROGS="sbin/init bin/sh bin/cat bin/cp bin/echo bin/hostname bin/kill
	bin/ln bin/ls bin/mkdir bin/mv bin/ps bin/pwd bin/rm bin/sleep
	sbin/dmesg sbin/mount sbin/mount_tmpfs sbin/reboot sbin/sysctl
	usr.bin/uname"

do_base() {
	local d
	[ -f "$SYSROOT/usr/lib/libc.so" ] || do_libc
	wenv
	for d in $BASE_LIBS $BASE_PROGS; do
		case $d in
		# libtic and tic_next only serve share/terminfo.
		lib/libncurses)	world_lib "$d" NO_SHARE=yes ;;
		# LD_DEBUG=1 support, for when a dynamic program fails to start.
		libexec/rtld-elf) world_lib "$d" ENABLE_DEBUG=yes ;;
		# Static like init, so the image always gets a working shell
		# (and its /etc/rc runs) even if dynamic linking is broken.
		bin/sh)		world_lib "$d" NOSHARED=yes ;;
		*)		world_lib "$d" ;;
		esac
	done
}

# Stage a root tree with what $BASE_PROGS installed plus every shared
# library they load, and pack it as a Rock Ridge ISO (root.iso) that the
# kernel mounts as cd9660; making it needs no root privileges.
do_rootfs() {
	local root=$OBJDIR/rootfs iso=$OBJDIR/root.iso d f prog lib
	[ -x "$SYSROOT/bin/sh" ] || do_base
	wenv
	rm -rf "$root"
	mkdir -p "$root"
	for d in bin sbin lib/priv libexec usr/bin usr/lib usr/libexec dev etc \
	    root tmp var/run; do
		mkdir -p "$root/$d"
	done
	cp -p "$SYSROOT/libexec/ld-elf.so.2" "$root/libexec/"
	ln -s ../../libexec/ld-elf.so.2 "$root/usr/libexec/ld-elf.so.2"
	for d in $BASE_PROGS; do
		prog=$(cd "$SRCDIR/$d" && make -V PROG)
		f=$(cd "$SYSROOT" && ls -d */"$prog" usr/*/"$prog" 2>/dev/null |
		    head -n 1) || :
		[ -n "$f" ] || die "$d: $prog not installed in the sysroot"
		cp -p "$SYSROOT/$f" "$root/$f"
	done
	# Links that bsd.prog.mk installs (halt -> reboot, ...).
	ln -s reboot "$root/sbin/halt"
	# Copy the shared libraries, following NEEDED entries to a fixpoint.
	local added=1 found
	while [ "$added" = 1 ]; do
		added=0
		for f in $(find "$root" -type f); do
			for lib in $(readelf -d "$f" 2>/dev/null |
			    sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
				found=
				for d in lib lib/priv usr/lib usr/lib/priv; do
					[ -e "$root/$d/$lib" ] && { found=1; break; }
				done
				[ -n "$found" ] && continue
				for d in lib lib/priv usr/lib usr/lib/priv; do
					[ -e "$SYSROOT/$d/$lib" ] || continue
					mkdir -p "$root/$d"
					cp -pL "$SYSROOT/$d/$lib" "$root/$d/$lib"
					found=1 added=1
					break
				done
				[ -n "$found" ] ||
				    die "$f needs $lib, which is not in the sysroot"
			done
		done
	done
	write_brand_tests "$root/root/tests"
	write_terminfo "$root/usr/share/terminfo"
	write_rc "$root/etc/rc"
	echo "foxynbsd" > "$root/etc/hostname"
	# Login classes: init(8) looks up class "daemon" for /etc/rc.  With
	# no login.conf.db, getcap(3) reads the text file directly, so no
	# cap_mkdb run is needed on the build host.
	cp "$SRCDIR/etc/login.conf" "$root/etc/login.conf"
	if command -v xorriso >/dev/null 2>&1; then
		# -R keeps modes and symlinks (Rock Ridge); the volume is read-only.
		# Record the files as root:wheel rather than the building user.
		xorriso -as mkisofs -quiet -R -uid 0 -gid 0 -V FOXYNROOT \
		    -o "$iso" "$root"
		msg "root image: $iso (boot it with tools/linux/qemu.sh --root)"
	else
		msg "root tree: $root (install xorriso to pack root.iso)"
	fi
}

# Two tiny static programs that differ only in their ELF ABI note: one
# says FoxynBSD, the other DragonFly.  Their EI_OSABI is 255 (standalone)
# and they have no interpreter, so the kernel can only accept them by the
# note; /etc/rc runs both (issue #5).
write_brand_tests() {
	local dir=$1 vendor src
	mkdir -p "$dir"
	src=$OBJDIR/brandtest.c
	for vendor in FoxynBSD DragonFly; do
		cat > "$src" <<EOF
/* ABI note: namesz, descsz, type 1, vendor, osrel. */
__asm__(".section .note.tag,\"a\",@note\n"
    "\t.p2align 2\n"
    "\t.long ${#vendor} + 1\n"
    "\t.long 4\n"
    "\t.long 1\n"
    "\t.asciz \"$vendor\"\n"
    "\t.p2align 2\n"
    "\t.long 600522\n"
    "\t.previous");

static const char msg[] = "brand $vendor: ok\n";

static long
sys3(long n, long a, long b, long c)
{
	long r;

	__asm__ __volatile__("syscall" : "=a" (r)
	    : "a" (n), "D" (a), "S" (b), "d" (c) : "rcx", "r11", "memory");
	return (r);
}

void _start(void);

void
_start(void)
{
	sys3(4, 1, (long)msg, sizeof(msg) - 1);	/* write */
	sys3(1, 0, 0, 0);			/* exit */
	for (;;)
		;
}
EOF
		xcc -static -nostdlib -ffreestanding -fno-stack-protector -O2 \
		    -o "$dir/brand-$vendor" "$src"
		# EI_OSABI (byte 7) = 255: no fallback by OS ABI or interpreter.
		printf '\377' | dd of="$dir/brand-$vendor" bs=1 seek=7 \
		    conv=notrunc 2>/dev/null
	done
	rm -f "$src"
}

# Compile the console terminal types from the tree's terminfo.src with the
# host's tic.  The image's ncurses reads the same directory-tree format
# (both the 16- and the 32-bit entries).
TERMINFO_TYPES="xterm,xterm-256color,vt100,vt220,cons25,dumb"
write_terminfo() {
	if ! command -v tic >/dev/null 2>&1; then
		msg "tic not found (ncurses): the image gets no terminfo"
		return 0
	fi
	mkdir -p "$1"
	tic -o "$1" -e "$TERMINFO_TYPES" \
	    "$SRCDIR/contrib/ncurses/misc/terminfo.src" 2>/dev/null
}

# /etc/rc for the minimal image: init(8) runs it on the console.  It prints
# a marker the boot test waits for, then hands the console to a shell.
write_rc() {
	cat > "$1" <<'EOF'
#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
TERM=${TERM:-xterm}
export PATH TERM
# The root is a read-only CD image; /tmp lives in memory.
if mount -t tmpfs tmpfs /tmp && echo ok > /tmp/.rc-test; then
	echo "rc: /tmp is writable (tmpfs)"
fi
hostname "$(cat /etc/hostname)"
echo
# The marker below is what boot-test.sh --root waits for: print it only
# if dynamically linked programs (rtld + libc + libutil + ncurses) ran.
# sh and init are static, so this is the first use of ld-elf.so.2.
if uname -a && ls -l /bin/sh; then
	echo
	echo "FoxynBSD userland is up (minimal read-only root on cd9660)."
	echo "This is /bin/sh; 'halt -p' powers the machine off."
else
	echo "rc: dynamically linked programs fail; ld-elf.so.2 trace follows"
	LD_DEBUG=1 uname -a
	echo "rc: exit status $?"
fi
# ABI notes: both brands must be accepted (issue #5).
for b in /root/tests/brand-*; do
	"$b" || echo "rc: $b failed with status $?"
done
echo
/bin/sh -i
halt -p
EOF
	chmod 755 "$1"
}

# world_lib DIR [VAR=value ...]: build one userland directory with xcc and
# install it into the sysroot, as buildworld's library stage does, so later
# links find it.  CCVER is passed on the command line because gnu/
# makefiles assign it themselves.
# `depend` comes first as in buildworld: the generated .depend ties each
# object to its listed source, so an arch .S wins over a same-named .c
# that the suffix rules would otherwise pick (libm's e_sqrtl).
world_lib() {
	local dir=$1; shift
	msg "building $dir"
	( cd "$SRCDIR/$dir" && make obj >/dev/null &&
	  make CCVER=clang DESTDIR="$SYSROOT" "$@" depend &&
	  make -j"$JOBS" CCVER=clang DESTDIR="$SYSROOT" "$@" &&
	  make CCVER=clang DESTDIR="$SYSROOT" "$@" install )
	fix_sysroot_links
}

# Installed symlinks are absolute (/usr/lib/libc.so -> /lib/libc.so.8).
# Inside the sysroot that would resolve on the host, so the linker would
# silently fall back to the static library; re-point them, relative, into
# the sysroot.
fix_sysroot_links() {
	find "$SYSROOT" -type l -lname '/*' ! -path "$SYSROOT/usr/lib/clang" |
	while read -r l; do
		t=$(readlink "$l")
		case $t in "$SYSROOT"/*) t=${t#"$SYSROOT"} ;; esac
		# Relative, so the link resolves both here and in the root image.
		ln -sfn "$(realpath -m --relative-to="$(dirname "$l")" "$SYSROOT$t")" "$l"
	done
}

# The compiler runtime (crtbegin/crtend and the libgcc helpers).  The
# in-tree gcc runtime (gnu/lib/gcc120) depends on gcc internals and does
# not build with clang, so use the host's LLVM compiler-rt instead.  Its
# objects are OS-independent and position-independent.  They go where
# clang's DragonFly driver looks: /usr/lib/gcc80.
# Stopgap until compiler-rt is built from source in the tree.
install_compiler_rt() {
	local res rt sfx dst=$SYSROOT/usr/lib/gcc80 f
	res=$("$OBJDIR/xtool/bin/clang" -print-resource-dir)/lib
	# Per-target layout (LLVM >= 19 default, Arch) or the older
	# lib/linux/*-x86_64 one (Ubuntu's LLVM 18).
	if [ -f "$res/x86_64-pc-linux-gnu/clang_rt.crtbegin.o" ]; then
		rt=$res/x86_64-pc-linux-gnu sfx=
	else
		rt=$res/linux sfx=-x86_64
	fi
	for f in clang_rt.crtbegin$sfx.o clang_rt.crtend$sfx.o \
	    libclang_rt.builtins$sfx.a; do
		[ -f "$rt/$f" ] ||
		    die "compiler-rt not found ($rt/$f); install compiler-rt"
	done
	msg "installing compiler-rt from $rt into $dst"
	mkdir -p "$dst"
	for f in crtbegin crtbeginS crtbeginT; do
		cp "$rt/clang_rt.crtbegin$sfx.o" "$dst/$f.o"
	done
	for f in crtend crtendS; do
		cp "$rt/clang_rt.crtend$sfx.o" "$dst/$f.o"
	done
	cp "$rt/libclang_rt.builtins$sfx.a" "$dst/libgcc.a"
	cp "$rt/libclang_rt.builtins$sfx.a" "$dst/libgcc_pic.a"
	# libgcc_eh is the exception unwinder; C needs none, but the driver
	# asks for it in static links.  An empty archive satisfies -lgcc_eh.
	rm -f "$dst/libgcc_eh.a"
	ar rc "$dst/libgcc_eh.a"
}

# EFI boot loader: stand/lib -> dloader -> libefi -> loader.efi, compiled
# against the staged sysroot headers instead of the Linux ones.
STANDOBJ=$OBJDIR/stand
do_loader() {
	local d xcc
	kenv
	headers_ok || do_sysroot
	xcc="cc -nostdinc -isystem $SYSROOT/usr/include"
	MAKEOBJDIRPREFIX=$STANDOBJ; export MAKEOBJDIRPREFIX
	mkdir -p "$STANDOBJ"
	for d in stand/lib stand/boot/dloader stand/boot/efi/libefi \
	    stand/boot/efi/loader; do
		msg "building $d"
		( cd "$SRCDIR/$d" && make obj >/dev/null &&
		  make -j"$JOBS" CC="$xcc" )
	done
	msg "loader: $(loader_efi)"
}

loader_efi() {
	echo "$STANDOBJ$SRCDIR/stand/boot/efi/loader/loader.efi"
}

# Assemble an EFI System Partition tree that QEMU can serve directly with
# -drive file=fat:rw:<dir>, so no root / mkfs / loop devices are needed.
do_esp() {
	local conf=${1:-X86_64_GENERIC} kobj esp boot
	kobj=$OBJDIR/sys/$conf
	esp=$OBJDIR/esp/$conf
	boot=$esp/boot
	[ -f "$kobj/kernel.stripped" ] || do_kernel "$conf"
	[ -f "$(loader_efi)" ] || do_loader
	msg "assembling ESP in $esp"
	rm -rf "$esp"
	mkdir -p "$esp/EFI/BOOT" "$boot/defaults" "$boot/kernel"
	cp "$(loader_efi)" "$esp/EFI/BOOT/BOOTX64.EFI"
	cp "$SRCDIR/stand/boot/pc32/loader/dloader.rc" "$boot/"
	cp "$SRCDIR/stand/boot/dloader/loader.conf" \
	    "$SRCDIR/stand/boot/dloader/dloader.menu" "$boot/defaults/"
	cp "$kobj/kernel.stripped" "$boot/kernel/kernel"
	if [ "${WITH_MODULES:-0}" = 1 ]; then
		# Strip debug info; QEMU's virtual FAT disk is size-limited.
		find "$kobj$SRCDIR/sys" -name '*.ko' | while read -r ko; do
			objcopy --strip-debug "$ko" "$boot/kernel/${ko##*/}"
		done
	fi
	# Serial console so `qemu -nographic` shows loader and kernel output.
	cat > "$boot/loader.conf" <<'EOF'
console="comconsole"
autoboot_delay="3"
boot_serial="YES"
EOF
	msg "ESP: $esp"
}

# Everything runs from inside main, and the call shares its line with
# exit: the shell reads a script piece by piece, so a build.sh rewritten
# while a long build runs (git pull) must not be read again afterwards.
main() {
	cmd=${1:-}
	# set -e exits quietly; say which command failed (the last ">>>" line
	# before this one names the step).
	trap 'rc=$?; [ "$rc" = 0 ] || echo "build.sh: $cmd failed (exit $rc)" >&2' EXIT
	[ $# -gt 0 ] && shift
	case ${1:-} in
	-*)	die "unknown option: $1 (--gui and --root belong to qemu.sh)" ;;
	esac
	case $cmd in
	tools)		do_tools ;;
	kernel)		do_kernel "$@" ;;
	modules)	do_modules "$@" ;;
	sysroot)	do_sysroot ;;
	libc)		do_libc ;;
	base)		do_base ;;
	rootfs)		do_rootfs ;;
	subdir)		[ -f "$SYSROOT/usr/lib/libc.so" ] || do_libc
			wenv; for d; do world_lib "$d"; done ;;
	loader)		do_loader ;;
	esp)		do_esp "$@" ;;
	env)		kenv; env | grep -E '^(PATH|MACHINE|MACHINE_ARCH|MACHINE_PLATFORM|CCVER|HOST_CCVER|HOST_BINUTILSVER)=' | sed 's/^/export /' ;;
	*)		sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
	esac
}

main "$@"; exit
