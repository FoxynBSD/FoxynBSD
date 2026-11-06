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
#	tools/linux/build.sh [all]		(the whole system, ready for qemu.sh;
#					 run again, it rebuilds what changed)
#	tools/linux/build.sh tools
#	tools/linux/build.sh kernel [KERNCONF]	(default X86_64_GENERIC)
#	tools/linux/build.sh modules [KERNCONF]
#	tools/linux/build.sh sysroot		(stage DragonFly headers)
#	tools/linux/build.sh libc		(userland: csu + libc, with clang)
#	tools/linux/build.sh base		(rtld, init, sh, core utilities)
#	tools/linux/build.sh rootfs		(root tree and root.iso: the whole
#					 world; ROOTFS=base for a minimal one)
#	tools/linux/build.sh disk		(disk.img: the root tree on a
#					 writable UFS disk; DISK_SIZE=4G)
#	tools/linux/build.sh world		(the whole userland, buildworld
#					 order; KEEP_GOING=1 lists failures)
#	tools/linux/build.sh subdir DIR...	(build and install world dirs)
#	tools/linux/build.sh loader		(EFI loader.efi)
#	tools/linux/build.sh esp [KERNCONF]	(boot tree for QEMU;
#					 WITH_MODULES=1 to add .ko)
#	tools/linux/build.sh env		(print an env for manual make runs)
#	tools/linux/build.sh doctor		(check the host's tools and packages)
#
# Environment:
#	OBJDIR	output directory (default ${XDG_CACHE_HOME:-~/.cache}/foxynbsd)
#	JOBS	parallel jobs (default: nproc)
#	HOST_CC, HOST_CFLAGS	compiler and flags for the host tools (gcc, -O2)
#	KERNCC	kernel and module compiler: gcc (default, the host gcc
#		through the cc wrapper) or clang (kcc, DragonFly target)
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
HOST_CXX=${HOST_CXX:-g++}
HOST_CFLAGS=${HOST_CFLAGS:--O2}
SYSROOT=$OBJDIR/sysroot

die() { echo "build.sh: $*" >&2; exit 1; }
msg() { echo ">>> $*" >&2; }

need() {
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
	done
}

# The absolute path of a host program, for the shims in $HOSTBIN that
# wrap it: searched in $PATH without $HOSTBIN itself (so a shim never
# finds itself), then in the sbin directories that Debian keeps out of a
# user's $PATH.  Distributions put the same tool in different places.
host_path() {
	local d IFS=:
	for d in $PATH /usr/sbin /sbin; do
		[ "$d" = "$HOSTBIN" ] && continue
		[ -f "$d/$1" ] && [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
	done
	die "missing host tool: $1"
}

# Point the shims $HOSTBIN/<name>... at the host programs they wrap: each
# was written with @NAME@ in place of the program's path.
shim_target() {
	local t p sed
	sed=$(host_path sed)	# not the sed shim, which may be one of them
	for t in "$@"; do
		p=$(host_path "$t")
		"$sed" -i "s|@$(echo "$t" | tr a-z A-Z)@|$p|g" "$HOSTBIN/$t"
		chmod 755 "$HOSTBIN/$t"
	done
}

# Wrapper around the host gcc so it behaves like DragonFly's base
# compiler for kernel purposes.  Two kinds of flags:
#
# Target requirements (what the DragonFly kernel ABI needs, whatever the
# host defaults are):
#	-fno-pie -fno-pic -no-pie	the kernel is linked at a fixed address
#				with -mcmodel=kernel; Arch, Debian and Ubuntu
#				gcc default to PIE.
#	-U__linux__ ... -D__DragonFly__	the predefines of DragonFly's gcc
#				(ACPICA would pick aclinux.h).
#	-Wl,--no-as-needed	the kernel keeps its dynamic section, which the
#				module linker needs (Debian/Ubuntu default
#				to --as-needed).
# Host hardening defaults that a kernel cannot use (it provides none of
# the runtime they rely on: no CET setup, no stack-clash probing support,
# no fortify library):
#	-fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE
#	-Wl,-z,lazy -Wl,-z,norelro	(Ubuntu's -z now / relro: meaningless for
#				a kernel, and they change its layout)
# The kernel makefiles choose stack protection themselves
# (-fno-stack-protector), so that is not touched here.
#
# Warnings introduced by compilers newer than the in-tree gcc120 stay
# warnings instead of failing -Werror; only the ones this gcc knows are
# passed, since gcc rejects a -Wno-error= for a warning it does not have.
# Format strings that are not literals are always an error, as with
# Debian/Ubuntu gcc, so every Linux host catches the same problems as CI.
write_cc_wrapper() {
	local hostgcc w noerr=
	hostgcc=$(command -v "${HOST_GCC:-gcc}") || die "no host gcc"
	for w in dangling-pointer enum-int-mismatch maybe-uninitialized \
	    array-bounds; do
		echo 'int x;' | "$hostgcc" -Werror -Wno-error=$w -x c -c \
		    -o /dev/null - 2>/dev/null && noerr="$noerr -Wno-error=$w"
	done
	cat > "$HOSTBIN/cc" <<EOF
#!/bin/sh
exec "$hostgcc" \\
	-fno-pie -fno-pic -no-pie \\
	-Wl,--no-as-needed -Wl,-z,lazy -Wl,-z,norelro \\
	-fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE \\
	-U__linux__ -U__linux -Ulinux -U__gnu_linux__ -D__DragonFly__ \\
	$noerr \\
	-Wformat -Werror=format-security \\
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
	$HOST_CC $HOST_CFLAGS -include "$SRCDIR/tools/linux/host-compat.h" \
	    -o "$HOSTBIN/uuencode" \
	    "$SRCDIR/usr.bin/uuencode/uuencode.c" $bsd -lresolv
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
exec @TSORT@ "$@" 2>/dev/null
EOF
	# BSD `find -s` walks each directory in sorted order (kdump's
	# mkioctls lists headers that way); GNU find has no -s, so sort.
	cat > "$HOSTBIN/find" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -s ]; then
	shift
	@FIND@ "$@" | LC_ALL=C sort
else
	exec @FIND@ "$@"
fi
EOF
	shim_target tsort find
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

	# Compiler for the helpers that run during the world build (NXCC:
	# mkmagic, make_keys, ...).  Their config headers describe DragonFly;
	# glibc has the xlocale functions in <locale.h>, so give them an
	# <xlocale.h> that includes it.
	mkdir -p "$OBJDIR/host/include"
	echo '#include <locale.h>' > "$OBJDIR/host/include/xlocale.h"
	# They also get libbsd and the BSD macros, like the tools above,
	# except when only preprocessing (-E): gcc's params.list and the
	# like are made from cpp output, which must stay free of them.
	# bsd.hostprog.mk links them -static; distributions ship libbsd
	# only as a shared library, and these programs never leave the host.
	local c
	# gcc 12 and the other C++ host code predate C++20 (char8_t), the
	# default of recent g++; a -std the makefiles pass still wins.
	for c in "$HOST_CC:hostcc" "$HOST_CXX -std=gnu++14:hostc++"; do
		cat > "$HOSTBIN/${c#*:}" <<EOF
#!/bin/sh
n=\$# pre=
while [ "\$n" -gt 0 ]; do
	a=\$1; shift; n=\$((n - 1))
	case \$a in
	-static) continue ;;
	-E) pre=1 ;;
	esac
	set -- "\$@" "\$a"
done
[ -n "\$pre" ] && exec ${c%%:*} -idirafter "$OBJDIR/host/include" "\$@"
exec ${c%%:*} $compat -idirafter "$OBJDIR/host/include" "\$@" $bsd
EOF
		chmod 755 "$HOSTBIN/${c#*:}"
	done
	cat > "$HOSTBIN/nxenv" <<'EOF'
#!/bin/sh
# NXENV for the world build: like env(1), run a command after optional
# VAR=value settings, with the target compilers replaced by the host's.
n=$# cmd=
while [ "$n" -gt 0 ]; do
	a=$1; shift; n=$((n - 1))
	if [ -z "$cmd" ]; then
		case $a in
		*=*)	;;
		xcc)	a=hostcc cmd=1 ;;
		xc++)	a=hostc++ cmd=1 ;;
		*)	cmd=1 ;;
		esac
	fi
	set -- "$@" "$a"
done
exec env "$@"
EOF
	chmod 755 "$HOSTBIN/nxenv"

	# zic(8) for share/zoneinfo, built from the tree like buildworld's
	# bootstrap tools: the hosts' own zic is in other places (/usr/sbin
	# on Debian) and comes from other tzcode releases, whose options
	# differ (DragonFly's -D: do not create directories).  The zoneinfo
	# build runs it as root with -u root -g wheel; the wrapper drops them.
	mkdir -p "$HOSTOBJ/zic"
	$HOST_CC $HOST_CFLAGS $compat -I"$SRCDIR/lib/libc/stdtime" \
	    -o "$HOSTOBJ/zic/zic" "$SRCDIR/usr.sbin/zic/zic.c" \
	    "$SRCDIR/usr.sbin/zic/ialloc.c" "$SRCDIR/usr.sbin/zic/scheck.c" $bsd
	cat > "$HOSTBIN/zic" <<'EOF'
#!/bin/sh
n=$#
while [ "$n" -gt 0 ]; do
	a=$1; shift; n=$((n - 1))
	case $a in
	-u|-g)	shift; n=$((n - 1)) ;;
	*)	set -- "$@" "$a" ;;
	esac
done
exec @ZIC@ "$@"
EOF
	"$(host_path sed)" -i "s|@ZIC@|$HOSTOBJ/zic/zic|" "$HOSTBIN/zic"
	chmod 755 "$HOSTBIN/zic"

	# buildworld's bootstrap yacc (byacc): bison differs in the
	# generated names and headers that ftpd and acpi's iasl rely on.
	local by=$SRCDIR/contrib/byacc f
	$HOST_CC $HOST_CFLAGS $compat -DYYPATCH="$(cat "$by/VERSION")" \
	    -DHAVE_CONFIG_H -I"$SRCDIR/usr.bin/yacc" -DMAXTABLE=65000 \
	    -o "$HOSTBIN/yacc" $(for f in closure error graph lalr lr0 main \
	    mkpar mstring output reader symtab verbose warshall yaccpar; do
		echo "$by/$f.c"; done) $bsd

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
exec @LN@ "$@"
EOF

	# BSD `sed -i ""` means "in place, no backup"; GNU sed would take ""
	# as a file name.
	cat > "$HOSTBIN/sed" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-i" ] && [ "${2+x}" = x ] && [ -z "$2" ]; then
	shift 2; exec @SED@ -i "$@"
fi
exec @SED@ "$@"
EOF
	# BSD install(1) for unprivileged staging: drop owner, group and
	# file-flag options (they need root or do not exist in GNU install)
	# and BSD-only switches; pass everything else to the host install.
	# Files are always installed as with BSD -C: one whose contents and
	# mode did not change is left alone, mtime included, so installing a
	# directory again (libc, say) does not make everything that links
	# against it relink.  GNU install refuses -C together with -s, so a
	# stripped file is stripped into a temporary directory first and
	# compared from there.
	cat > "$HOSTBIN/install" <<'EOF'
#!/bin/sh
n=$# strip= dir=
while [ "$n" -gt 0 ]; do
	a=$1; shift; n=$((n - 1))
	case $a in
	-o|-g|-f|-B|-N)	shift; n=$((n - 1)) ;;
	-o?*|-g?*|-f?*|-B?*|-N?*|-U|-S|-l?*|-C|-b) ;;
	-s)		strip=1 ;;
	-d)		dir=1; set -- "$@" "$a" ;;
	*)		set -- "$@" "$a" ;;
	esac
done
[ -n "$dir" ] && exec @INSTALL@ "$@"
opts=
while [ $# -gt 0 ]; do
	case $1 in
	-m)	opts="$opts $1 $2"; shift 2 ;;
	-*)	opts="$opts $1"; shift ;;
	*)	break ;;
	esac
done
[ -n "$strip" ] || exec @INSTALL@ -C $opts "$@"
# Sources and the destination (last): strip the sources into $t, then
# compare those with the destination.
t=$(mktemp -d) || exit 1
trap 'rm -rf "$t"' EXIT
n=$#
while [ "$n" -gt 1 ]; do
	@INSTALL@ -s $opts "$1" "$t/" || exit
	set -- "$@" "$t/${1##*/}"; shift; n=$((n - 1))
done
d=$1; shift
@INSTALL@ -C $opts "$@" "$d"
EOF
	# File flags (schg, ...) do not exist here and need root anyway.
	printf '#!/bin/sh\nexit 0\n' > "$HOSTBIN/chflags"
	chmod 755 "$HOSTBIN/chflags"
	shim_target ln sed install
}

# The generators that buildworld's bootstrap-tools stage builds for the
# share/ data (Makefile.inc1 BSTRAPDIRS): the glibc programs of the same
# name write other formats, or (cap_mkdb) do not exist.  They are built
# from the tree with hostcc, which supplies libbsd and host-compat.h.
build_bootstrap_tools() {
	local b=$HOSTOBJ/bt inc=$HOSTOBJ/bt/inc t d c=$SRCDIR/lib/libc/citrus
	local db=$SRCDIR/lib/libc/db
	rm -rf "$b"; mkdir -p "$inc"

	# localedef(1) for share/colldef, ctypedef and monetdef.  It reads
	# the _CTYPE_* class bits from DragonFly's <ctype.h>.
	grep -E '^#define[[:space:]]+_CTYPE_[A-Z0-9]+[[:space:]]' \
	    "$SRCDIR/include/ctype.h" > "$inc/bsdctype.h"
	d=$SRCDIR/usr.bin/localedef
	( cd "$b" && "$HOSTBIN/yacc" -d -o parser.c "$d/parser.y" )
	"$HOSTBIN/hostcc" $HOST_CFLAGS -include "$inc/bsdctype.h" \
	    -DBOOTSTRAPPING -I"$b" -I"$d" -I"$SRCDIR/lib/libc/locale" \
	    -I"$SRCDIR/lib/libc/stdtime" -o "$HOSTBIN/localedef" \
	    "$b/parser.c" $(for t in charmap collate ctype localedef messages \
	    monetary numeric scanner time wide; do echo "$d/$t.c"; done)

	# mkcsmapper(1) and mkesdb(1) for share/i18n (citrus iconv tables).
	for t in mkcsmapper mkesdb; do
		d=$SRCDIR/usr.bin/$t
		mkdir -p "$b/$t"
		( cd "$b/$t" && "$HOSTBIN/yacc" -d -o yacc.c "$d/yacc.y" &&
		  flex -o lex.c "$d/lex.l" )
		"$HOSTBIN/hostcc" $HOST_CFLAGS -I"$b/$t" -I"$d" -I"$c" \
		    -I"$SRCDIR/lib/libc" \
		    -I"$SRCDIR/lib/i18n_module/mapper_std" -o "$HOSTBIN/$t" \
		    "$b/$t/yacc.c" "$b/$t/lex.c" "$c/citrus_bcs.c" \
		    "$c/citrus_db_factory.c" "$c/citrus_db_hash.c" \
		    "$c/citrus_lookup_factory.c" \
		    $([ $t = mkcsmapper ] && echo "$c/citrus_pivot_factory.c")
	done

	# cap_mkdb(1) for share/termcap, with the tree's 4.4BSD db(3) and
	# getcap(3), which glibc does not have.
	cp "$SRCDIR/include/db.h" "$SRCDIR/include/mpool.h" "$inc/"
	: > "$inc/un-namespace.h"
	for t in open read write close fcntl fstat fsync unlink writev \
	    sigprocmask; do
		echo "#define _$t $t"
	done > "$inc/namespace.h"
	{
		echo '#define __BSD_VISIBLE 1'
		echo '#define O_EXLOCK 0'
		echo '#define O_SHLOCK 0'
		echo '#define issetugid() 0'
		echo 'int mkostemp(char *, int);'
		grep -E '^#define[[:space:]]+(rounddown2|__PAST_END)\(' \
		    "$SRCDIR/sys/sys/param.h"
		grep -E '^(char|int)[[:space:]]+\*?cget[a-z]+\(' \
		    "$SRCDIR/include/stdlib.h"
	} > "$inc/dbcompat.h"
	"$HOSTBIN/hostcc" $HOST_CFLAGS -include "$inc/dbcompat.h" \
	    -D__DBINTERFACE_PRIVATE -I"$inc" -o "$HOSTBIN/cap_mkdb" \
	    "$SRCDIR/usr.bin/cap_mkdb/cap_mkdb.c" \
	    "$SRCDIR/lib/libc/gen/getcap.c" "$db"/btree/bt_*.c \
	    "$db/db/db.c" "$db"/hash/hash*.c "$db/mpool/mpool.c" \
	    "$db"/recno/rec_*.c

	# Host programs that read console structures (share/syscons'
	# mkscrfil, kbdcontrol) find DragonFly's console headers after the
	# host's own.
	mkdir -p "$OBJDIR/host/include/sys" "$OBJDIR/host/include/machine"
	for t in consio ioccom kbio fbio; do
		cp "$SRCDIR/sys/sys/$t.h" "$OBJDIR/host/include/sys/"
	done
	cp "$SRCDIR/sys/platform/pc64/include/console.h" \
	    "$OBJDIR/host/include/machine/"
	printf '#include <stdint.h>\ntypedef uintptr_t vm_offset_t;\ntypedef uintptr_t vm_size_t;\n' \
	    > "$OBJDIR/host/include/machine/types.h"

	# kbdcontrol -L turns the kernel's built-in keymaps (LINT64's
	# ATKBD_DFLT_KEYMAP, UKBD_DFLT_KEYMAP) into C, as KBDCONTROL.  A
	# keymap name is looked up in the tree's share/syscons/keymaps.
	d=$SRCDIR/usr.sbin/kbdcontrol
	mkdir -p "$b/kbdcontrol"
	flex -o "$b/kbdcontrol/lex.c" "$d/lex.l"
	"$HOSTBIN/hostcc" $HOST_CFLAGS -I"$d" -o "$b/kbdcontrol/kbdcontrol" \
	    "$d/kbdcontrol.c" "$b/kbdcontrol/lex.c" -lfl
	cat > "$HOSTBIN/kbdcontrol" <<EOF
#!/bin/sh
cd "$SRCDIR/share/syscons/keymaps" && exec "$b/kbdcontrol/kbdcontrol" "\$@"
EOF
	chmod 755 "$HOSTBIN/kbdcontrol"
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
	local res
	res=$("$clang" -print-resource-dir)/include
	cat > "$HOSTBIN/xcc" <<EOF
#!/bin/sh
# Drop gcc-only options that the gcc runtime makefiles pass.  For
# -fbuilding-libgcc, gcc predefines the target facts the unwinder reads
# (DWARF_FRAME_REGISTERS is 17 on x86_64, gcc/config/i386/i386.h); clang
# does not, so define the ones libgcc_eh uses.
n=\$#
while [ "\$n" -gt 0 ]; do
	a=\$1; shift; n=\$((n - 1))
	case \$a in
	-finhibit-size-directive|-gno-as-loc-support) ;;
	-fbuilding-libgcc) set -- "\$@" -D__LIBGCC_DWARF_FRAME_REGISTERS__=17 \\
	    -D__LIBGCC_STACK_GROWS_DOWNWARD__ -D__LIBGCC_EH_RETURN_STACKADJ_RTX__ ;;
	*) set -- "\$@" "\$a" ;;
	esac
