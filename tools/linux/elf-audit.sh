#!/bin/sh
#
# Audit the target files that tools/linux/build.sh produced for leaks from
# the Linux build host: every ELF file under a tree (the sysroot, the root
# image tree, an ESP) must be an x86_64 DragonFly/FoxynBSD object, not
# something built or linked against glibc.
#
# Usage:
#	tools/linux/elf-audit.sh [-o REPORT] DIR...
#
# Errors (exit status 1) mean confirmed host contamination:
#	- not ELF64 little-endian x86-64;
#	- a program interpreter other than ld-elf.so.2 (e.g. ld-linux);
#	- a NEEDED library with a glibc/Linux soname (libc.so.6, ld-linux,
#	  libgcc_s.so.1, libbsd.so.0, ...) that the tree does not have;
#	- versioned references to glibc (GLIBC_x.y) or libgcc_s (GCC_x.y)
#	  symbols;
#	- the Linux ABI note (.note.ABI-tag, NT_GNU_ABI_TAG with OS Linux),
#	  which glibc's crt1.o carries;
#	- RPATH/RUNPATH or interpreter strings that point into the build host
#	  (the source or object tree, /usr/lib/x86_64-linux-gnu, /lib64).
# Static archives (.a) are checked member by member for the machine and
# the Linux ABI note.
# Warnings (reported, not fatal):
#	- a NEEDED library that is neither a known host soname nor present in
#	  the tree (an incomplete tree, not contamination);
#	- a dynamically linked program or shared library without a DragonFly
#	  or FoxynBSD ABI note (crt1.o adds it to programs; shared libraries
#	  normally carry none, so this is only checked for programs);
#	- host build paths in the loaded (non-debug) data of a file;
#	- EI_OSABI 3 (GNU).  It does not mean Linux: LLVM sets it on objects
#	  that use GNU ELF extensions (SHF_GNU_RETAIN sections, which clang
#	  emits for gcc 8's libstdc++ locale instances; IFUNC, GNU_UNIQUE),
#	  and lld passes it on to what links them.  DragonFly's kernel
#	  accepts such programs by their ABI note.
#
# EI_OSABI 0 (System V) is what clang and lld normally write for
# DragonFly.  .comment is not looked at: clang's ident is the same for
# every target.  Findings name the file as <tree>/<path>, where <tree> is
# the last component of the DIR argument.
#
# Needs readelf from GNU binutils or LLVM (llvm-readelf).

set -eu

die() { echo "elf-audit.sh: $*" >&2; exit 2; }

REPORT=
while [ $# -gt 0 ]; do
	case $1 in
	-o)	REPORT=$2; shift 2 ;;
	--)	shift; break ;;
	-*)	die "unknown option: $1" ;;
	*)	break ;;
	esac
done
[ $# -gt 0 ] || die "usage: elf-audit.sh [-o REPORT] DIR..."

READELF=
for r in readelf llvm-readelf; do
	command -v "$r" >/dev/null 2>&1 && { READELF=$r; break; }
done
[ -n "$READELF" ] || die "readelf not found (binutils or llvm)"

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
# Host paths that must not end up in what the target loads.  $OBJDIR is
# where build.sh writes; the defaults cover a normal checkout.
OBJDIR=${OBJDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/foxynbsd}
HOSTPATHS="$SRCDIR|$OBJDIR|/usr/lib/x86_64-linux-gnu|/lib/x86_64-linux-gnu|/lib64/|ld-linux"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/elf-audit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out=$tmp/report
: > "$out"

err() { echo "ERROR $1: $2" >> "$out"; }
warn() { echo "WARN  $1: $2" >> "$out"; }

# Glibc and other Linux-only sonames; any of them as NEEDED is a leak.
host_soname() {
	case $1 in
	libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|\
	libutil.so.1|libresolv.so.2|libcrypt.so.1|libcrypt.so.2|\
	ld-linux*|libgcc_s.so.1|libstdc++.so.6|libbsd.so.0|libmd.so.0|\
	libtirpc.so.3|libfl.so.2|libnsl.so.*|libanl.so.1|libz.so.1|\
	libtinfo.so.*|libncursesw.so.6|libselinux.so.1|libsystemd.so.0|\
	linux-vdso.so.1)
		return 0 ;;
	esac
	return 1
}

