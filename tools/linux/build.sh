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
#	tools/linux/build.sh loader		(EFI loader.efi)
#	tools/linux/build.sh esp [KERNCONF]	(boot tree for QEMU;
#					 WITH_MODULES=1 to add .ko)
#	tools/linux/build.sh env		(print an env for manual make runs)
#
# Environment:
#	OBJDIR	output directory (default ${XDG_CACHE_HOME:-~/.cache}/foxynbsd)
#	JOBS	parallel jobs (default: nproc)
#
# Host packages needed (Arch/Omarchy):
#	base-devel flex bison libbsd

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
HOSTBIN=$OBJDIR/host/bin
HOSTOBJ=$OBJDIR/host/obj
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
# in-tree gcc120 stay warnings instead of failing -Werror.
write_cc_wrapper() {
	local hostgcc
	hostgcc=$(command -v "${HOST_GCC:-gcc}") || die "no host gcc"
	cat > "$HOSTBIN/cc" <<EOF
#!/bin/sh
exec "$hostgcc" \\
	-fno-pie -fno-pic -no-pie \
	-fcf-protection=none -fno-stack-clash-protection -U_FORTIFY_SOURCE \
	-U__linux__ -U__linux -Ulinux -U__gnu_linux__ -D__DragonFly__ \
	-Wno-error=dangling-pointer -Wno-error=enum-int-mismatch \
	-Wno-error=maybe-uninitialized -Wno-error=array-bounds \
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
	/usr/bin/gcc -O2 -w -I"$o" -I"$SRCDIR/contrib/bmake" \
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
	  /usr/bin/gcc -O2 -I. y.tab.c lex.yy.c main.c mkioconf.c \
	      mkmakefile.c mkheaders.c mkoptions.c -lfl -o "$HOSTBIN/config" )
}

build_small_tools() {
	local bsd
	bsd=$(pkg-config --cflags --libs libbsd-overlay) ||
	    die "libbsd not found (pacman -S libbsd)"
	/usr/bin/gcc -O2 -o "$HOSTBIN/file2c" \
	    "$SRCDIR/usr.bin/file2c/file2c.c" $bsd
	/usr/bin/gcc -O2 -o "$HOSTBIN/uudecode" \
	    "$SRCDIR/usr.bin/uudecode/uudecode.c" $bsd -lresolv
	install -m 755 "$SRCDIR/usr.bin/mkdep/mkdep.sh" "$HOSTBIN/mkdep"
	# bsd.lib.mk orders archives with `lorder ... | tsort -q`; GNU tsort
	# has no -q (quiet about cycles), so drop it and silence stderr.
	install -m 755 "$SRCDIR/usr.bin/lorder/lorder.sh" "$HOSTBIN/lorder"
	cat > "$HOSTBIN/tsort" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
exec /usr/bin/tsort "$@" 2>/dev/null
EOF
	chmod 755 "$HOSTBIN/tsort"
}

do_tools() {
	need gcc flex bison awk pkg-config objcopy ld nm
	mkdir -p "$HOSTBIN" "$HOSTOBJ"
	msg "bootstrapping host tools into $HOSTBIN"
	write_cc_wrapper
	build_bmake
	build_config
	build_small_tools
	touch "$HOSTBIN/.done"
}

kenv() {
	[ -f "$HOSTBIN/.done" ] || do_tools
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
	touch "$SYSROOT/.headers_done"
}

# EFI boot loader: stand/lib -> dloader -> libefi -> loader.efi, compiled
# against the staged sysroot headers instead of the Linux ones.
STANDOBJ=$OBJDIR/stand
do_loader() {
	local d xcc
	kenv
	[ -f "$SYSROOT/.headers_done" ] || do_sysroot
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

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
tools)		do_tools ;;
kernel)		do_kernel "$@" ;;
modules)	do_modules "$@" ;;
sysroot)	do_sysroot ;;
loader)		do_loader ;;
esp)		do_esp "$@" ;;
env)		kenv; env | grep -E '^(PATH|MACHINE|MACHINE_ARCH|MACHINE_PLATFORM|CCVER|HOST_CCVER|HOST_BINUTILSVER)=' | sed 's/^/export /' ;;
*)		sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