done
# Headers: the sysroot's /usr/include first and clang's own headers
# (intrinsics, stdatomic.h) after it, the order DragonFly's base gcc
# uses.  clang's stddef.h, limits.h, stdarg.h, ... would otherwise shadow
# the system ones, which pull in <sys/cdefs.h> (__unused, __dead2).
# --undefined-version: like GNU ld, accept version scripts that name
# symbols a given configuration does not build (e.g. hesiod in libc).
# Old-C diagnostics that recent clang makes errors are warnings in the
# tree's gcc 12: incompatible (function) pointer types (GNU grep's
# obstack.c, K&R code in tcp_wrappers), int-conversion, implicit int and
# implicit function declarations.
# -gno-as-loc-support: gcc 12's libstdc++ asks gcc not to rely on the
# assembler's .loc directives (cxx11-ios_failure.cc); clang has no such
# option and needs none.
# -ffile-prefix-map: __FILE__ (assert messages) and debug info name the
# sources as a native build does (/usr/src, /usr/obj), not this host's
# checkout and object tree.
exec "$xtool/bin/clang" --target=x86_64-unknown-dragonfly \\
	--sysroot="$SYSROOT" -nobuiltininc -idirafter "$res" \\
	-ffile-prefix-map="$SRCDIR"=/usr/src -ffile-prefix-map="$OBJDIR"=/usr/obj \\
	-fuse-ld=lld -Wl,--undefined-version \\
	-Wno-error=incompatible-function-pointer-types \\
	-Wno-error=incompatible-pointer-types -Wno-error=int-conversion \\
	-Wno-error=implicit-int -Wno-error=implicit-function-declaration \\
	-Qunused-arguments -Wno-unknown-warning-option "\$@"
EOF
	chmod 755 "$HOSTBIN/xcc"
	# C++: clang's DragonFly driver finds the headers that
	# gnu/lib/gcc80/libstdc++ installs in /usr/include/c++/8.0.  Up to
	# clang 18 a constexpr function that can never be constant is an
	# error; gcc 8's <cmath> has some (they call non-constexpr builtins).
	# gcc 12's libstdc++ (random.cc) calls gcc's name for the RDSEED
	# builtin, which clang calls __builtin_ia32_rdseed32_step.  Sized
	# deallocation (operator delete(void *, size_t), which gcc 12's
	# floating_from_chars.cc calls) is on by default in gcc from C++14
	# and in clang only from clang 19.
	cat > "$HOSTBIN/xc++" <<'EOF'
#!/bin/sh
exec "$(dirname "$0")/xcc" --driver-mode=g++ -Wno-invalid-constexpr \
	-fsized-deallocation \
	-D__builtin_ia32_rdseed_si_step=__builtin_ia32_rdseed32_step "$@"
EOF
	chmod 755 "$HOSTBIN/xc++"
}

# The kernel compiler for KERNCC=clang: host clang for the DragonFly
# target, so the predefines (__DragonFly__, no __linux__) and the defaults
# (no PIE, no host hardening specs) are the target's own rather than
# undone flag by flag as in the gcc wrapper.  The kernel makefiles'
# clang settings (CCVER=clang) are used as they are, except:
#	-no-integrated-as	kern.pre.mk asks old clang for the external as;
#				the integrated assembler is the one that knows
#				the target, the host's GNU as does not.
#	-mindirect-branch=thunk-inline	gcc's retpoline flag (Spectre v2);
#				clang's equivalent is -mretpoline, with the
#				thunks in COMDAT sections of each object.
# The kernel and modules link through this driver with the host's GNU ld
# (ld.bfd) as with gcc: the kernel's linker script and program headers
# are what GNU ld makes of them (lld lays out the PHDRS differently).
# xgcc: the host gcc as a compiler for the DragonFly target, for the C
# parts of gcc 12's runtime (gnu/lib/gcc120: crtbegin/crtend, libgcc,
# the unwinder, libssp, libatomic, libgcov, libgomp).  They need gcc
# itself: what it predefines for -fbuilding-libgcc, mode attributes and
# builtins that clang lacks.  A gcc for x86_64 Linux and the tree's gcc
# 12 for x86_64 DragonFly generate the same code for them (both ELF and
# the SysV ABI); the differences are the predefined system macros and the
# headers, which xgcc replaces with DragonFly's (the sysroot, then the
# host gcc's own intrinsics and gcc 12's in /usr/libdata/gcc120), and the
# hardening defaults of Linux distributions, which it turns off as the
# DragonFly gcc has them.  Only compiling goes to gcc: links (libatomic,
# libgomp and libssp are shared too) go to xcc, which links for the
# target.  Warnings stay warnings: the host gcc is newer than gcc 12.
write_xgcc_wrapper() {
	local gcc inc
	gcc=$(command -v "${HOST_GCC:-gcc}") || die "no host gcc"
	inc=$("$gcc" -print-file-name=include)
	cat > "$HOSTBIN/xgcc" <<EOF
#!/bin/sh
for a; do
	case \$a in
	-c|-S|-E|-M|-MM) exec "$gcc" -nostdinc -isystem "$SYSROOT/usr/include" \\
		-idirafter "$inc" -idirafter "$SYSROOT/usr/libdata/gcc120" \\
		-U__linux__ -U__linux -Ulinux -U__gnu_linux__ -D__DragonFly__ \\
		-fno-pie -fcf-protection=none -fno-stack-clash-protection \\
		-U_FORTIFY_SOURCE -fno-stack-protector \\
		-ffile-prefix-map="$SRCDIR"=/usr/src -ffile-prefix-map="$OBJDIR"=/usr/obj \\
		"\$@" -Wno-error -Wno-system-headers ;;
	esac
done
exec "$HOSTBIN/xcc" "\$@"
EOF
	chmod 755 "$HOSTBIN/xgcc"
}

write_kcc_wrapper() {
	local clang
	if ! clang=$(command -v "${HOST_CLANG:-clang}"); then
		rm -f "$HOSTBIN/kcc"
		return 0
	fi
	cat > "$HOSTBIN/kcc" <<EOF
#!/bin/sh
n=\$#
while [ "\$n" -gt 0 ]; do
	a=\$1; shift; n=\$((n - 1))
	case \$a in
	-no-integrated-as) continue ;;
	-mindirect-branch=thunk-inline) a=-mretpoline ;;
	esac
	set -- "\$@" "\$a"
done
exec "$clang" --target=x86_64-unknown-dragonfly -fno-pie -fuse-ld=bfd \\
	-Qunused-arguments "\$@"
EOF
	chmod 755 "$HOSTBIN/kcc"
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
	build_bootstrap_tools
	build_makefs
	write_xcc_wrapper
	write_kcc_wrapper
	write_xgcc_wrapper
	echo "$TOOLS_STAMP" > "$HOSTBIN/.done"
}

# makefs(8) from usr.sbin/makefs, for `build.sh disk`: it writes a UFS
# file system image from an mtree manifest, so the files get root:wheel
# and their modes without root privileges.  Only the ffs back end is
# built (tools/linux/makefs/stubs.c stands in for the others).  Its
# kernel headers (the UFS on-disk structures, sbuf) are copied into a
# directory of their own: the rest of sys/ must not shadow the host's.
build_makefs() {
	local m=$SRCDIR/usr.sbin/makefs inc=$HOSTOBJ/makefs/include o=$HOSTOBJ/makefs
	local bsd f srcs
	bsd=$(pkg-config --cflags --libs libbsd-overlay)
	rm -rf "$o"
	mkdir -p "$inc/vfs/ufs" "$inc/sys"
	cp -R "$SRCDIR/tools/linux/makefs/include/." "$inc/"
	for f in dinode.h dir.h fs.h ufs_types.h; do
		cp "$SRCDIR/sys/vfs/ufs/$f" "$inc/vfs/ufs/"
	done
	cp "$SRCDIR/sys/sys/sbuf.h" "$inc/sys/"
	srcs="$m/makefs.c $m/walk.c $m/mtree.c $m/ffs.c $m/ffs/buf.c
	    $m/ffs/ffs_alloc.c $m/ffs/ffs_balloc.c $m/ffs/ffs_bswap.c
	    $m/ffs/ffs_subr.c $m/ffs/mkfs.c $m/ffs/ufs_bmap.c
	    $SRCDIR/sys/vfs/ufs/ffs_tables.c
	    $SRCDIR/usr.sbin/mtree/getid.c $SRCDIR/usr.sbin/mtree/misc.c
	    $SRCDIR/usr.sbin/mtree/spec.c $SRCDIR/usr.sbin/mtree/stat_flags.c
	    $SRCDIR/usr.sbin/mtree/pack_dev.c $SRCDIR/lib/libutil/efun.c
	    $SRCDIR/lib/libc/stdlib/strsuftoll.c $SRCDIR/sys/kern/subr_sbuf.c
	    $SRCDIR/tools/linux/makefs/stubs.c"
	# __DragonFly__: makefs's ffs code has DragonFly-only branches (no
	# UFS2, vnode fields).  LIBBSD_NETBSD_VIS: the NetBSD strnunvis(3)
	# argument order, which DragonFly's <vis.h> has.
	(cd "$o" && $HOST_CC $HOST_CFLAGS -std=gnu17 -w \
	    -include "$SRCDIR/tools/linux/host-compat.h" \
	    -include "$SRCDIR/tools/linux/makefs/makefs-compat.h" \
	    -I"$m" -I"$SRCDIR/usr.sbin/mtree" -I"$inc" \
	    -D__DragonFly__ -DLIBBSD_NETBSD_VIS -DMAKEFS \
	    -DHAVE_NBTOOL_CONFIG_H=0 -DHAVE_NETDB_H=1 \
	    -DHAVE_STRUCT_STAT_BIRTHTIME=0 -DHAVE_STRUCT_STAT_ST_FLAGS=0 \
	    -DHAVE_STRUCT_STAT_ST_MTIMENSEC=0 -DHAVE_STRUCT_STATVFS_F_IOSIZE=0 \
	    -o "$HOSTBIN/makefs" $srcs $bsd)
}

# Bump when the host tools or shims change, so an existing $OBJDIR gets
# them rebuilt instead of failing with old ones (install -C/-B, chflags).
TOOLS_STAMP=22

kenv() {
	[ "$(cat "$HOSTBIN/.done" 2>/dev/null)" = "$TOOLS_STAMP" ] || do_tools
	PATH=$HOSTBIN:$PATH
	MACHINE=x86_64 MACHINE_ARCH=x86_64 MACHINE_PLATFORM=pc64
	CCVER=gcc120 HOST_CCVER=gcc120 HOST_BINUTILSVER=binutils234
	KBDCONTROL=$HOSTBIN/kbdcontrol
	export PATH MACHINE MACHINE_ARCH MACHINE_PLATFORM CCVER HOST_CCVER \
	    HOST_BINUTILSVER KBDCONTROL
	# Make variables for the kernel and module builds.  kmod.mk falls
	# back to ${DESTDIR}/usr/include for standard headers until the
	# module's "dragonfly" link exists (during depend): on this host that
	# must be the sysroot's DragonFly headers, never the Linux
	# /usr/include.  Nothing is installed, so DESTDIR has no other
	# effect.  The directory must exist (amdgpu builds with
	# -Werror=missing-include-dirs) even when the kernel is built before
	# `build.sh sysroot`: empty, it still keeps the host's headers out.
	# KERNCC=clang compiles with kcc (see write_kcc_wrapper).
	# FASTER_DEPEND: the kernel's objects are compiled with -MD, whose
	# .d files keep its dependencies current between incremental builds
	# (do_kernel).
	mkdir -p "$SYSROOT/usr/include"
	KMAKE="DESTDIR=$SYSROOT FASTER_DEPEND=1"
	case ${KERNCC:-gcc} in
	gcc)	;;
	clang)	[ -x "$HOSTBIN/kcc" ] ||
		    die "KERNCC=clang: no kcc (install clang, then run build.sh tools)"
		KMAKE="$KMAKE CCVER=clang CC=kcc" ;;
	*)	die "KERNCC must be gcc or clang, not $KERNCC" ;;
	esac
}

# The kernel is built incrementally: its object directory is kept, so
# only what changed is compiled again.  Bump this when its objects must
# be rebuilt from scratch instead (and it also is when KERNCC changes).
# 2: compiled with FASTER_DEPEND (-MD), whose .d files the incremental
# builds read; older objects have none.
KERNEL_STAMP=2