nfiles=0 narch=0
for root in "$@"; do
	[ -d "$root" ] || die "not a directory: $root"
	root=$(cd "$root" && pwd)
	# The sysroot's usr/lib/clang points at the host compiler's resource
	# directory (headers only, but do not walk the host's files).
	find "$root" -path "$root/usr/lib/clang" -prune -o -type f -size +51c \
	    -print > "$tmp/files"
	while read -r f; do
		magic=$(head -c 7 "$f" | od -An -c | tr -d ' ')
		rel=${root##*/}/${f#"$root"/}
		# Static archives: each member must be an x86-64 object without
		# the Linux ABI note (a glibc or host-compiler object copied in).
		if [ "$magic" = '!<arch>' ]; then
			"$READELF" -W -h -n "$f" 2>/dev/null | awk -v F="$rel" '
			/^File: / { m = $2 }
			/^ *Machine:/ && !/X86-64|x86-64/ { print "ERROR " m ": not an x86-64 object" }
			/NT_GNU_ABI_TAG/ { t = 1 }
			t && /OS: *Linux/ { print "ERROR " m ": Linux ABI note"; t = 0 }
			' >> "$out"
			narch=$((narch + 1))
			continue
		fi
		# ELF magic only.
		case $magic in 177ELF*) ;; *) continue ;; esac
		nfiles=$((nfiles + 1))
		"$READELF" -W -h -l -d -n -V "$f" > "$tmp/re" 2>/dev/null || {
			err "$rel" "readelf cannot parse it"; continue; }
		awk -v F="$rel" -v HOSTPATHS="$HOSTPATHS" '
		function err(m) { print "ERROR " F ": " m }
		/^ *Class:/ && $2 != "ELF64" { err("class " $2 ", not ELF64") }
		/^ *Data:/ && $0 !~ /little endian/ { err("not little endian") }
		/^ *Machine:/ { sub(/^ *Machine: */, ""); if ($0 !~ /X86-64|x86-64/) err("machine " $0 ", not x86-64") }
		/^ *OS\/ABI:/ && /Linux|GNU/ { print "WARN  " F ": EI_OSABI is GNU (GNU ELF extensions, see elf-audit.sh)" }
		/Requesting program interpreter:/ {
			i = $0; sub(/.*interpreter: */, "", i); sub(/\].*/, "", i)
			if (i != "/libexec/ld-elf.so.2" && i != "/usr/libexec/ld-elf.so.2")
				err("program interpreter " i)
		}
		/\((RPATH|RUNPATH)\)/ && $0 ~ HOSTPATHS { err("host path in " $0) }
		/NT_GNU_ABI_TAG/ { abitag = 1 }
		abitag && /OS: *Linux/ { err("Linux ABI note (glibc crt1.o)"); abitag = 0 }
		/Name: *GLIBC_[0-9]/ { v = $0; sub(/.*Name: */, "", v); sub(/ .*/, "", v); g[v] = 1 }
		/Name: *GCC_[0-9]/ { v = $0; sub(/.*Name: */, "", v); sub(/ .*/, "", v); g[v] = 1 }
		END { l = ""; for (v in g) l = l " " v; if (l != "") err("needs host symbol versions" l) }
		' "$tmp/re" >> "$out"

		# NEEDED: a library the tree has is the target's own (and is
		# audited itself; DragonFly also has a libpthread.so.0).  One it
		# lacks is an error if it is a glibc/Linux soname, else a warning.
		runpath=$(sed -n 's/.*(R[UN]*PATH).*\[\(.*\)\]/\1/p' "$tmp/re" | tr ':' ' ')
		for lib in $(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' "$tmp/re"); do
			found=
			for d in lib lib/priv usr/lib usr/lib/priv usr/lib/gcc80 \
			    usr/lib/gcc120 $runpath; do
				case $d in '$ORIGIN'*) d=$(dirname "${f#"$root"/}")${d#'$ORIGIN'} ;; esac
				[ -e "$root/${d#/}/$lib" ] && { found=1; break; }
			done
			[ -n "$found" ] && continue
			if host_soname "$lib"; then
				err "$rel" "links against the host library $lib (not in the tree)"
			else
				warn "$rel" "needs $lib, which is not in $root"
			fi
		done

		# Programs (they have an interpreter) carry crt1.o's ABI note.
		if grep -q 'Requesting program interpreter' "$tmp/re" &&
		    ! grep -Eq '^ *(DragonFly|FoxynBSD) ' "$tmp/re"; then
			warn "$rel" "dynamically linked program without a DragonFly/FoxynBSD ABI note"
		fi

		# Host paths in the strings a program actually loads.
		for s in .rodata .data; do
			"$READELF" -W -p "$s" "$f" 2>/dev/null
		done | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -E "$HOSTPATHS" |
		    sort -u | head -n 3 | while read -r l; do
			warn "$rel" "host path in loaded data: $l"
		done
	done < "$tmp/files"
done

nerr=$(grep -c '^ERROR' "$out" || :)
nwarn=$(grep -c '^WARN' "$out" || :)
{
	echo "elf-audit: $nfiles ELF files and $narch archives in $*"
	echo "elf-audit: $nerr errors (host contamination), $nwarn warnings"
	sort "$out"
} > "$tmp/final"
[ -n "$REPORT" ] && cp "$tmp/final" "$REPORT"
# Print the summary and the first findings; the report has them all.
head -n 2 "$tmp/final"
grep '^ERROR' "$tmp/final" | head -n 50 || :
grep '^WARN' "$tmp/final" | head -n 20 || :
[ "$nerr" = 0 ]