do_kernel() {
	local conf=${1:-X86_64_GENERIC} kobj stamp
	kenv
	kobj=$OBJDIR/sys/$conf
	stamp="$KERNEL_STAMP ${KERNCC:-gcc}"
	[ -f "$SRCDIR/sys/config/$conf" ] || die "no such KERNCONF: $conf"
	if [ "$(cat "$kobj/.foxyn-kernel" 2>/dev/null)" = "$stamp" ]; then
		msg "configuring $conf in $kobj (incremental)"
	else
		msg "configuring $conf in $kobj (from scratch)"
		rm -rf "$kobj"
	fi
	mkdir -p "$OBJDIR/sys"
	# config(8) rewrites only the files whose contents change, so the
	# objects that do not depend on a changed option are kept.
	( cd "$SRCDIR/sys/config" && config -d "$kobj" "$conf" )
	echo "$stamp" > "$kobj/.foxyn-kernel"
	# depend also covers the modules, before the kernel is built: once
	# the kernel's objdir has the generated *_if.c, kmod.mk no longer
	# makes them for the modules.  A configuration without INET (MINI64)
	# builds a kernel but no modules.  This takes a while, so it runs
	# for a new object directory and when config(8) wrote a new
	# Makefile (files or options came or went).  Otherwise the
	# dependencies come from the .d files that the compiler writes next
	# to each object (FASTER_DEPEND, see kenv): they are up to date
	# for everything that was compiled, even by a build that failed.
	if [ -f "$kobj/.depend_done" ] && ! [ "$kobj/Makefile" -nt "$kobj/.depend_done" ]; then
		( cd "$kobj" && cat ./*.d > .depend 2>/dev/null || : )
	else
		msg "make depend"
		if kconf_modules "$conf"; then
			( cd "$kobj" && make $KMAKE KERNEL=kernel depend )
		else
			( cd "$kobj" && make $KMAKE NO_MODULES=1 KERNEL=kernel depend )
		fi
		: > "$kobj/.depend_done"
	fi
	msg "make all (-j$JOBS)"
	if grep -q '^platform[[:space:]]*vkernel' "$SRCDIR/sys/config/$conf"; then
		# A virtual kernel is a DragonFly program: its objects are
		# kernel code, but it links against libc and libpthread, so
		# the link step uses xcc and the sysroot instead of the host's
		# linker and glibc.
		vkernel_libs
		( cd "$kobj" && make -j"$JOBS" $KMAKE NO_MODULES=1 KERNEL=kernel \
		    SYSTEM_LD='@xcc ${ELDFLAGS} ${DEBUG} -o ${.TARGET} ${SYSTEM_OBJS} vers.o -pthread' \
		    all )
	else
		( cd "$kobj" && make -j"$JOBS" $KMAKE NO_MODULES=1 KERNEL=kernel all )
	fi
	msg "kernel: $kobj/kernel.debug"
}

# Whether a kernel configuration can build the modules (MINI64 cannot).
kconf_modules() {
	grep -q '^options[[:space:]]*INET\b' "$SRCDIR/sys/config/$1"
}

# The libraries a virtual kernel links against, built if missing.
vkernel_libs() {
	[ -f "$SYSROOT/usr/lib/libc.so" ] || ( do_libc )
	[ -f "$SYSROOT/usr/lib/libpthread.so" ] ||
	    ( wenv; world_lib lib/libthread_xu && world_lib lib/libpthread )
	kenv
}

do_modules() {
	local conf=${1:-X86_64_GENERIC} kobj
	kenv
	kobj=$OBJDIR/sys/$conf
	[ -f "$kobj/kernel.debug" ] || do_kernel "$conf"
	msg "building modules (-j$JOBS)"
	kconf_modules "$conf" || die "$conf builds no modules (no INET)"
	( cd "$kobj" && make -j"$JOBS" $KMAKE KERNEL=kernel modules )
}

# Stage the DragonFly headers into $SYSROOT/usr/include: the ones that
# include/Makefile's "copies" target copies (stage_headers), then the
# ones that include/ and the libraries install themselves.  Run again,
# it updates the headers that changed and leaves the rest alone, their
# mtimes included, so only what includes a changed header is compiled
# again.  It starts from an empty directory when HEADERS_STAMP changed.
do_sysroot() {
	local inc=$SYSROOT/usr/include d
	if headers_ok; then
		msg "updating the headers in $inc"
	else
		msg "staging headers into $inc"
		rm -rf "$inc"
	fi
	mkdir -p "$inc"
	stage_headers

	# The rest is what buildworld's "includes" stage does: create the
	# directory tree from the mtree spec (mtree(8) is not available on
	# Linux, so read the spec with awk), then let every directory under
	# include/ and lib/ install its own headers.  Generated headers, such
	# as the rpcgen output for include/rpc, come from the same rules.
	mtree_dirs "$SRCDIR/etc/mtree/BSD.root.dist" "$SYSROOT"
	mtree_dirs "$SRCDIR/etc/mtree/BSD.usr.dist" "$SYSROOT/usr"
	mtree_dirs "$SRCDIR/etc/mtree/BSD.var.dist" "$SYSROOT/var"
	mtree_dirs "$SRCDIR/etc/mtree/BSD.include.dist" "$inc"
	(
	wenv
	for d in include/arpa include/protocols include/rpc include/rpcsvc \
	    include/xlocale lib gnu/lib; do
		msg "installing headers from $d"
		( cd "$SRCDIR/$d" && make obj >/dev/null &&
		  make -j"$JOBS" DESTDIR="$SYSROOT" buildincludes &&
		  make DESTDIR="$SYSROOT" installincludes )
	done
	)
	echo "$HEADERS_STAMP" > "$SYSROOT/.headers_done"
}

# The headers that include/Makefile's "copies" target copies, done by
# hand because that target needs mtree(8), cpdup(1) and BSD install(1)
# semantics.  They are put together in a directory of their own first,
# as machine/ is cpu/'s headers overlaid with the platform's, and only
# the ones that differ from the sysroot's are copied there.  The world
# commands run this before they build, so a header edited in the tree
# reaches the sysroot without a `build.sh sysroot`.
stage_headers() {
	local inc=$OBJDIR/sysroot-headers s=$SRCDIR/sys d f mk ldirs lsubdirs
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
	sync_tree "$inc" "$SYSROOT/usr/include"
}

# Bump when do_sysroot stages headers differently, so sysroots made by an
# older build.sh are restaged instead of silently missing files (e.g. the
# rpcsvc/*.x that libc's `make depend` needs).
HEADERS_STAMP=5
headers_ok() {
	[ "$(cat "$SYSROOT/.headers_done" 2>/dev/null)" = "$HEADERS_STAMP" ]
}

# Before the world commands build: the sysroot's headers, current.
# Restaged from scratch when HEADERS_STAMP changed, else the copied ones
# that changed in the tree are copied again (stage_headers); the ones a
# library installs are updated when it is built.
headers_current() {
	[ -z "${HEADERS_CURRENT:-}" ] || return 0
	if headers_ok; then stage_headers; else do_sysroot; fi
	HEADERS_CURRENT=1
}

# Copy the tree $1 over the tree $2.  A file or symlink that is the same
# in both is left alone, mtime included; nothing is deleted from $2.
sync_tree() {
	local f
	(cd "$1" && find . -type d) | while read -r f; do
		mkdir -p "$2/$f"
	done
	(cd "$1" && find . ! -type d) | while read -r f; do
		if [ -L "$1/$f" ]; then
			[ "$(readlink "$1/$f")" = "$(readlink "$2/$f" 2>/dev/null)" ] &&
			    continue
		elif [ ! -L "$2/$f" ] && cmp -s "$1/$f" "$2/$f"; then
			continue
		fi
		rm -f "$2/$f"
		cp -P "$1/$f" "$2/$f"
	done
}

# Write standard input to the file $1 unless it already has these
# contents: an unchanged generated file keeps its mtime, so make does not
# rebuild what depends on it.
write_changed() {
	cat > "$1.new" || return
	if cmp -s "$1.new" "$1"; then
		rm -f "$1.new"
	else
		mv -f "$1.new" "$1"
	fi
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
	CXX=xc++
	MAKEOBJDIRPREFIX=$OBJDIR/world
	# Build-time helpers (ncurses' make_keys, gcc's generators, ...) run
	# on this host.  share/mk builds them with ${NXENV} ${CC} (or ${CXX},
	# and makefiles such as cc80's libcpp switch CC to CXX), so NXENV
	# turns xcc into hostcc and xc++ into hostc++.  Its default would
	# also reset PATH and drop the shims.
	NXENV=nxenv
	unset NXCC NXCC_LINK NXCXX NXCXX_LINK
	# Where buildworld's makefiles look for already-installed libraries
	# and private headers (e.g. usr/include/priv/ncurses).
	_SHLIBDIRPREFIX=$SYSROOT
	# Scripts that sort or compare file lists (kdump's mkioctls, ...)
	# expect the C collation of a BSD host.
	LC_ALL=C
	# What C++ programs link, for their dependencies (bsd.prog.mk): the
	# C++ runtime of clang's DragonFly driver is gcc 8's, not one in
	# GCCLIBDIR (/usr/lib/clang).  A dependency on a file that does not
	# exist would relink them on every build.
	LIBSTDCPLUSPLUS=$SYSROOT/usr/lib/gcc80/libstdc++.a
	# usr.sbin/installer (the BSD Installer) is built only for release
	# media (nrelease sets it); the live image is release media.
	WANT_INSTALLER=yes
	export CCVER CC CXX MAKEOBJDIRPREFIX NXENV _SHLIBDIRPREFIX
	export LC_ALL WANT_INSTALLER LIBSTDCPLUSPLUS
	mkdir -p "$MAKEOBJDIRPREFIX"
}

# Userland libraries, starting from the bottom: csu, then libc.
do_libc() {
	headers_current
	wenv
	[ -x "$HOSTBIN/xcc" ] ||
	    die "xcc missing: install clang and lld, then run build.sh tools"
	world_lib lib/csu
	install_compiler_rt
	world_lib lib/libc
}

# The smallest userland that boots to a login prompt through the tree's
# /etc/rc, in build order: the runtime linker and the libraries first,
# then init, sh, login and the utilities rc.subr and rc.d call.  LibreSSL
# (libcrypto, libssl) and libfetch come with what needs them: csh,
# mtree, dhcpcd (the network at boot), fetch and openssl.  The installer
# (tools/linux/foxyn-install) uses gpt, newfs_msdos, newfs_hammer2,
# newfs, mount_msdos, mount_hammer2 (which runs hammer2), cpdup, kenv
# and dd.
BASE_LIBS="lib/libc_rtld libexec/rtld-elf lib/libutil lib/libcrypt
	lib/libncurses lib/libedit lib/libm lib/libkvm lib/libypclnt
	lib/libpam/libpam lib/libpam/modules lib/libexpat lib/libsbuf
	gnu/usr.bin/grep/libgreputils usr.bin/awk/maketab
	usr.bin/flex/lib gnu/lib/gcc80/libgcc_eh gnu/lib/gcc80/libstdc++/headers
	gnu/lib/gcc80/libstdc++/components gnu/lib/gcc80/libstdc++/product
	lib/librecrypto lib/libressl lib/libfetch lib/libkinfo lib/libnetgraph
	lib/libkiconv lib/libpthread lib/libdmsg"
BASE_PROGS="sbin/init bin/sh bin/cat bin/chmod bin/cp bin/date bin/df
	bin/echo bin/expr bin/hostname bin/kill bin/ln bin/ls bin/mkdir bin/mv
	bin/ps bin/pwd bin/rm bin/rmdir bin/sleep bin/stty bin/test bin/varsym
	sbin/adjkerntz sbin/devd sbin/devfsctl sbin/dmesg sbin/fsck sbin/ifconfig sbin/kldload sbin/kldstat
	sbin/kldunload
	sbin/ldconfig sbin/mount sbin/mount_tmpfs sbin/mount_ufs sbin/rcorder sbin/reboot
	sbin/route sbin/swapon sbin/sysctl sbin/umount
	libexec/getty usr.bin/awk/awk usr.bin/basename usr.bin/cmp usr.bin/find
	gnu/usr.bin/grep/grep usr.bin/head usr.bin/id usr.bin/logger
	usr.bin/login usr.bin/mktemp usr.bin/sed usr.bin/tail usr.bin/touch
	usr.bin/tr usr.bin/uname usr.bin/wc usr.bin/xargs usr.bin/xinstall
	usr.sbin/chown usr.sbin/cron/cron usr.sbin/cron/crontab gnu/usr.sbin/anacron usr.sbin/newsyslog usr.sbin/pwd_mkdb usr.sbin/syslogd
	usr.bin/diff usr.bin/lockf usr.bin/netstat usr.bin/sort usr.bin/tee
	usr.bin/w gnu/usr.bin/grep/egrep gnu/usr.bin/grep/fgrep usr.sbin/chkgrp
	usr.sbin/periodic
	bin/csh sbin/dhcpcd usr.bin/fetch usr.bin/openssl usr.sbin/mtree
	bin/cpdup sbin/gpt sbin/newfs sbin/newfs_msdos sbin/newfs_hammer2
	sbin/mount_hammer2 sbin/mount_msdos usr.bin/kenv bin/dd sbin/hammer2"

# Modules rc.local loads and unloads to test the kernel linker.  snd_hda
# brings sound.ko, whose unload panicked an INVARIANTS kernel when
# /dev/sndstat had never been opened (sndstat.c); it loads without the
# hardware.
KLD_TESTS="udf ext2fs snd_hda"
# Kernel modules that the loader loads at every boot: the ESP and the
# image's /boot (which the installers copy) always have them.
BOOT_MODULES="bus/u4b/controller/ehci bus/u4b/controller/xhci"

# PAM modules that /etc/pam.d/login, system and crond load.  login(1) and
# cron(8) open them with dlopen(3), so they are not in any NEEDED list.
PAM_MODULES="pam_lastlog pam_login_access pam_nologin pam_permit pam_securetty
	pam_self pam_unix"

do_base() {
	local d
	headers_current
	# Always: lib/libc's makefile rebuilds only what changed (a new
	# system call or Symbol.map entry), and install -C leaves an
	# unchanged libc.so alone.
	do_libc
	wenv
	for d in $BASE_LIBS $BASE_PROGS; do
		world_dir "$d"
	done
}

# world_lib with the settings a few directories need on this host.
world_dir() {
	case $1 in
	# libtic and tic_next only serve share/terminfo.
	lib/libncurses)	world_lib "$1" NO_SHARE=yes ;;
	# LD_DEBUG=1 support, for when a dynamic program fails to start.
	libexec/rtld-elf) world_lib "$1" ENABLE_DEBUG=yes ;;
	# Static like init, so the image always gets a working shell
	# (and its /etc/rc runs) even if dynamic linking is broken.
	bin/sh)		world_lib "$1" NOSHARED=yes ;;
	# In an object tree of its own: gcc_prep's stand-in gcc headers
	# must not reach the real gcc build (gnu/usr.bin/cc80).
	gnu/lib/gcc80/libgcc_eh)
		( MAKEOBJDIRPREFIX=$OBJDIR/world-libgcc
		  export MAKEOBJDIRPREFIX; mkdir -p "$MAKEOBJDIRPREFIX"
		  gcc_prep; world_lib "$1" ) && gcc_pic_unwind ;;
	gnu/usr.bin/cc80) gcc_prep_clean; world_lib "$1" ;;
	gnu/lib/gcc120)	world_gcc120 ;;
	usr.bin/ruby)	world_ruby ;;
	*)		world_lib "$1" ;;
	esac
}

# The whole userland, in buildworld's order (Makefile.inc1): the startup
# and compiler libraries, the _prebuild_libs that others link against,
# every other library, then the programs.  Each top-level directory is
# walked one SUBDIR level deep, so with KEEP_GOING=1 a failing directory
# is recorded and the rest still builds; the failures are listed at the
# end (and the command fails).  Without it the first failure stops.
#
# Left out: gcc 8's csu and libgcc (lib/libcompiler_rt stands in, see
# install_compiler_rt); the C++ runtime the world links is gcc 8's, as in
# `base`.  gcc 12's runtime (gnu/lib/gcc120), which the image's own cc
# links with, is built last (world_gcc120).
WORLD_PREBUILD="lib/libc_rtld gnu/lib/gcc80/libgcc_eh
	lib/libbz2 lib/liblzma lib/libz lib/libzstd lib/libutil lib/libpcap
	lib/libcrypt lib/libncurses lib/libncurses/libtic
	lib/libncurses/tic_next lib/librecrypto lib/libressl lib/libldns
	lib/libsbuf lib/libm lib/libpam/libpam lib/libypclnt lib/libprop
	gnu/lib/gcc80/libstdc++/headers gnu/lib/gcc80/libstdc++/components
	gnu/lib/gcc80/libstdc++/product"
WORLD_TOP="gnu/lib lib usr.bin/flex/lib libexec bin sbin usr.bin usr.sbin
	gnu/usr.bin gnu/usr.sbin games share"
WORLD_SKIP="lib/csu lib/libc gnu/lib/gcc80 gnu/lib/gcc120"

do_world() {
	local d top subs failed= seen=
	headers_current
	do_libc		# as in do_base
	wenv
	world_try() {
		case " $WORLD_SKIP $seen " in *" $1 "*) return 0 ;; esac
		seen="$seen $1"
		world_dir "$1" && return 0
		[ -n "${KEEP_GOING:-}" ] || die "world: $1 failed"
		failed="$failed $1"
	}
	for d in $WORLD_PREBUILD; do world_try "$d"; done
	for top in $WORLD_TOP; do
		subs=$(world_subdirs "$top")
		# A leaf (usr.bin/flex/lib) is built itself.
		[ -n "$subs" ] || { world_try "$top"; continue; }
		for d in $subs; do world_try "$top/$d"; done
	done
	# gcc 12's runtime last: it includes headers that gnu/usr.bin/cc120
	# generates (buildworld's _compiler_libs_gcc120 stage builds them
	# first for the same reason).
	world_dir gnu/lib/gcc120 || {
		[ -n "${KEEP_GOING:-}" ] || die "world: gnu/lib/gcc120 failed"
		failed="$failed gnu/lib/gcc120"
	}
	if [ -n "$failed" ]; then
		msg "world: these directories failed:"
		for d in $failed; do echo "	$d" >&2; done
		return 1
	fi
	# build.sh rootfs puts the whole world in the image from now on.
	: > "$SYSROOT/.world_done"
	msg "world: done"
}

# gcc 12's runtime in /usr/lib/gcc120, /usr/libdata/gcc120 and
# /usr/include/c++/12.0: what the image's cc (gcc 12, DragonFly's default
# compiler) links programs with.  It is gcc's own code, built here as
# buildworld builds it, except for the compilers: the C parts with xgcc
# (the host gcc for the DragonFly target, see write_xgcc_wrapper), which
# also takes the makefiles' gcc options (CCVER=gcc120); libstdc++, as
# gcc 8's, with xc++ (clang): host g++ releases newer than gcc 12 do not
# all compile its exception support (an internal compiler error in gcc
# 16 on libsupc++'s eh_call.cc).  csu and libgcc need the headers that
# gnu/usr.bin/cc120 generates (cc_prep, cc_tools), so this runs after it.
GCC120_C="csu libgcc libgcc_eh libgcc_pic libssp_nonshared libssp libatomic
	libgcov libgomp"
GCC120_CXX="libstdc++/headers libstdc++/components libstdc++/product libstdc++fs"
world_gcc120() {
	local d g=gnu/lib/gcc120 o
	[ -f "$MAKEOBJDIRPREFIX$SRCDIR/gnu/usr.bin/cc120/cc_prep/tm.h" ] ||
	    die "$g needs gnu/usr.bin/cc120 built first (build.sh world)"
	mkdir -p "$SYSROOT/usr/lib/gcc120/profile" "$SYSROOT/usr/libdata/gcc120"
	for d in $GCC120_C; do
		if [ $d = libssp ]; then
			# Its sources include <ssp/ssp.h>, which it installs.
			o=$(cd "$SRCDIR/$g/$d" && make obj >/dev/null &&
			    make CCVER=gcc120 CC=xgcc ssp.h >/dev/null &&
			    make CCVER=gcc120 -V .OBJDIR) || return
			install -D -m 444 "$o/ssp.h" "$SYSROOT/usr/libdata/gcc120/ssp/ssp.h"
		fi
		WORLD_CCVER=gcc120 world_lib "$g/$d" CC=xgcc || return
	done
	for d in $GCC120_CXX; do
		world_lib "$g/$d" || return
	done
}

# Ruby (usr.bin/ruby, contrib/ruby) for the target.  Ruby's configure
# cross-compiles with a Ruby that runs on this host (BASERUBY), which runs
# the build's generators, the extensions' extconf.rb and the installation
# of the default and bundled gems in place of the Ruby being built.  It
# must be the same Ruby: the install runs the tree's lib/ (RubyGems 4,
# Pathname in the core) in it.  So BASERUBY is built first, for this
# host, from contrib/ruby (a release builds without a Ruby), into
# $HOSTOBJ/ruby; the host needs no Ruby of its own.
host_ruby() {
	local o=$HOSTOBJ/ruby-build p=$HOSTOBJ/ruby v
	v=$(sed -n 's/^#define RUBY_VERSION_TEENY \([0-9]*\)/\1/p' "$SRCDIR/contrib/ruby/version.h")
	v=$(sed -n 's/^#define RUBY_API_VERSION_MAJOR \([0-9]*\)/\1/p;s/^#define RUBY_API_VERSION_MINOR \([0-9]*\)/\1/p' \
	    "$SRCDIR/contrib/ruby/include/ruby/version.h" | tr '\n' .)$v
	if [ "$(cat "$p/.version" 2>/dev/null)" = "$v" ] && [ -x "$p/bin/ruby" ] &&
	    [ -s "$o/builtin_binary.rbbin" ]; then
		return 0
	fi
	msg "building Ruby $v for this host (BASERUBY)"
	rm -rf "$o" "$p"; mkdir -p "$o"
	# Without the shims and the world's settings: a plain host build.
	( PATH=$(echo "$PATH" | tr ':' '\n' | grep -vx "$HOSTBIN" | paste -sd:)
	  unset MAKEOBJDIRPREFIX MAKEFLAGS MACHINE MACHINE_ARCH MACHINE_PLATFORM \
	      CCVER CC CXX NXENV _SHLIBDIRPREFIX WANT_INSTALLER
	  cd "$o" && "$SRCDIR/contrib/ruby/configure" --prefix="$p" \
	      --disable-install-doc --disable-yjit --disable-zjit --without-gmp \
	      --disable-shared CC="$HOST_CC" >configure.log 2>&1 &&
	  make -j"$JOBS" >make.log 2>&1 && make install-nodoc >install.log 2>&1 ) ||
	    die "building the host Ruby failed: see $o/*.log"
	echo "$v" > "$p/.version"
}

world_ruby() {
	host_ruby
	# The host build's precompiled core library (see usr.bin/ruby).  And
	# the flags that configure found clang (xcc) takes and the image's cc
	# (gcc 12), which builds the gems' extensions, rejects: usr.bin/ruby
	# removes them from the installed rbconfig.rb.
	world_lib usr.bin/ruby \
	    "RUBY_CONFIGURE_ARGS=--host=x86_64-unknown-dragonfly --build=x86_64-pc-linux-gnu --with-baseruby=$HOSTOBJ/ruby/bin/ruby" \
	    "RUBY_BUILTIN_BINARY=$HOSTOBJ/ruby-build/builtin_binary.rbbin" \
	    "RUBY_RBCONFIG_DROP=-fdeclspec -Wextra-tokens -Wdivision-by-zero -Wshorten-64-to-32"
}

# The SUBDIR list of a directory's Makefile, as its make sees it.
world_subdirs() {
	(cd "$SRCDIR/$1" && make CCVER=clang -V SUBDIR)
}

# Dynamically linked C++ programs link -lgcc_pic (clang's DragonFly
# driver, like base gcc), and libstdc++.so leaves the unwinder
# (_Unwind_*) to it: gnu/lib/gcc80/libgcc_pic is libgcc plus the
# unwinder with default visibility.  libgcc's C parts need gcc's machine
# modes and do not build with clang, so take compiler-rt's builtins
# (libgcc.a, see install_compiler_rt) and add the unwinder built from
# libgcc_eh's sources the way libgcc_pic builds them (-DSHARED, exported).
# It is built in its own object tree, next to the hidden libgcc_eh one.
gcc_pic_unwind() {
	local o=$OBJDIR/world-pic dst=$SYSROOT/usr/lib/gcc80 eh
	cat > "$HOSTBIN/xcc-pic" <<'EOF'
#!/bin/sh
exec xcc "$@" -fvisibility=default -UHIDE_EXPORTS -DSHARED -D_AVOID_WEAKREF
EOF
	chmod 755 "$HOSTBIN/xcc-pic"
	msg "building the exported unwinder for libgcc_pic"
	( MAKEOBJDIRPREFIX=$o; export MAKEOBJDIRPREFIX; mkdir -p "$o"
	  gcc_prep
	  cd "$SRCDIR/gnu/lib/gcc80/libgcc_eh" && make obj >/dev/null &&
	  make CCVER=clang CC=xcc-pic depend >/dev/null &&
	  make -j"$JOBS" CCVER=clang CC=xcc-pic ) || return
	eh=$o$SRCDIR/gnu/lib/gcc80/libgcc_eh/libgcc_eh.a
	rm -f "$o/libgcc_pic.a"
	printf 'create %s\naddlib %s\naddlib %s\nsave\nend\n' \
	    "$o/libgcc_pic.a" "$dst/libgcc.a" "$eh" | ar -M
	ranlib "$o/libgcc_pic.a"
	# Unchanged, the installed one keeps its mtime: the C++ programs
	# that link it are not linked again.
	write_changed "$dst/libgcc_pic.a" < "$o/libgcc_pic.a"
}

# The exception unwinder (libgcc_eh) that C++ programs such as devd(8)
# need.  It includes gcc's target headers, which in a real gcc build come
# from gnu/usr.bin/cc80: make the ones that are plain shell and awk
# output (tm.h, options.h) and write the few that gcc's generator
# programs would make.  libgcc_eh only uses FIRST_PSEUDO_REG from them,
# for array sizes in i386.h.
# An $OBJDIR made by an older build.sh has gcc_prep's stand-ins in the
# main object tree, where gnu/usr.bin/cc80 would use them.
gcc_prep_clean() {
	local d=$MAKEOBJDIRPREFIX$SRCDIR/gnu/usr.bin/cc80/cc_prep f
	for f in insn-modes.h libgcc_tm.h; do
		[ -s "$d/$f" ] || rm -f "$d/$f"
	done
	if [ -f "$d/insn-constants.h" ] &&
	    [ "$(wc -l < "$d/insn-constants.h")" = 1 ] &&
	    grep -q '^#define FIRST_PSEUDO_REG' "$d/insn-constants.h"; then
		rm -f "$d/insn-constants.h"
	fi
}

gcc_prep() {
	local d=$MAKEOBJDIRPREFIX$SRCDIR/gnu/usr.bin/cc80/cc_prep n
	( cd "$SRCDIR/gnu/usr.bin/cc80/cc_prep" && make obj >/dev/null &&
	  make CCVER=clang tm.h options.h >/dev/null )
	n=$(sed -n 's/.*(FIRST_PSEUDO_REG[[:space:]]*\([0-9]*\)).*/\1/p' \
	    "$SRCDIR/contrib/gcc-8.0/gcc/config/i386/i386.md")
	[ -n "$n" ] || die "FIRST_PSEUDO_REG not found in i386.md"
	echo "#define FIRST_PSEUDO_REG $n" | write_changed "$d/insn-constants.h"
	write_changed "$d/insn-modes.h" < /dev/null
	write_changed "$d/libgcc_tm.h" < /dev/null
}

# The base image: the programs of `build.sh base` (the library fixpoint
# in do_rootfs adds what they load) and the PAM modules login opens.
rootfs_base() {
	local root=$1 d f prog
	cp -p "$SYSROOT/libexec/ld-elf.so.2" "$root/libexec/"
	ln -s ../../libexec/ld-elf.so.2 "$root/usr/libexec/ld-elf.so.2"
	for d in $BASE_PROGS; do
		# PROGNAME: xinstall installs as "install".  SCRIPTS: periodic.sh
		# installs as "periodic".
		prog=$(cd "$SRCDIR/$d" &&
		    make -V '${PROGNAME:U${PROG:U${SCRIPTS:T:R}}}')
		# A directory of subdirectories (bin/csh: gethost, csh) is
		# named after its program.
		[ -n "$prog" ] || prog=${d##*/}
		# Files only: the sysroot also has an /etc/devd directory.
		f=$(cd "$SYSROOT" && for c in */"$prog" usr/*/"$prog"; do
			[ -f "$c" ] && echo "$c"; done | head -n 1) || :
		[ -n "$f" ] || die "$d: $prog not installed in the sysroot"
		cp -p "$SYSROOT/$f" "$root/$f"
	done
	# Links that bsd.prog.mk installs (halt -> reboot, ...).
	ln -s reboot "$root/sbin/halt"
	ln -s id "$root/usr/bin/whoami"
	ln -s id "$root/usr/bin/groups"
	ln -s test "$root/bin/["
	ln -s chown "$root/usr/sbin/chgrp"
	ln -s w "$root/usr/bin/uptime"
	ln -s csh "$root/bin/tcsh"
	# dhcpcd(8) runs its hooks (resolv.conf, hostname) through this script.
	mkdir -p "$root/usr/libexec/dhcpcd-hooks"
	cp -p "$SYSROOT/usr/libexec/dhcpcd-run-hooks" "$root/usr/libexec/"
	cp -p "$SYSROOT/usr/libexec/dhcpcd-hooks/"* "$root/usr/libexec/dhcpcd-hooks/"
	mkdir -p "$root/usr/lib/security"
	for f in $PAM_MODULES; do
		cp -pL "$SYSROOT/usr/lib/security/$f.so" "$root/usr/lib/security/"
	done
}

# Stage a root tree and pack it as a Rock Ridge ISO (root.iso) that the
# kernel mounts as cd9660; making it needs no root privileges.
#
# What goes in depends on ROOTFS.  "world" (the default) is everything
# `build.sh world` installs in the sysroot: the whole userland with its
# editors, pagers, man pages, ssh, compilers, ...; the world is built
# first if it has not been.  "base" is only the programs of `build.sh
# base` and the libraries they load: a small image that is quicker to
# build (CI's userland job).
do_rootfs() {
	local root=$OBJDIR/rootfs iso=$OBJDIR/root.iso d f prog lib
	local content=${ROOTFS:-world}
	case $content in
	world)	[ -f "$SYSROOT/.world_done" ] || ( do_world ) ;;
	base)	[ -x "$SYSROOT/bin/sh" ] || ( do_base ) ;;
	*)	die "ROOTFS must be world or base, not $content" ;;
	esac
	wenv
	msg "root image contents: $content"
	rm -rf "$root"
	mkdir -p "$root"
	if [ $content = world ]; then
		# The installed world as it is, symlinks included (they are
		# relative, see fix_sysroot_links); not the link to the host
		# compiler's headers or build.sh's stamps.
		cp -a "$SYSROOT/." "$root/"
		rm -f "$root/usr/lib/clang" "$root/.headers_done" "$root/.world_done"
	fi
	for d in bin sbin lib/priv libexec usr/bin usr/lib usr/libexec usr/sbin dev etc \
	    mnt root tmp var/db var/log var/run var/tmp; do
		mkdir -p "$root/$d"
	done
	mtree_dirs "$SRCDIR/etc/mtree/BSD.var.dist" "$root/var"
	chmod 1777 "$root/tmp" "$root/var/tmp"
	[ $content = world ] || rootfs_base "$root"
	# The tests run at boot go in first: their libraries are copied too.
	write_brand_tests "$root/root/tests"
	write_cxx_test "$root/root/tests"
	write_runtime_tests "$root/root/tests"
	write_net_test "$root/root/tests/net-check"
	write_cron_test "$root/root/tests/cron-check"
	write_cc_test "$root/root/tests/cc-check"
	write_ruby_test "$root/root/tests/ruby-check"
	write_pkg_test "$root/root/tests/pkg-check"
	write_desktop_test "$root/root/tests/desktop-check"
	write_audio_test "$root/root/tests/audio-check"
	# The kernel modules that `build.sh modules` built, without debug
	# information, in /boot/kernel as installkernel puts them: devd(8)
	# loads drivers from there when a device has none (ums for a USB
	# mouse, sound, network), and so does kldload(8).  Without
	# `build.sh modules`, only those of the ESP (BOOT_MODULES, below).
	# The kld test in rc.local loads and unloads those in KLD_TESTS.
	local ko kodir=$OBJDIR/sys/X86_64_GENERIC$SRCDIR/sys
	mkdir -p "$root/boot/kernel"
	if [ -d "$kodir" ]; then
		find "$kodir" -name '*.ko' | while read -r ko; do
			objcopy --strip-debug "$ko" "$root/boot/kernel/${ko##*/}"
		done
	fi
	printf '%s\n' $KLD_TESTS > "$root/root/tests/kld-modules"
	# What the installers put on the disk they install to: the EFI
	# loader and the boot tree of `build.sh esp` (dloader.rc, the
	# defaults, the kernel), in /boot as on an installed DragonFly system.
	local esp=$OBJDIR/esp/X86_64_GENERIC
	if [ -f "$esp/EFI/BOOT/BOOTX64.EFI" ] && [ -f "$esp/boot/kernel/kernel" ]; then
		mkdir -p "$root/boot/kernel" "$root/boot/defaults"
		cp "$esp/EFI/BOOT/BOOTX64.EFI" "$root/boot/loader.efi"
		# The BSD Installer's ESP gets boot1.efi, which starts
		# loader.efi from the installed /boot partition.
		[ -f "$(boot1_efi)" ] && cp "$(boot1_efi)" "$root/boot/boot1.efi"
		# disklabel64 -B (the BSD Installer) reads the BIOS boot blocks.
		for f in $(biosboot_files); do
			[ -f "$f" ] && cp "$f" "$root/boot/"
		done
		cp "$esp/boot/dloader.rc" "$root/boot/"
		cp "$esp/boot/defaults/"* "$root/boot/defaults/"
		cp "$esp/boot/kernel/kernel" "$root/boot/kernel/kernel"
		for f in $BOOT_MODULES; do
			f=$esp/boot/kernel/${f##*/}.ko
			[ -f "$f" ] && cp "$f" "$root/boot/kernel/"
		done
	else
		msg "no ESP from build.sh esp: the image cannot install itself"
	fi
	install -m 555 "$SRCDIR/tools/linux/foxyn-install" "$root/usr/sbin/foxyn-install"
	# Copy the shared libraries, following NEEDED entries to a fixpoint
	# (not for /boot: the kernel and its modules do not load them).
	# They are looked up where rtld looks: the standard directories and
	# the file's RUNPATH (/usr/lib/gcc80 for libstdc++, which clang's
	# DragonFly driver adds to every dynamic link).
	local added=1 dirs
	while [ "$added" = 1 ]; do
		added=0
		# One line per library that a file needs and the image lacks:
		# the file, the library, the directories it is looked up in.
		rootfs_missing_libs "$root" > "$OBJDIR/rootfs.missing"
		while IFS='	' read -r f lib dirs; do
			for d in $dirs; do
				d=${d#/}
				# Copied for an earlier file of this pass.
				[ -e "$root/$d/$lib" ] && continue 2
			done
			for d in $dirs; do
				d=${d#/}
				[ -e "$SYSROOT/$d/$lib" ] || continue
				mkdir -p "$root/$d"
				cp -pL "$SYSROOT/$d/$lib" "$root/$d/$lib"
				added=1
				continue 2
			done
			die "$f needs $lib, which is not in the sysroot"
		done < "$OBJDIR/rootfs.missing"
	done
	rm -f "$OBJDIR/rootfs.missing"
	# The world installs share/terminfo; the base image gets a few types.
	[ -d "$root/usr/share/terminfo/x" ] || write_terminfo "$root/usr/share/terminfo"
	write_etc "$root"
	# Login classes: init(8) looks up class "daemon" for /etc/rc.  With
	# no login.conf.db, getcap(3) reads the text file directly, so no
	# cap_mkdb run is needed on the build host.
	cp "$SRCDIR/etc/login.conf" "$root/etc/login.conf"
	# Users and groups.  getgrent(3) reads /etc/group as text, but the
	# password functions only read the hashed pwd.db and spwd.db, which
	# pwd_mkdb(8) cannot make on a Linux host: the image's rc.local.d
	# script builds them at boot, once /etc is a writable tmpfs.
	cp "$SRCDIR/etc/group" "$root/etc/group"
	# Root's shell is csh, as on DragonFly, when the image has it (the
	# world); the base image has only sh.
	if [ -x "$root/bin/csh" ]; then
		cp "$SRCDIR/etc/master.passwd" "$root/etc/master.passwd"
	else
		sed 's|^\(root:.*:\)/bin/csh$|\1/bin/sh|' \
		    "$SRCDIR/etc/master.passwd" > "$root/etc/master.passwd"
	fi
	chmod 600 "$root/etc/master.passwd"
	# Logins: init(8) starts getty(8) on the terminals in /etc/ttys once
	# /etc/rc exits, and login(1) checks the password through PAM.
	cp "$SRCDIR/etc/gettytab" "$SRCDIR/etc/login.access" "$root/etc/"
	# PAM policies for login, su, passwd, sshd, ... (etc/pam.d).
	mkdir -p "$root/etc/pam.d"
	(cd "$SRCDIR/etc/pam.d" && ls | grep -vx Makefile |
	    while read -r f; do cp "$f" "$root/etc/pam.d/$f"; done)
	write_ttys "$root/etc/ttys"
	[ -x "$root/usr/sbin/installer" ] && rootfs_installer "$root"
	if command -v xorriso >/dev/null 2>&1; then
		# -R keeps modes and symlinks (Rock Ridge); the volume is read-only.
		# Record the files as root:wheel rather than the building user.
		xorriso -as mkisofs -quiet -R -uid 0 -gid 0 -V FOXYNROOT \
		    -o "$iso" "$root"
		msg "root image: $iso (boot it with tools/linux/qemu.sh)"
	else
		msg "root tree: $root (install xorriso to pack root.iso)"
	fi
}

# The shared libraries that the files of the root tree $1 need (their
# NEEDED entries) and that are not in it, looked up where rtld looks:
# the standard directories and the file's RUNPATH.  One readelf reads
# many files, so this takes seconds for the whole world.
rootfs_missing_libs() {
	find "$1" -path "$1/boot" -prune -o -type f -print0 |
	    xargs -0 readelf -d /dev/null 2>/dev/null | awk -v root="$1" '
	function flush(   i, j, n, d, found) {
		if (file == "") return
		n = split("lib lib/priv usr/lib usr/lib/priv " rpath, d, /[: ]+/)
		for (i = 1; i <= nneed; i++) {
			found = 0
			for (j = 1; j <= n && !found; j++) {
				if (d[j] == "") continue
				p = root "/" d[j]
				sub(/\/\/+/, "/", p)
				p = p "/" need[i]
				if ((getline l < p) >= 0) { close(p); found = 1 }
			}
			if (!found) {
				dirs = "lib lib/priv usr/lib usr/lib/priv " rpath
				gsub(/:/, " ", dirs)
				print file "\t" need[i] "\t" dirs
			}
		}
		file = ""; rpath = ""; nneed = 0
	}
	/^File: / { flush(); file = substr($0, 7); next }
	/\((RUNPATH|RPATH)\)/ {
		v = $0; sub(/.*\[/, "", v); sub(/\].*/, "", v)
		rpath = rpath " " v
	}
	/\(NEEDED\)/ {
		v = $0; sub(/.*\[/, "", v); sub(/\].*/, "", v)
		need[++nneed] = v
	}
	END { flush() }'
}

# An mtree(5) manifest of the tree in the current directory, for makefs:
# everything root:wheel with the modes it has here (the building user
# owns the files on the host).  Each file under $1, an overlay tree,
# replaces or adds the file at the same path.  Names are encoded as
# strsvis(3) octal escapes where they have other characters than these.
disk_manifest() {
	local over=$1
	echo '#mtree 2.0'
	echo '/set uid=0 gid=0'
	{
		find . -printf '%y %m %p\t%l\n' | while IFS= read -r l; do
			p=${l#* * }; p=${p%%	*}
			[ -f "$over/$p" ] || printf '%s\n' "$l"
		done
		(cd "$over" && find . -type f -printf "%y %m %p\t\n") |
		    sed "s|\\t\$|\\t@$over|"
	} | LC_ALL=C awk -F'\t' '
	function enc(s,   r, i, c) {
		if (s !~ /[^A-Za-z0-9._\/+,~@:=%-]/) return s
		r = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c ~ /[A-Za-z0-9._\/+,~@:=%-]/) r = r c
			else r = r sprintf("\\%03o", ord[c])
		}
		return r
	}
	BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
	{
		t = substr($1, 1, 1); m = substr($1, 3); sp = index(m, " ")
		p = substr(m, sp + 1); m = substr(m, 1, sp - 1)
		if (t == "d") ty = "dir"
		else if (t == "l") ty = "link"
		else if (t == "f") ty = "file"
		else next
		line = enc(p) " type=" ty " mode=" m
		if (t == "l") line = line " link=" enc($2)
		# A file of the overlay: its contents come from there.
		if (substr($2, 1, 1) == "@")
			line = line " contents=" enc(substr($2, 2) "/" substr(p, 3))
		print line
	}'
}

# A disk image with a writable root: the tree of `build.sh rootfs` (made
# first if there is none) as a UFS file system in a GPT partition, which
# qemu.sh --disk boots with the kernel from the ESP.  The image differs
# from root.iso only in /etc/fstab and /etc/rc.conf: the root is mounted
# read-write and /var, /tmp and /root live on it.  The password
# databases are made on its first boot (rc.local.d/imagedb).
#
# makefs needs no root privileges, and the image is sparse: DISK_SIZE
# (default 4G) is its size, not what it takes on the host.  It is made
# anew each time, so what was written into the old one is lost.
do_disk() {
	local root=$OBJDIR/rootfs over=$OBJDIR/disk-etc img=${DISK:-$OBJDIR/disk.img}
	local size mib off=1048576 sectors
	[ -x "$HOSTBIN/makefs" ] || do_tools
	need sfdisk
	[ -f "$root/etc/rc.conf" ] || ( do_rootfs )
	size=${DISK_SIZE:-4G}
	case $size in
	*[Gg])	mib=$((${size%?} * 1024)) ;;
	*[Mm])	mib=${size%?} ;;
	*)	die "DISK_SIZE must be like 4G or 4096M, not $size" ;;
	esac
	[ "$mib" -ge 64 ] || die "DISK_SIZE is too small: $size"
	rm -rf "$over"
	mkdir -p "$over/etc"
	cat > "$over/etc/fstab" <<'EOF'
# Device	Mountpoint	FStype	Options		Dump	Pass#
/dev/vbd1s0	/		ufs	rw		1	1
EOF
	# The ESP is the first virtio disk (vbd0) and this one the second.
	sed -e '/^root_rw_mount=/d' \
	    -e 's|^# rc.conf for the root image .*|# rc.conf for the disk image from tools/linux/build.sh disk.  Services|' \
	    "$root/etc/rc.conf" > "$over/etc/rc.conf"
	msg "disk image: $img ($size, UFS root in GPT partition 1)"
	(cd "$root" && disk_manifest "$over") > "$OBJDIR/disk.mtree" < /dev/null
	(cd "$root" &&
	    "$HOSTBIN/makefs" -t ffs -B little -Z -o version=1 \
	    -O "$off" -s "$((mib - 2))m" "$img.tmp" "$OBJDIR/disk.mtree") >&2
	# Room for the backup GPT at the end, then the table itself:
	# partition 1 (vbd1s0) is the file system makefs wrote at 1 MiB.
	truncate -s "${mib}M" "$img.tmp"
	sectors=$(((mib - 2) * 2048))
	printf 'label: gpt\nstart=2048, size=%s, type=9D94CE7C-1CA5-11DC-8817-01301BB8A9F5, name="foxynroot"\n' \
	    "$sectors" | sfdisk --quiet --wipe never --wipe-partitions never "$img.tmp" >&2
	mv "$img.tmp" "$img"
	msg "disk image: $img (boot it with tools/linux/qemu.sh --disk)"
}

# cron(8), Cronie: /root/tests/cron-check start installs a root crontab
# and an /etc/cron.d file whose jobs write in /tmp, and has a user other
# than root (nobody) install, list and remove a crontab of its own (the
# base's empty /var/cron/deny lets every user; with su(1) only, so not in
# the base image).  cron-check wait, a few
# minutes later, waits for both jobs to have run, then removes them.
# start also checks anacron(8): /etc/anacrontab parses, and a test table's
# job runs at once and leaves its timestamp.
write_cron_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
cron=ok
case ${1:-} in
start)
	rm -f /tmp/cron-check.tab /tmp/cron-check.d
	printf 'MAILTO=""\n* * * * * echo tab > /tmp/cron-check.tab\n' | crontab - ||
	    { cron=fail; echo "cron-check: FAIL crontab - (root)"; }
	printf 'MAILTO=""\n* * * * * root echo cron.d > /tmp/cron-check.d\n' \
	    > /etc/cron.d/cron-check
	chmod 644 /etc/cron.d/cron-check
	if ! command -v su >/dev/null; then
		echo "cron-check: no su(1) in this image: crontab(1) as nobody not tested"
	elif printf '* * * * * true # cron-check\n' |
	    su -m nobody -c 'crontab -' 2>&1; then
		su -m nobody -c 'crontab -l' 2>&1 | grep -q 'cron-check' ||
		    { cron=fail; echo "cron-check: FAIL crontab -l (nobody)"; }
		su -m nobody -c 'crontab -r' 2>&1 ||
		    { cron=fail; echo "cron-check: FAIL crontab -r (nobody)"; }
	else
		cron=fail; echo "cron-check: FAIL crontab - (nobody, /var/cron/deny)"
	fi
	echo "cron-check: jobs installed at $(date +%T)"
	# anacron(8): the system's table parses, and a job of a test table
	# runs now (-f -n) and leaves its timestamp.
	anacron -T || { cron=fail; echo "cron-check: FAIL anacron -T /etc/anacrontab"; }
	t=$(mktemp -d /tmp/anacron-check.XXXXXX)
	printf '1\t0\tanacron-check\techo anacron > %s/ran\n' "$t" > $t/tab
	if anacron -d -f -n -t $t/tab -S $t 2>&1 && [ -f $t/ran ] &&
	    [ -s $t/anacron-check ]; then
		echo "cron-check: anacron ran a job, timestamp $(cat $t/anacron-check)"
	else
		cron=fail; echo "cron-check: FAIL anacron did not run the test job"
	fi
	rm -rf $t
	;;
wait)
	# Cronie reads the changed tables at the start of a minute and runs
	# that minute's jobs: at most two minutes after start.
	i=0
	while [ ! -f /tmp/cron-check.tab ] || [ ! -f /tmp/cron-check.d ]; do
		i=$((i + 1))
		[ $i -lt 150 ] || break
		sleep 1
	done
	echo "cron-check: checked at $(date +%T)"
	[ -f /tmp/cron-check.tab ] ||
	    { cron=fail; echo "cron-check: FAIL the root crontab's job did not run"; }
	[ -f /tmp/cron-check.d ] ||
	    { cron=fail; echo "cron-check: FAIL the /etc/cron.d job did not run"; }
	crontab -r
	rm -f /etc/cron.d/cron-check /tmp/cron-check.tab /tmp/cron-check.d
	grep -a ' cron\[\| crond\[\|(root) CMD\|(CRON)' /var/log/cron 2>/dev/null |
	    tail -n 5 | sed 's/^/cron-check: log: /'
	;;
*)	echo "usage: cron-check start|wait" >&2; exit 2 ;;
esac
# start reports "start ok", wait the result: "ok".
[ "$1" = start ] && echo "cron-check: start $cron" || echo "cron-check: $cron"
EOF
}

# The network and TLS test that boot-test.sh runs after logging in.
# The network: dhcpcd(8) got a lease for vtnet0 from QEMU's user-mode
# network (an address, the default route and a name server), and fetch(1)
# reaches http://10.0.2.100/, where boot-test.sh has QEMU answer.  TLS:
# fetch talks HTTPS to an openssl(1) s_server on this machine, with a
# certificate made here, so LibreSSL's libcrypto and libssl both work.
write_net_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
net=ok tls=ok
# The lease comes in parts: the address, then the route and the
# name server (dhcpcd's hooks write resolv.conf).  Wait for all three.
i=0
while ! { ifconfig vtnet0 2>/dev/null | grep -q '^[[:space:]]*inet ' &&
    route -n get default >/dev/null 2>&1 &&
    grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; }; do
	i=$((i + 1))
	[ $i -lt 40 ] || break
	sleep 1
done
addr=$(ifconfig vtnet0 | awk '$1 == "inet" { print $2; exit }')
gw=$(route -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2 }')
ns=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null)
echo "net-check: vtnet0 ${addr:-none}, gateway ${gw:-none}, nameserver ${ns:-none}"
[ -n "$addr" ] && [ -n "$gw" ] && [ -n "$ns" ] ||
    { net=fail; echo "net-check: FAIL no DHCP lease (address, route and name server)"; }
ps -axo comm= | grep -qx dhcpcd ||
    { net=fail; echo "net-check: FAIL dhcpcd is not running"; }
out=$(fetch -T 20 -q -o - http://10.0.2.100/ 2>&1)
case $out in
*foxynbsd-net-42*) echo "net-check: fetched http://10.0.2.100/ through ${gw:-?}" ;;
*) net=fail; echo "net-check: FAIL fetch http://10.0.2.100/: $out" ;;
esac
echo "net-check: $net"

echo "tls-check: $(openssl version)"
d=$(mktemp -d /tmp/tls.XXXXXX)
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout $d/key.pem -out $d/cert.pem >$d/req.log 2>&1; then
	openssl s_server -accept 8443 -cert $d/cert.pem -key $d/key.pem \
	    -www >$d/server.log 2>&1 </dev/null &
	pid=$!
	sleep 2
	# By name: TLS sends no server name (SNI) for an address.
	out=$(fetch -T 20 -q --no-verify-peer -o - https://localhost:8443/ 2>&1)
	kill $pid 2>/dev/null
	case $out in
	*"Ciphers supported"*)
		echo "$out" | grep -E 'Protocol|Cipher[[:space:]]*:' | sed 's/^ */tls-check: /' ;;
	*)	tls=fail; echo "tls-check: FAIL fetch https://localhost:8443/: $out"
		sed 's/^/tls-check: server: /' $d/server.log ;;
	esac
else
	tls=fail; echo "tls-check: FAIL openssl req"; sed 's/^/tls-check: /' $d/req.log
fi
# OpenSSH's use of libcrypto (the image with the world has it).
if command -v ssh-keygen >/dev/null 2>&1; then
	if ssh-keygen -q -t rsa -b 2048 -N '' -f $d/id_rsa &&
	    ssh-keygen -q -t ed25519 -N '' -f $d/id_ed25519; then
		for k in $d/id_rsa.pub $d/id_ed25519.pub; do
			ssh-keygen -l -f $k | sed 's/^/tls-check: ssh-keygen: /'
		done
	else
		tls=fail; echo "tls-check: FAIL ssh-keygen"
	fi
fi
rm -rf $d
echo "tls-check: $tls"
[ $net = ok ] && [ $tls = ok ]
EOF
	chmod 755 "$1"
}

# The image's own compilers, which boot-test.sh runs after logging in:
# cc (gcc 12, DragonFly's default, with gnu/lib/gcc120) and gcc 8
# (CCVER=gcc80, with the runtime in /usr/lib/gcc80) compile, link and run
# C, dynamically and statically (a 128-bit division needs libgcc), and
# C++ that throws and catches through a frame with a destructor.  The
# base image has no compiler: the test says it is skipped.
write_cc_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
if [ ! -x /usr/libexec/gcc120/cc ]; then
	echo "cc-check: skipped (no compiler in this image)"
	exit 0
fi
d=$(mktemp -d /tmp/cc.XXXXXX)
cd $d || exit 1
cat > t.c <<'EOT'
#include <stdio.h>
int main(int argc, char **argv) {
	volatile unsigned __int128 n = (unsigned __int128)1 << 100;
	volatile unsigned __int128 q = n / (argc + 5);
	printf("%s %d.%d: %llu\n", argv[1], __GNUC__, __GNUC_MINOR__,
	    (unsigned long long)(q >> 64));
	return (q >> 64) != 9817068105;
}
EOT
cat > t.cc <<'EOT'
#include <iostream>
#include <stdexcept>
#include <string>
struct guard { std::string &s; ~guard() { s += " unwound"; } };
static void thrower(std::string &s) { guard g{s}; throw std::runtime_error("thrown"); }
int main(int, char **argv) {
	std::string s = argv[1];
	try { thrower(s); } catch (const std::exception &e) { s += std::string(" ") + e.what(); }
	std::cout << s << std::endl;
	return s.find("unwound thrown") == std::string::npos;
}
EOT
ok=ok
for v in gcc120 gcc80; do
	for t in "c:cc:t.c" "c-static:cc -static:t.c" "c++:c++:t.cc"; do
		n=${t%%:*}; c=${t#*:}; c=${c%%:*}; src=${t##*:}
		if CCVER=$v $c -O2 -o t $src >build.log 2>&1 &&
		    out=$(./t "cc-check: $v $n") && echo "$out"; then
			:
		else
			ok=fail; echo "cc-check: FAIL $v $n"
			sed 's/^/cc-check: /' build.log | head -n 20
		fi
	done
done
cd /
rm -rf $d
echo "cc-check: $ok"
[ $ok = ok ]
EOF
	chmod 755 "$1"
}

# The BSD Installer (usr.sbin/installer) on the live image, set up as
# nrelease sets up the release CD: /etc.hdd is the /etc it copies to the
# disk instead of the live one (no tmpfs mounts, a read-write root, no
# boot tests in rc.local), and logging in as "installer" (uid 0, no
# password) starts it; /etc/issue says so.  Only the world has it.
rootfs_installer() {
	local root=$1
	cp "$SRCDIR/etc/defaults/pfi.conf" "$root/etc/defaults/"
	rm -rf "$root/etc.hdd"
	cp -a "$root/etc" "$root/etc.hdd"
	sed -i -e '/^root_rw_mount=/d' \
	    -e 's|^# rc.conf for the root image .*|# rc.conf of a system installed by the BSD Installer.  Services|' \
	    "$root/etc.hdd/rc.conf"
	printf '# Device\tMountpoint\tFStype\tOptions\tDump\tPass#\n' \
	    > "$root/etc.hdd/fstab"
	rm -f "$root/etc.hdd/rc.local"
	echo 'installer::0:0::0:0:FoxynBSD Installer:/root:/usr/sbin/installer' \
	    >> "$root/etc/master.passwd"
	cp "$SRCDIR/nrelease/root/etc/issue" "$root/etc/issue"
}

# Ruby in the image (the world has it), which boot-test.sh runs after
# logging in: the interpreter and the extensions that link the base's
# libraries (openssl: LibreSSL, psych: libyaml, zlib, socket), Net::HTTP
# to the server boot-test.sh has QEMU answer on 10.0.2.100, and RubyGems.
# Packages (DPorts, issue #11): /root/tests/pkg-check bootstraps pkg(8)
# from DragonFly's mirror, installs inxi (which brings Perl) and prints an
# inventory: inxi's ("inxi| " lines) and the raw PCI one ("pciconf| ").
# It needs the internet and a writable root, so boot-test.sh runs it only
# with PKG_CHECK=1 on a disk.  The dynamic pkg running at all checks
# /etc/libmap.conf: DragonFly built it against older private LibreSSL
# libraries.
# A first graphical session from DPorts (issue #13): /root/tests/
# desktop-check installs Xorg with the scfb driver (syscons' EFI
# framebuffer; there is no KMS under QEMU), libinput, fonts and GNUstep,
# starts X, checks that the USB keyboard and mouse reach it ("input"
# lines) and that a GNUstep application maps its window.  Like
# pkg-check it needs the internet and a writable root, and a display:
# boot-test.sh runs it with DESKTOP_CHECK=1, on a disk, with a VGA card.
write_desktop_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
ok=1
fail() { echo "desktop-check: FAIL $*"; ok=0; }
done_() { pkill -x Sudoku; pkill -x Xorg; [ $ok = 1 ] && echo "desktop-check: ok" ||
    echo "desktop-check: fail"; [ $ok = 1 ]; exit; }
if [ ! -x /usr/local/sbin/pkg ] &&
    ! make -C /usr pkg-bootstrap > /tmp/pkg-bootstrap.log 2>&1; then
	fail "pkg bootstrap"; done_
fi
pkgs="xorg-minimal xf86-video-scfb xf86-input-libinput dejavu xinput xwininfo
    gnustep gnustep-sudoku"
if ! pkg install -y $pkgs > /tmp/desktop-pkg.log 2>&1; then
	tail -n 5 /tmp/desktop-pkg.log | sed 's/^/desktop-check: /'
	fail "pkg install"; done_
fi
echo "desktop-check: installed $(echo $pkgs)"
# Several drivers match the framebuffer, and Xorg then gives up ("Cannot
# run in framebuffer mode"): name scfb.
mkdir -p /usr/local/etc/X11/xorg.conf.d
printf 'Section "Device"\n\tIdentifier "fb"\n\tDriver "scfb"\nEndSection\n' \
    > /usr/local/etc/X11/xorg.conf.d/10-scfb.conf
X :0 -nolisten tcp vt9 > /tmp/X.out 2>&1 &
i=0
while [ ! -S /tmp/.X11-unix/X0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
export DISPLAY=:0
if ! xwininfo -root > /dev/null 2>&1; then
	grep -a '(EE)' /var/log/Xorg.0.log | sed 's/^/desktop-check: /'
	fail "X did not start"; done_
fi
echo "desktop-check: X $(sed -n 's/.*scfb(0): Using: \(.*\)/\1/p' /var/log/Xorg.0.log | head -n 1 | tr -s ' ')"
xinput list --name-only | sed 's/^/desktop-check: input: /'
xinput list --name-only | grep -q 'USB Keyboard' || fail "no USB keyboard in X"
xinput list --name-only | grep -q 'USB Mouse' || fail "no USB mouse in X"
. /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
/usr/local/GNUstep/System/Applications/Sudoku.app/Sudoku > /tmp/sudoku.log 2>&1 &
i=0
while ! xwininfo -root -tree | grep -q '"Sudoku"' && [ $i -lt 60 ]; do
	sleep 1; i=$((i + 1))
done
if xwininfo -root -tree | grep -q '"Sudoku"'; then
	echo "desktop-check: GNUstep: Sudoku.app mapped $(xwininfo -root -tree | grep -c '"Sudoku"') windows"
else
	tail -n 3 /tmp/sudoku.log | sed 's/^/desktop-check: /'
	fail "GNUstep application did not map a window"
fi
done_
EOF
	chmod 755 "$1"
}

# Sound through PipeWire (issue #13): /root/tests/audio-check installs
# PipeWire, WirePlumber and JACK from DPorts and builds libepoll-shim
# from source.  DPorts' libepoll-shim was built without eventfd(2) and
# emulates it with kqueue descriptors, which SCM_RIGHTS refuses, so
# PipeWire's clients are cut off; built here, it finds the native
# eventfd and leaves eventfd() to libc.  The sound goes PipeWire ->
# JACK tunnel -> jackd (OSS, /dev/dsp) -> snd_hda.  The script checks
# the PipeWire side ("audio-check:" lines); boot-test.sh, with
# AUDIO_CHECK=1, gives the machine an HDA card whose output QEMU records,
# and checks that the 440 Hz tone arrived ("audio-wav:" line).
# PipeWire starts WirePlumber, which runs without its camera monitor:
# unloading libspa-v4l2 also unloads libinotify under its running
# thread, which faults (see #13).
# Argument: a DPorts mirror URL to use instead of pkg's default.
write_audio_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
ok=1
fail() { echo "audio-check: FAIL $*"; ok=0; }
done_() { pkill -x pw-play; pkill -x wireplumber; pkill -x pipewire
    pkill -x jackd; [ $ok = 1 ] && echo "audio-check: ok" ||
    echo "audio-check: fail"; [ $ok = 1 ]; exit; }
shim=epoll-shim-0.0.20240608
shim_sha256=8f5125217e4a0eeb96ab01f9dfd56c38f85ac3e8f26ef2578e538e72e87862cb
if [ ! -x /usr/local/sbin/pkg ] &&
    ! make -C /usr pkg-bootstrap > /tmp/pkg-bootstrap.log 2>&1; then
	fail "pkg bootstrap"; done_
fi
if [ -n "${1:-}" ]; then
	printf 'Avalon: { url: "%s/${ABI}/LATEST" }\n' "$1" \
	    > /usr/local/etc/pkg/repos/df-latest.conf
	pkg update -f > /tmp/audio-pkg.log 2>&1
fi
pkgs="pipewire wireplumber jackit cmake"
if ! pkg install -y $pkgs >> /tmp/audio-pkg.log 2>&1; then
	tail -n 5 /tmp/audio-pkg.log | sed 's/^/audio-check: /'
	fail "pkg install"; done_
fi
echo "audio-check: installed $(pkg query '%n-%v' $pkgs libepoll-shim | tr '\n' ' ')"
cd /tmp || done_
fetch -qo $shim.tar.gz \
    https://github.com/jiixyj/epoll-shim/archive/refs/tags/v${shim#epoll-shim-}.tar.gz ||
    { fail "fetch $shim"; done_; }
[ "$(sha256 -q $shim.tar.gz)" = $shim_sha256 ] || { fail "$shim checksum"; done_; }
rm -rf $shim && tar xzf $shim.tar.gz && mkdir $shim/b && cd $shim/b &&
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr/local > /tmp/shim-build.log 2>&1 &&
    make >> /tmp/shim-build.log 2>&1 || { tail -n 5 /tmp/shim-build.log |
    sed 's/^/audio-check: /'; fail "build $shim"; done_; }
grep -q 'Looking for eventfd - found' /tmp/shim-build.log ||
    fail "$shim did not find eventfd(2)"
cp src/libepoll-shim.so.0 /usr/local/lib/libepoll-shim.so.0
cd /tmp
nm -D /usr/local/lib/libepoll-shim.so.0 | grep -q ' T eventfd$' &&
    fail "libepoll-shim still defines eventfd"
echo "audio-check: $shim built against eventfd(2)"
[ -c /dev/dsp ] || kldload snd_hda || { fail "kldload snd_hda"; done_; }
[ -c /dev/dsp ] || { fail "no /dev/dsp"; done_; }
[ -e /dev/shm ] || ln -s /tmp /dev/shm
export XDG_RUNTIME_DIR=/tmp/xdg-root
mkdir -p -m 700 $XDG_RUNTIME_DIR
mkdir -p /usr/local/etc/pipewire/pipewire.conf.d \
    /usr/local/etc/wireplumber/wireplumber.conf.d
printf 'context.modules = [\n  { name = libpipewire-module-jack-tunnel\n    args = { tunnel.mode = sink } }\n]\n' \
    > /usr/local/etc/pipewire/pipewire.conf.d/jack-sink.conf
printf 'wireplumber.profiles = {\n  main = { monitor.v4l2 = disabled }\n}\n' \
    > /usr/local/etc/wireplumber/wireplumber.conf.d/90-no-v4l2.conf
ruby -e 'r = 48000; d = (0...r * 4).map { |i| (Math.sin(2 * Math::PI * 440 * i / r) * 12000).to_i }.pack("s<*")
    File.binwrite("/tmp/tone.wav", ["RIFF", 36 + d.size, "WAVE", "fmt ", 16, 1, 1, r, r * 2, 2, 16, "data", d.size].pack("a4Va4a4VvvVVvva4V") + d)'
jackd -d oss -r 48000 -p 1024 -n 2 -i 0 -o 2 -P /dev/dsp > /tmp/jackd.log 2>&1 &
sleep 4
pgrep -x jackd > /dev/null || { tail -n 3 /tmp/jackd.log | sed 's/^/audio-check: /'; fail "jackd"; done_; }
# PipeWire starts WirePlumber itself (DPorts' pipewire.conf.d/
# 10-wireplumber.conf): a second session manager would stall both.
dbus-run-session -- sh -c '
	pipewire > /tmp/pipewire.log 2>&1 & sleep 9
	pgrep -x wireplumber | wc -l | tr -d " " > /tmp/wireplumbers
	timeout 10 pw-cli ls Node > /tmp/nodes.txt 2>&1
	timeout 30 pw-play /tmp/tone.wav > /tmp/play.log 2>&1
	echo $? > /tmp/play.rc
	sleep 1'
[ "$(cat /tmp/wireplumbers)" = 1 ] && echo "audio-check: PipeWire started WirePlumber" ||
    fail "$(cat /tmp/wireplumbers) WirePlumber processes, not 1"
grep -q '"jack_sink"' /tmp/nodes.txt && echo "audio-check: PipeWire: jack_sink node" ||
    fail "no jack_sink node"
grep -a 'error -45' /tmp/pipewire.log | head -n 2 | sed 's/^/audio-check: /'
grep -aq 'error -45' /tmp/pipewire.log && fail "descriptor passing (EOPNOTSUPP)"
[ "$(cat /tmp/play.rc)" = 0 ] && echo "audio-check: pw-play played /tmp/tone.wav (440 Hz, 4 s)" ||
    { tail -n 3 /tmp/play.log | sed 's/^/audio-check: /'; fail "pw-play"; }
done_
EOF
	chmod 755 "$1"
}

write_pkg_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
ok=1
fail() { echo "pkg-check: FAIL $*"; ok=0; }
if [ ! -x /usr/local/sbin/pkg ]; then
	if make -C /usr pkg-bootstrap > /tmp/pkg-bootstrap.log 2>&1; then
		echo "pkg-check: bootstrap ok"
	else
		tail -n 5 /tmp/pkg-bootstrap.log | sed 's/^/pkg-check: /'
		fail bootstrap
		echo "pkg-check: fail"
		exit 1
	fi
fi
v=$(pkg -v 2>&1) && echo "pkg-check: pkg $v, ABI $(pkg config abi)" ||
    fail "the dynamic pkg does not run: $v"
if pkg install -y inxi > /tmp/pkg-inxi.log 2>&1; then
	echo "pkg-check: pkg install inxi ok"
else
	tail -n 5 /tmp/pkg-inxi.log | sed 's/^/pkg-check: /'
	fail "pkg install inxi"
fi
v=$(perl -e 'print "perl $^V"' 2>&1) && echo "pkg-check: $v" || fail "perl: $v"
v=$(inxi --version 2>&1 | head -n 1) && echo "pkg-check: $v" || fail "inxi: $v"
inxi -Fxxxz -c 0 2>&1 | sed 's/^/inxi| /'
pciconf -lv 2>&1 | sed 's/^/pciconf| /'
[ $ok = 1 ] && echo "pkg-check: ok" || echo "pkg-check: fail"
[ $ok = 1 ]
EOF
	chmod 755 "$1"
}

write_ruby_test() {
	cat > "$1" <<'EOF'
#!/bin/sh
if [ ! -x /usr/bin/ruby ]; then
	echo "ruby-check: skipped (no Ruby in this image)"
	exit 0
fi
ruby -v | sed 's/^/ruby-check: /'
ruby -ropenssl -ryaml -rzlib -rsocket -rnet/http -e '
ok = true
check = lambda do |name, &b|
  begin
    r = b.call
    puts "ruby-check: #{name}: #{r}"
  rescue Exception => e
    ok = false
    puts "ruby-check: FAIL #{name}: #{e.class}: #{e.message}"
  end
end
check.call("openssl") do
  d = OpenSSL::Digest::SHA256.hexdigest("foxynbsd")
  raise "sha256 #{d}" unless d == "32a855ce4cf7566b341676d3a01b7456f39f87e2a8720fd74e1846e8359c81a4"
  OpenSSL::OPENSSL_LIBRARY_VERSION
end
check.call("yaml") do
  h = YAML.safe_load(YAML.dump({ "os" => "FoxynBSD", "n" => 42 }))
  raise h.inspect unless h["n"] == 42
  "round trip ok (libyaml #{Psych::LIBYAML_VERSION})"
end
check.call("zlib") do
  s = "fox" * 100
  raise "inflate" unless Zlib::Inflate.inflate(Zlib::Deflate.deflate(s)) == s
  "deflate/inflate ok"
end
check.call("socket") do
  srv = TCPServer.new("127.0.0.1", 0)
  t = Thread.new { c = srv.accept; c.puts(c.gets.upcase); c.close }
  c = TCPSocket.new("127.0.0.1", srv.addr[1]); c.puts("fox"); r = c.gets.chomp; t.join
  raise r unless r == "FOX"
  "loopback ok"
end
check.call("net/http") do
  b = Net::HTTP.get(URI("http://10.0.2.100/"))
  raise b.inspect unless b.include?("foxynbsd-net-42")
  "http://10.0.2.100/ ok"
end
check.call("rubygems") do
  "#{Gem::VERSION}, #{Gem::Specification.count} gems"
end
# A C extension, as gem install builds one: mkmf reads rbconfig.rb, so
# this fails when it names the compiler, flags or directories of the build.
if system("command -v cc >/dev/null")
  check.call("mkmf") do
    require "tmpdir"
    Dir.mktmpdir do |d|
      File.write("#{d}/foxext.c", <<~C)
        #include <ruby.h>
        static VALUE fox(VALUE self) { return INT2FIX(42); }
        void Init_foxext(void) { rb_define_global_function("fox", fox, 0); }
      C
      File.write("#{d}/extconf.rb", %(require "mkmf"\ncreate_makefile("foxext")\n))
      log = "#{d}/build.log"
      built = Dir.chdir(d) { system("ruby extconf.rb > #{log} 2>&1 && make >> #{log} 2>&1") }
      raise File.readlines(log).last(3).join(" ").strip unless built
      r = IO.popen(["ruby", "-I", d, "-rfoxext", "-e", "print fox"], &:read)
      raise "fox: #{r.inspect}" unless r == "42"
      "built and loaded a C extension with #{RbConfig::CONFIG["CC"]}"
    end
  end
end
puts "ruby-check: #{ok ? "ok" : "fail"}"
exit(ok)
'
EOF
	chmod 755 "$1"
}

# Two tiny static programs that differ only in their ELF ABI note: one
# says FoxynBSD, the other DragonFly.  Their EI_OSABI is 255 (standalone)
# and they have no interpreter, so the kernel can only accept them by the
check.call("gem-platform") do
  local = Gem::Platform.local
  raise "unexpected local platform #{local}" unless local.cpu == "x86_64" && local.os == "dragonfly"
  same_os = Gem::Platform.new("x86_64-dragonfly6")
  other_os = Gem::Platform.new("x86_64-unknown")
  freebsd = Gem::Platform.new("x86_64-freebsd")
  raise "DragonFly platform mismatch" unless same_os === local
  raise "matched another OS" if other_os === local || freebsd === local
  local.to_s
end
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

# A C++ program that throws through a destructor and a second frame
# before it catches: it only prints "ok" if libgcc_eh (built with clang)
# unwinds the stack and libstdc++ matches the handler.
write_cxx_test() {
	local src=$OBJDIR/cxxtest.cc
	cat > "$src" <<'EOF'
#include <cstdio>
#include <stdexcept>
#include <string>

static int unwound;

struct guard {
	~guard() { unwound++; }
};

static void
inner(const std::string &what)
{
	guard g;
	throw std::runtime_error(what);
}

static void __attribute__((noinline))
outer()
{
	guard g;
	inner("unwound");
}

int
main()
{
	try {
		outer();
	} catch (const std::runtime_error &e) {
		if (unwound == 2) {
			std::printf("c++ exceptions: ok (%s)\n", e.what());
			return 0;
		}
	}
	std::printf("c++ exceptions: destructors ran %d times\n", unwound);
	return 1;
}
EOF
	xc++ -static -O2 -o "$1/cxx-eh" "$src"
	rm -f "$src"
}

# The compiler runtime and dynamic linking tests (tools/linux/tests),
# built with xcc/xc++ against the sysroot and run by /etc/rc.local:
#	rt-builtins, rt-builtins-static	compiler-rt builtins (lib/libcompiler_rt)
#	rt-cxx + librtcxx.so	C++ constructors and destructors in a program
#				and a shared library, an exception thrown
#				across the library boundary, atexit order
#	rt-dlopen + rt-dlmod.so	dlopen(3), dlsym(3), dlclose(3) and a module's
#				constructor and destructor
#	rt-sem			named semaphores (sem_open(3) names with and
#				without a leading slash)
#	rt-eventfd		eventfd(2): a counter passed to another process
#				over SCM_RIGHTS, readiness, limits, blocking
# Each prints "<name>: ok" or "<name>: FAIL <what>".
write_runtime_tests() {
	local dir=$1 t=$SRCDIR/tools/linux/tests
	mkdir -p "$dir"
	xcc -O2 -o "$dir/rt-builtins" "$t/rt-builtins.c"
	xcc -O2 -static -o "$dir/rt-builtins-static" "$t/rt-builtins.c"
	xc++ -O2 -fPIC -shared -Wl,-soname,librtcxx.so -o "$dir/librtcxx.so" \
	    "$t/rt-cxxlib.cc"
	xc++ -O2 -o "$dir/rt-cxx" "$t/rt-cxx.cc" -L"$dir" -lrtcxx \
	    -Wl,-rpath,/root/tests
	xcc -O2 -fPIC -shared -o "$dir/rt-dlmod.so" "$t/rt-dlmod.c"
	xcc -O2 -Wl,-E -o "$dir/rt-dlopen" "$t/rt-dlopen.c"
	xcc -O2 -o "$dir/rt-sem" "$t/rt-sem.c"
	xcc -O2 -o "$dir/rt-eventfd" "$t/rt-eventfd.c"
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

# The terminals init(8) runs getty on: the serial port when it is the
# console (qemu.sh's default) and the first virtual console when there is a
# screen (qemu.sh --gui).  The tree's etc.x86_64/ttys calls the serial
# lines "dialup", which has no terminfo entry here.
write_ttys() {
	cat > "$1" <<'EOF'
# name	getty				type	status		comments
console	none				unknown	off secure
ttyv0	"/usr/libexec/getty Pc"		xterm	on  secure ifexists
ttyd0	"/usr/libexec/getty std.115200"	vt100	on  secure ifconsole
EOF
}

# /etc for the image: the tree's rc, rc.subr and rc.d scripts, with an
# fstab and rc.conf modelled on the live CD's (nrelease/root/etc).  The
# root stays a read-only cd9660; tmpfs mounts over /etc, /var, /tmp and
# /root make them writable, and -C copies the CD's files into each.
write_etc() {
	local root=$1
	cp "$SRCDIR/etc/rc" "$SRCDIR/etc/rc.subr" "$SRCDIR/etc/rc.shutdown" \
	    "$SRCDIR/etc/network.subr" "$SRCDIR/etc/motd" \
	    "$SRCDIR/etc/syslog.conf" "$SRCDIR/etc/newsyslog.conf" \
	    "$SRCDIR/etc/devd.conf" "$root/etc/"
	mkdir -p "$root/etc/devd"
	cp "$SRCDIR/etc/devd/"*.conf "$root/etc/devd/"
	# The mtree specifications (distribution installs them): the BSD
	# Installer builds the new /var from BSD.var.dist.
	mkdir -p "$root/etc/mtree"
	cp "$SRCDIR/etc/mtree/"BSD.*.dist "$root/etc/mtree/"
	# dhcpcd's configuration (etc/Makefile takes it from contrib), and
	# LibreSSL's: openssl(1)'s defaults and the CA certificates that
	# libtls and fetch(1) check servers against.
	cp "$SRCDIR/contrib/dhcpcd/src/dhcpcd.conf" "$root/etc/"
	mkdir -p "$root/etc/ssl"
	cp "$SRCDIR/crypto/libressl/openssl.cnf" "$SRCDIR/crypto/libressl/cert.pem" \
	    "$root/etc/ssl/"
	# The empty log files that etc/Makefile's distribution target
	# installs: syslogd(8) only writes to files that exist.
	install -m 600 /dev/null "$root/var/log/auth.log"
	install -m 600 /dev/null "$root/var/log/cron"
	# cron(8): every user may have a crontab (see etc/Makefile).
	install -m 600 /dev/null "$root/var/cron/deny"
	install -m 640 /dev/null "$root/var/log/daemon"
	install -m 644 /dev/null "$root/var/log/lpd-errs"
	install -m 640 /dev/null "$root/var/log/maillog"
	install -m 644 /dev/null "$root/var/log/lastlogx"
	install -m 644 /dev/null "$root/var/log/messages"
	install -m 600 /dev/null "$root/var/log/security"
	install -m 640 /dev/null "$root/var/log/slip.log"
	install -m 640 /dev/null "$root/var/log/ppp.log"
	install -m 644 /dev/null "$root/var/log/wtmpx"
	mkdir -p "$root/etc/defaults" "$root/etc/rc.d" "$root/etc/rc.local.d"
	cp "$SRCDIR/etc/defaults/rc.conf" "$SRCDIR/etc/defaults/devfs.conf" \
	    "$SRCDIR/etc/defaults/periodic.conf" "$root/etc/defaults/"
	for d in daily weekly monthly security; do
		mkdir -p "$root/etc/periodic/$d"
		(cd "$SRCDIR/etc/periodic/$d" && ls | grep -vx Makefile |
		    while read -r f; do cp "$f" "$root/etc/periodic/$d/$f"; done)
	done
	chmod 755 "$root/etc/periodic/"*/[0-9]*
	(cd "$SRCDIR/etc/rc.d" && ls | grep -vx Makefile |
	    while read -r f; do cp "$f" "$root/etc/rc.d/$f"; done)
	chmod 755 "$root/etc/rc.d/"*
	# cron(8) with the tree's crontab; without atrun in the image (the
	# base image), minus its job.  /etc/cron.d: more system crontabs.
	mkdir -p "$root/etc/cron.d"
	if [ -x "$root/usr/libexec/atrun" ]; then
		cp "$SRCDIR/etc/crontab" "$root/etc/crontab"
	else
		grep -v '/usr/libexec/atrun' "$SRCDIR/etc/crontab" > "$root/etc/crontab"
	fi
	# periodic(8) by anacron(8), which the crontab runs every hour.
	cp "$SRCDIR/etc/anacrontab" "$root/etc/anacrontab"
	# /etc/os-release, from installworld's own target (NAME=FoxynBSD,
	# ID_LIKE=dragonfly).
	( cd "$SRCDIR" && make -f Makefile.inc1 DESTDIR="$root" os-release )
	# /usr/Makefile: make src-create, dports-create, pkg-bootstrap, ...
	cp "$SRCDIR/etc/Makefile.usr" "$root/usr/Makefile"
	# The rest of etc/Makefile's distribution files that a shell
	# session reads (profile, shells, csh.*, hosts, services, ...).
	for f in auth.conf csh.cshrc csh.login csh.logout devtab hosts \
	    hosts.allow hosts.equiv netconfig networks profile protocols rpc \
	    services shells sysctl.conf libmap.conf; do
		cp "$SRCDIR/etc/$f" "$root/etc/$f"
	done
	# Root's dot files, as distribution installs them from share/skel,
	# plus a .shrc whose prompt shows the user, host and directory
	# (share/skel's only has it as a comment).
	for f in cshrc login profile; do
		cp "$SRCDIR/share/skel/dot.$f" "$root/root/.$f"
	done
	{
		cat "$SRCDIR/share/skel/dot.shrc"
		echo
		echo '# FoxynBSD root image: show user@host:directory in the prompt.'
		printf '%s\n' "PS1='\\u@\\h:\\w \\\$ '"
	} > "$root/root/.shrc"
	cat > "$root/etc/fstab" <<'EOF'
# Device	Mountpoint	FStype	Options		Dump	Pass#
dummy		/var		tmpfs	rw,-C		0	0
dummy		/tmp		tmpfs	rw,-C		0	0
dummy		/root		tmpfs	rw,-C		0	0
EOF
	cat > "$root/etc/rc.conf" <<'EOF'
# rc.conf for the root image from tools/linux/build.sh rootfs.  Services
# whose programs the image does not have yet are off.
hostname="foxynbsd"
root_rw_mount="NO"	# The root is a read-only cd9660 image.
syslogd_enable="YES"
newsyslog_enable="YES"
dntpd_enable="NO"
cron_enable="YES"
devd_enable="YES"
mixer_enable="NO"
crashinfo_enable="NO"
check_quotas="NO"
rpc_umntall_enable="NO"
moused_nondefault_enable="NO"
ip6addrctl_enable="NO"
sendmail_submit_enable="NO"
sendmail_outbound_enable="NO"
sendmail_msp_queue_enable="NO"
sendmail_rebuild_aliases="NO"
blanktime="NO"		# Without --gui there is no ttyv0 to blank.
# The virtual consoles run syscons' xterm emulator, as their type in
# /etc/ttys says (the tree's default is cons25, the "sc" emulator).
allscreens_flags="-T xterm"
# The network: dhcpcd(8) configures QEMU's virtio-net card (user-mode
# networking gives it 10.0.2.15, a gateway and DNS).  -b: rc goes on
# while the lease comes.
dhcp_client="dhcpcd"
ifconfig_vtnet0="DHCP"
EOF
	# periodic(8): the reports go to files in /var/log, since the image
	# has no mail program; the checks for programs and subsystems it
	# lacks (sendmail, HAMMER, accounting, ipfw, pf, locate, whatis)
	# are off.
	cat > "$root/etc/periodic.conf" <<'EOF'
# periodic.conf for the root image from tools/linux/build.sh rootfs.
daily_output="/var/log/daily.log"
weekly_output="/var/log/weekly.log"
monthly_output="/var/log/monthly.log"
daily_status_security_inline="YES"	# In daily.log.
weekly_status_security_inline="YES"
monthly_status_security_inline="YES"
daily_clean_msgs_enable="NO"
daily_clean_hoststat_enable="NO"
daily_clean_hammer_enable="NO"
daily_clean_hammer2_enable="NO"
daily_backup_aliases_enable="NO"
daily_accounting_enable="NO"
daily_news_expire_enable="NO"
daily_status_mailq_enable="NO"
daily_status_mail_rejects_enable="NO"
daily_queuerun_enable="NO"
weekly_locate_enable="NO"
weekly_whatis_enable="NO"
monthly_accounting_enable="NO"
security_status_ipfwdenied_enable="NO"
security_status_pfdenied_enable="NO"
security_status_ipfwlimit_enable="NO"
security_status_ip6fwdenied_enable="NO"
security_status_ip6fwlimit_enable="NO"
EOF
	# The first rc.d step: make /etc a writable copy and build the
	# password databases in it, before devfs(8) rules look up users.
	# (Not in fstab: mountcritlocal comes after devfs.)
	cat > "$root/etc/rc.local.d/imagedb" <<'EOF'
#!/bin/sh
#
# PROVIDE: imagedb
# REQUIRE: rcconf
# BEFORE:  devfs

. /etc/rc.subr

name="imagedb"
start_cmd="imagedb_start"
stop_cmd=":"

imagedb_start()
{
	case $(mount | sed -n 's|^.* on / (\([^,)]*\).*|\1|p') in
	cd9660)
		# The live image: /etc becomes a writable copy, the databases
		# go in it at every boot.
		mount_tmpfs -C tmpfs /etc &&
		    pwd_mkdb -p /etc/master.passwd ;;
	*)
		# A disk (build.sh disk): the databases are made once, on the
		# first boot; the root is still mounted read-only here.
		if [ ! -f /etc/spwd.db ]; then
			mount -u -o rw / && pwd_mkdb -p /etc/master.passwd &&
			    mount -u -o ro / && echo "rc: first boot of this disk"
		fi ;;
	esac
	id root >/dev/null && echo "rc: user database ready ($(whoami))"
}

load_rc_config $name
run_rc_command "$1"
EOF
	chmod 755 "$root/etc/rc.local.d/imagedb"
	# rc.d/local sources this just before the LOGIN stage.
	cat > "$root/etc/rc.local" <<'EOF'
echo
# The root's file system: cd9660 for root.iso, ufs for disk.img.
rootfs=$(mount | sed -n 's|^.* on / (\([^,)]*\).*|\1|p')
if echo ok > /tmp/.rc-test; then
	echo "rc: /tmp is writable ($(df /tmp | awk 'NR == 2 { print $1 }'))"
fi
# Identity: os-release names FoxynBSD and keeps DragonFly as ID_LIKE.
( . /etc/os-release && echo "os-release: $PRETTY_NAME (ID=$ID, ID_LIKE=$ID_LIKE)" )
# CI looks for the marker below: print it only if dynamically linked
# programs (rtld + libc + libutil + ncurses) ran.
if uname -a && ls -l /bin/sh; then
	echo
	echo "FoxynBSD userland is up (root on $rootfs, /etc/rc and rc.d)."
	echo "Log in as root (no password); 'halt -p' powers the machine off."
else
	echo "rc: dynamically linked programs fail; ld-elf.so.2 trace follows"
	LD_DEBUG=1 uname -a
	echo "rc: exit status $?"
fi
# ABI notes: both brands must be accepted (issue #5).
/root/tests/cxx-eh || echo "rc: /root/tests/cxx-eh failed with status $?"
for b in /root/tests/brand-*; do
	"$b" || echo "rc: $b failed with status $?"
done
# The compiler runtime and dynamic linking tests (build.sh
# write_runtime_tests): each prints "<name>: ok" or a FAIL line.
for t in rt-builtins rt-builtins-static rt-cxx rt-dlopen rt-sem rt-eventfd; do
	/root/tests/$t || echo "rc: /root/tests/$t failed with status $?"
done
# Kernel modules (build.sh rootfs copies them in when they were built):
# the loader loaded ehci.ko and xhci.ko at boot, which are only listed;
# those named in /root/tests/kld-modules are loaded, found and unloaded.
if ls /boot/kernel/*.ko >/dev/null 2>&1; then
	kld=ok
	echo "kld-check: $(ls /boot/kernel/*.ko | wc -l | tr -d ' ') modules in /boot/kernel"
	for n in ehci.ko xhci.ko; do
		kldstat -n $n >/dev/null 2>&1 && echo "kld-check: $n loaded at boot"
	done
	for n in $(cat /root/tests/kld-modules 2>/dev/null); do
		m=/boot/kernel/$n.ko n=$n.ko
		[ -f $m ] || continue
		if kldload $m && kldstat -n $n | sed "s/^/kld-check: /" &&
		    kldunload $n && ! kldstat -n $n >/dev/null 2>&1; then
			echo "kld-check: $n loaded and unloaded"
		else
			kld=fail; echo "kld-check: FAIL $n"
		fi
	done
	echo "kld-check: $kld"
else
	echo "kld-check: skipped (no modules in the image)"
fi
# Permissions and the writable runtime directories of the live image:
# the root stays read-only, the tmpfs mounts are writable, the
# temporary directories are sticky and the password databases private.
fs=ok
for d in /tmp /var/tmp; do
	[ -d $d ] && [ -w $d ] && [ -k $d ] || { fs=fail; echo "fs-check: FAIL $d is not a sticky writable directory"; }
done
for d in /etc /var/run /var/log /var/db /root; do
	if touch $d/.fs-check 2>/dev/null; then rm -f $d/.fs-check
	else fs=fail; echo "fs-check: FAIL $d is not writable"; fi
done
if [ "$rootfs" = cd9660 ]; then
	if touch /.fs-check 2>/dev/null; then
		fs=fail; echo "fs-check: FAIL / is writable (expected the read-only image)"
	fi
elif touch /.fs-check 2>/dev/null; then
	rm -f /.fs-check
	# A writable root on a disk: count the boots, so a second boot
	# shows that what the first one wrote is still there.
	n=$(cat /var/db/boot-count 2>/dev/null || echo 0)
	n=$((n + 1))
	echo $n > /var/db/boot-count
	echo "disk-check: boot $n of this disk, root on $rootfs ($(df / | awk 'NR == 2 { print $1 }'))"
else
	fs=fail; echo "fs-check: FAIL / is not writable on $rootfs"
fi
for f in /etc/master.passwd /etc/spwd.db; do
	case $(ls -l $f 2>/dev/null) in
	-rw-------*) ;;
	*) fs=fail; echo "fs-check: FAIL $f is not mode 600: $(ls -l $f 2>&1)" ;;
	esac
done
[ $fs = ok ] && echo "fs-check: ok"
# syslogd: a message sent with logger(1) must reach /var/log/messages.
logger -p user.notice "rc.local: syslog test $$"
sleep 1
if grep -qF "syslog test $$" /var/log/messages; then
	echo "rc: syslogd wrote to /var/log/messages"
fi
EOF
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
	local ccver=${WORLD_CCVER:-clang}
	( cd "$SRCDIR/$dir" && make obj >/dev/null &&
	  world_depend CCVER=$ccver DESTDIR="$SYSROOT" "$@" &&
	  make -j"$JOBS" CCVER=$ccver DESTDIR="$SYSROOT" "$@" &&
	  make CCVER=$ccver DESTDIR="$SYSROOT" "$@" install ) || return
	fix_sysroot_links
}

# make depend, in a world directory.  A .depend that names a file which
# is gone (a header that a contrib/ update removed) makes make rebuild
# the objects that listed it on every run, and is not made again, as it
# is newer than the sources: then it is made again from scratch.
# The object directories of source directories that are gone (cron's
# lib/ before Cronie) are left out: make no longer reads them.
world_depend() {
	local o=$MAKEOBJDIRPREFIX$PWD f
	make "$@" depend || return
	[ -n "$(find "$o" -name '.depend*' -type f 2>/dev/null |
	    while read -r f; do
		f=${f#"$o"}
		[ -d "$PWD${f%/*}" ] && cat "$o$f"
	    done | stale_deps)" ] || return 0
	msg "$dir: .depend names files that are gone, making it again"
	make "$@" cleandepend >/dev/null && make "$@" depend
}

# The first absolute path in the make dependencies on standard input
# that does not exist.
stale_deps() {
	awk '{
		for (i = 1; i <= NF; i++) {
			f = $i
			sub(/:$/, "", f)
			if (f !~ /^\// || f in seen) continue
			seen[f] = 1
			if ((getline l < f) < 0) { print f; exit }
			close(f)
		}
	}'
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
# not build with clang, so lib/libcompiler_rt builds LLVM's compiler-rt
# from contrib/compiler-rt instead, into /usr/lib/gcc80 where clang's
# DragonFly driver looks.  Nothing comes from the host's clang install.
install_compiler_rt() {
	local dst=$SYSROOT/usr/lib/gcc80
	mkdir -p "$dst"
	world_lib lib/libcompiler_rt
	# libgcc_eh is the exception unwinder; C needs none, but the driver
	# asks for it in static links.  An empty archive satisfies -lgcc_eh
	# until `base` builds the real one from gnu/lib/gcc80/libgcc_eh.
	[ -f "$dst/libgcc_eh.a" ] || ar rc "$dst/libgcc_eh.a"
}

# EFI boot loader: stand/lib -> dloader -> libefi -> loader.efi, compiled
# against the staged sysroot headers instead of the Linux ones.
STANDOBJ=$OBJDIR/stand
do_loader() {
	local d xcc
	kenv
	headers_current
	# The loader's compiler: the kernel cc wrapper on the sysroot's
	# headers.  One word, because mkdep passes it as CC=${CC} in its
	# environment.
	printf '#!/bin/sh\nexec cc -nostdinc -isystem "%s/usr/include" "$@"\n' \
	    "$SYSROOT" > "$HOSTBIN/standcc"
	chmod 755 "$HOSTBIN/standcc"
	xcc=standcc
	MAKEOBJDIRPREFIX=$STANDOBJ; export MAKEOBJDIRPREFIX
	mkdir -p "$STANDOBJ"
	for d in stand/lib stand/boot/dloader stand/boot/efi/libefi \
	    stand/boot/efi/loader stand/boot/efi/boot1; do
		msg "building $d"
		# depend first, as in world_lib: bsd.prog.mk turns DPADD into
		# dependencies only through .depend, so without it loader.efi
		# is not relinked when libdloader or libefi change.
		( cd "$SRCDIR/$d" && make obj >/dev/null &&
		  make CC="$xcc" depend && make -j"$JOBS" CC="$xcc" )
	done
	msg "loader: $(loader_efi), $(boot1_efi)"
	do_biosboot
}

# The legacy BIOS boot blocks of stand/boot/pc32/boot2: boot1_64 and
# boot2_64, which disklabel64 -B writes into a slice (the BSD Installer
# always runs it), and their 32-bit counterparts.  They are 32-bit code
# (the pc64 makefiles add -m32) linked by btxld, a host tool.  On this
# host btxld gets the BSD a.out and ELF32 definitions from a directory
# of its own, and the boot2 makefile two BSD tools: dd conv=osync (pad
# the output) and stat with no options (the size is the eighth field).
# The assembler must not add an x86 ISA note (Arch's binutils do by
# default): objcopy -O binary would put it after the 512-byte boot1.
do_biosboot() {
	local inc=$HOSTOBJ/btxld-inc bsd=$HOSTOBJ/bsdbin d m note=
	mkdir -p "$inc/sys" "$bsd"
	# Written only when they change, so btxld is not compiled again.
	write_changed "$inc/sys/imgact_aout.h" < "$SRCDIR/sys/sys/imgact_aout.h"
	write_changed "$inc/a.out.h" <<'EOF'
/* btxld on a Linux host: the BSD a.out definitions, not glibc's. */
#include <sys/types.h>
#include <arpa/inet.h>	/* ntohl, in the a.out macros */
#define __LDPGSZ	4096
#include <sys/imgact_aout.h>
EOF
	write_changed "$inc/sys/elf32.h" <<'EOF'
/* btxld on a Linux host: glibc's <elf.h> has the ELF32 types. */
#include <elf.h>
#ifndef IS_ELF
#define IS_ELF(ehdr)	((ehdr).e_ident[EI_MAG0] == ELFMAG0 && \
			 (ehdr).e_ident[EI_MAG1] == ELFMAG1 && \
			 (ehdr).e_ident[EI_MAG2] == ELFMAG2 && \
			 (ehdr).e_ident[EI_MAG3] == ELFMAG3)
#endif
EOF
	cat > "$bsd/stat" <<EOF
#!/bin/sh
[ \$# -eq 1 ] || exec "$(host_path stat)" "\$@"
s=\$("$(host_path stat)" -c %s "\$1") || exit 1
echo "0 0 0 0 0 0 0 \$s 0 0 0 0 0 0 0 \$1"
EOF
	cat > "$bsd/dd" <<EOF
#!/bin/sh
obs= of= sync=
n=\$#
while [ "\$n" -gt 0 ]; do
	a=\$1; shift; n=\$((n - 1))
	case \$a in
	conv=osync) sync=1; continue ;;
	obs=*) obs=\${a#obs=} ;;
	of=*) of=\${a#of=} ;;
	esac
	set -- "\$@" "\$a"
done
"$(host_path dd)" "\$@" || exit
if [ -n "\$sync" ] && [ -n "\$obs" ] && [ -n "\$of" ]; then
	s=\$("$(host_path stat)" -c %s "\$of")
	truncate -s \$(( (s + obs - 1) / obs * obs )) "\$of"
fi
EOF
	chmod 755 "$bsd/stat" "$bsd/dd"
	echo | as -mx86-used-note=no -o /dev/null - 2>/dev/null &&
	    note=-Wa,-mx86-used-note=no
	printf '#!/bin/sh\nexec standcc %s "$@"\n' "$note" > "$HOSTBIN/biosbootcc"
	chmod 755 "$HOSTBIN/biosbootcc"
	m="CC=biosbootcc NXENV=env NXCC_LINK=hostcc REALLY_X86_64=true MACHINE_ARCH=i386 MACHINE=i386"
	for d in asmdef btx btxld boot2; do
		msg "building stand/boot/pc32/$d"
		( PATH=$bsd:$PATH
		  cd "$SRCDIR/stand/boot/pc32/$d" && make $m "NXCC=hostcc -I$inc" obj >/dev/null &&
		  make $m "NXCC=hostcc -I$inc" depend &&
		  make -j"$JOBS" $m "NXCC=hostcc -I$inc" ) || return
	done
	d=$STANDOBJ$SRCDIR/stand/boot/pc32/boot2
	[ "$(wc -c < "$d/boot1_64")" = 512 ] || die "boot1_64 is not 512 bytes"
}

# The BIOS boot blocks that disklabel64 -B reads from /boot.
biosboot_files() {
	local d=$STANDOBJ$SRCDIR/stand/boot/pc32/boot2
	echo "$d/boot1_64 $d/boot2_64 $d/boot1_32 $d/boot2_32"
}

loader_efi() {
	echo "$STANDOBJ$SRCDIR/stand/boot/efi/loader/loader.efi"
}

# boot1.efi: the first stage that the BSD Installer puts on an ESP; it
# starts /loader.efi (or /boot/loader.efi) from a UFS partition.
boot1_efi() {
	echo "$STANDOBJ$SRCDIR/stand/boot/efi/boot1/boot1.efi"
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
	# The EFI loader loads ehci.ko and xhci.ko at every boot
	# (stand/boot/efi/loader/main.c); GENERIC has only the UHCI and OHCI
	# drivers built in, so without them USB 2 and 3 controllers, and
	# what is plugged into them, have no driver.
	if kconf_modules "$conf"; then
		local m ko
		for m in $BOOT_MODULES; do
			ko=$kobj$SRCDIR/sys/$m/${m##*/}.ko
			[ -f "$ko" ] ||
			    ( kenv && cd "$kobj" && make -j"$JOBS" $KMAKE \
				KERNEL=kernel MODULES_OVERRIDE="$BOOT_MODULES" modules ) ||
			    return
			objcopy --strip-debug "$ko" "$boot/kernel/${m##*/}.ko"
		done
	fi
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

# What this host has and lacks for each part of the build, with the
# package that provides it.  Only reports; nothing is changed.
do_doctor() {
	local id=unknown pm=pacman missing= t pkg pkgp pkga why probe sub
	[ -r /etc/os-release ] && id=$(. /etc/os-release; echo "${ID:-unknown} ${ID_LIKE:-}")
	case " $id " in
	*" debian "*|*" ubuntu "*) pm=apt ;;
	esac
	echo "host: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")," \
	    "packages via $pm"
	echo "/bin/sh: $(readlink -f /bin/sh), awk: $(readlink -f "$(command -v awk)")"
	# tool  pacman-package  apt-package  what-needs-it
	while read -r t pkgp pkga why; do
		if command -v "$t" >/dev/null 2>&1; then
			continue
		fi
		[ $pm = apt ] && pkg=$pkga || pkg=$pkgp
		echo "missing: $t ($why) -> $pkg"
		missing="$missing $pkg"
	done <<'EOF'
gcc base-devel build-essential tools,kernel
make base-devel build-essential tools
flex flex flex tools,kernel
bison bison bison tools,kernel
pkg-config pkgconf pkg-config tools
readelf binutils binutils rootfs,audit
clang clang clang userland
ld.lld lld lld userland
tic ncurses ncurses-bin rootfs(terminfo)
xorriso libisoburn xorriso rootfs(root.iso)
sfdisk util-linux fdisk disk(disk.img)
qemu-system-x86_64 qemu-desktop qemu-system-x86 boot
EOF
	for probe in libbsd-overlay:libbsd:libbsd-dev libtirpc:libtirpc:libtirpc-dev; do
		pkg-config --exists "${probe%%:*}" 2>/dev/null && continue
		t=${probe#*:}
		[ $pm = apt ] && pkg=${t#*:} || pkg=${t%%:*}
		echo "missing: ${probe%%:*} (tools) -> $pkg"
		missing="$missing $pkg"
	done
	# -lfl: Debian ships flex's library separately.
	echo 'int yylex(void){return 0;}' | ${HOST_CC} -x c - -lfl -o /dev/null \
	    2>/dev/null || {
		[ $pm = apt ] && pkg=libfl-dev || pkg=flex
		echo "missing: libfl (tools) -> $pkg"; missing="$missing $pkg"; }
	if command -v "$HOST_CC" >/dev/null 2>&1; then
		echo "host gcc: $($HOST_CC -dumpfullversion 2>/dev/null)," \
		    "default PIE: $(echo | $HOST_CC -dM -E - | grep -q '__PIE__' && echo yes || echo no)," \
		    "default SSP: $(echo | $HOST_CC -dM -E - | grep -q '__SSP' && echo yes || echo no)" \
		    "(the kernel build turns both off: cc wrapper, kern.mk)"
	fi
	command -v clang >/dev/null 2>&1 &&
	    echo "clang: $(clang -dumpversion), resource dir $(clang -print-resource-dir)"
	if command -v qemu-system-x86_64 >/dev/null 2>&1; then
		"$SRCDIR/tools/linux/qemu.sh" --firmware 2>&1 | sed 's/^/firmware: /' ||
		    { [ $pm = apt ] && pkg=ovmf || pkg=edk2-ovmf; missing="$missing $pkg"; }
		if qemu-system-x86_64 -display help 2>/dev/null | grep -qxE 'gtk|sdl'; then
			echo "qemu window: yes (gtk/sdl)"
		else
			[ $pm = apt ] && pkg=qemu-system-gui || pkg=qemu-desktop
			echo "qemu window: no, qemu.sh uses the serial console -> $pkg"
		fi
		[ -w /dev/kvm ] && echo "kvm: usable" ||
		    echo "kvm: not usable (QEMU falls back to TCG, much slower)"
	fi
	# The contrib/ submodules: checked out, at the recorded commits.
	sub=0
	"$SRCDIR/tools/linux/check-submodules.sh" -r || sub=1
	if [ -n "$missing" ]; then
		case $pm in
		apt)	echo "install: sudo apt-get install$missing" ;;
		*)	echo "install: sudo pacman -S --needed$missing" ;;
		esac
		return 1
	fi
	[ $sub = 0 ] || return 1
	echo "everything the build and the boot test use is installed"
}

# The whole system, ready for `tools/linux/qemu.sh`: host tools, kernel,
# EFI loader and boot tree, the world (ROOTFS=base: the base programs)
# and a root image with all of it.  Every step is incremental: after an
# edit in the tree, running it again compiles what the edit affects,
# relinks what links against that, and packs the images again.
do_all() {
	kenv
	( do_kernel )
	( do_loader )
	( do_esp )
	case ${ROOTFS:-world} in
	base)	( do_base ) ;;
	*)	( do_world ) ;;
	esac
	( do_rootfs )
	msg "done: boot it with tools/linux/qemu.sh (a window; --serial for the terminal)"
}

# Everything runs from inside main, and the call shares its line with
# exit: the shell reads a script piece by piece, so a build.sh rewritten
# while a long build runs (git pull) must not be read again afterwards.
main() {
	cmd=${1:-all}
	# set -e exits quietly; say which command failed (the last ">>>" line
	# before this one names the step).
	trap 'rc=$?; [ "$rc" = 0 ] || echo "build.sh: $cmd failed (exit $rc)" >&2' EXIT
	[ $# -gt 0 ] && shift
	case ${1:-} in
	-*)	die "unknown option: $1 (--gui and --root belong to qemu.sh)" ;;
	esac
	# The contrib/ submodules (Cronie, ...) must be checked out at the
	# commits the tree records before anything is built from them.
	case $cmd in
	doctor|env|tools|kernel|modules|loader|esp) ;;
	*)	"$SRCDIR/tools/linux/check-submodules.sh" -r -q ||
		    die "the contrib/ submodules are not ready (see above)" ;;
	esac
	case $cmd in
	all)		do_all ;;
	tools)		do_tools ;;
	kernel)		do_kernel "$@" ;;
	modules)	do_modules "$@" ;;
	sysroot)	do_sysroot ;;
	libc)		do_libc ;;
	base)		do_base ;;
	world)		do_world ;;
	rootfs)		do_rootfs ;;
	disk)		do_disk ;;
	subdir)		headers_current
			[ -f "$SYSROOT/usr/lib/libc.so" ] || do_libc
			wenv; for d; do world_dir "$d"; done ;;
	loader)		do_loader ;;
	esp)		do_esp "$@" ;;
	doctor)		do_doctor ;;
	env)		kenv; env | grep -E '^(PATH|MACHINE|MACHINE_ARCH|MACHINE_PLATFORM|CCVER|HOST_CCVER|HOST_BINUTILSVER)=' | sed 's/^/export /' ;;
	*)		sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
	esac
}

main "$@"; exit
