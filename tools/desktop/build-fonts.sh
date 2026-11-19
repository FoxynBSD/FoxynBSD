#!/bin/sh
#
# build-fonts.sh: the X bitmap fonts of font-misc-misc and their encodings,
# built from contrib/ (docs/contrib.md) into /usr/local/share/fonts/misc
# and /usr/local/share/fonts/encodings, where XLibre's default font path
# looks (build-xlibre.sh; foxyn-desktop(8)).  DejaVu is not built here:
# it comes from DPorts (the exception to the no-DPorts rule for images).
#
# Usage: build-fonts.sh
#
# Run as root: it installs into the prefix.  Environment:
#	FONT_SRC	the sources: contrib/ (default
#			/usr/share/foxynbsd/contrib, the copies build.sh puts in
#			the image)
#	FONT_PREFIX	where the fonts go (default /usr/local/share/fonts)
#	CC		the C compiler (default cc, the base system's)
#
# What is built, as the Makefile of font-misc-misc builds it by default:
# the 10646-1 fonts, and the ISO8859-*, KOI8-R and JISX0201 conversions
# that ucs2any (font-util) makes from them; each BDF becomes a PCF with
# bdftopcf -t (contrib/bdftopcf).  fonts.dir is written from the FONT
# name of each BDF, which is what mkfontscale writes for bitmap fonts:
# mkfontscale (and freetype) are not built.  fonts.alias comes from
# font-alias.  encodings.dir is written from the STARTENCODING name of
# each .enc file in contrib/encodings (and its large/ directory).
#
# Not built: the truncated fonts (bdftruncate), compressed PCF, the 75dpi,
# 100dpi and cyrillic sets.  The sources are not written to: all the
# output is in a work directory, and the install is the last step.
set -eu

src=${FONT_SRC:-/usr/share/foxynbsd/contrib}
prefix=${FONT_PREFIX:-/usr/local/share/fonts}
CC=${CC:-cc}
md=$src/font-misc-misc
fa=$src/font-alias
enc=$src/encodings
fu=$src/font-util
bt=$src/bdftopcf
xp=$src/xorgproto

say() { echo "build-fonts: $*"; }
die() { echo "build-fonts: $*" >&2; exit 1; }

for d in "$md" "$fa" "$enc" "$fu" "$bt" "$xp"; do
	[ -d "$d" ] || die "$d is missing (contrib/ in the image: build.sh rootfs)"
done
mkdir -p "$prefix" 2>/dev/null && [ -w "$prefix" ] ||
	die "$prefix is not writable by $(id -un)"

work=$(mktemp -d "${TMPDIR:-/tmp}/fonts-build.XXXXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
bdf=$work/bdf
pcf=$work/pcf
mkdir "$bdf" "$pcf"

# The configuration bdftopcf and ucs2any expect from configure.
cat > "$work/config.h" <<'EOF'
#define HAVE_STDINT_H 1
#define HAVE_STRDUP 1
#define PACKAGE_VERSION "1.1.2"
#define PACKAGE_STRING "bdftopcf 1.1.2"
EOF

# bdftopcf: the sources the Makefile lists (contrib/bdftopcf/Makefile.am).
say "building bdftopcf"
objs=
for f in atom bdfread bdfutils bitmap bitmaputil bufio defaults fileio \
    filewr fontaccel fontink pcfwrite private utilbitmap bdftopcf; do
	"$CC" -O2 -c -DHAVE_CONFIG_H -I"$work" -I"$xp/include" -I"$bt" \
	    "$bt/$f.c" -o "$work/$f.o" || die "compile $f.c"
	objs="$objs $work/$f.o"
done
"$CC" -o "$work/bdftopcf" $objs || die "link bdftopcf"

say "building ucs2any"
"$CC" -O2 -I"$work" "$fu/ucs2any.c" -o "$work/ucs2any" || die "compile ucs2any"

# The Makefile's lists (contrib/font-misc-misc/Makefile.am): the sizes
# converted to each encoding.
all="4x6 5x7 5x8 6x9 6x10 6x12 6x13 6x13B 6x13O 7x13 7x13B 7x13O 7x14
    7x14B 8x13 8x13B 8x13O 9x15 9x15B 9x18 9x18B 10x20"
extra="12x13ja 18x18ja 18x18ko k14 nil2"
iso8859_8="4x6 5x7 5x8 6x9 6x10 6x12 6x13 6x13B 7x13 7x13B 7x14 7x14B
    8x13 8x13B 9x15 9x15B 9x18 9x18B 10x20"
iso8859_11="6x13 7x13 7x13B 7x13O 7x14 7x14B 9x15 9x15B 9x18 10x20"
koi8_r="4x6 5x7 5x8 6x9 6x10 6x12 6x13 7x13 7x14 8x13 9x15 9x18 10x20"
jisx0201="7x14"
iso8859_common="ISO8859-1 ISO8859-2 ISO8859-3 ISO8859-4 ISO8859-5
    ISO8859-7 ISO8859-9 ISO8859-10 ISO8859-13 ISO8859-14 ISO8859-15
    ISO8859-16"

for f in $all $extra; do
	[ -f "$md/$f.bdf" ] || die "$md/$f.bdf is missing"
	cp "$md/$f.bdf" "$bdf/$f.bdf"
done

# convert LIST ENCODING MAP: ucs2any writes NAME-ENCODING.bdf into the
# current directory, named after the source file.
convert() {
	for f in $1; do
		(cd "$bdf" && "$work/ucs2any" "$md/$f.bdf" \
		    "$fu/map-$3" "$2" > /dev/null 2> "$work/ucs2any.log") ||
			{ cat "$work/ucs2any.log" >&2; die "ucs2any $f $2"; }
		[ -f "$bdf/$f-$2.bdf" ] || die "ucs2any did not write $f-$2.bdf"
	done
}
for e in $iso8859_common; do convert "$all" "$e" "$e"; done
convert "$iso8859_8" ISO8859-8 ISO8859-8
convert "$iso8859_11" ISO8859-11 ISO8859-11
convert "$koi8_r" KOI8-R KOI8-R
convert "$jisx0201" JISX0201.1976-0 JISX0201.1976-0

say "compiling $(ls "$bdf" | wc -l) BDF fonts to PCF"
for b in "$bdf"/*.bdf; do
	n=$(basename "$b" .bdf)
	"$work/bdftopcf" -t "$b" > "$pcf/$n.pcf" || die "bdftopcf $n"
done

# fonts.dir: the count, then "file XLFD name" for each PCF.
{
	echo "$(ls "$pcf" | wc -l | tr -d ' ')"
	for b in "$bdf"/*.bdf; do
		n=$(basename "$b" .bdf)
		printf '%s.pcf %s\n' "$n" \
		    "$(sed -n 's/^FONT //p' "$b" | head -n 1)"
	done
} > "$work/fonts.dir"

# encdir DIR: DIR/encodings.dir, the count, then "file STARTENCODING-name"
# for each .enc file in DIR.
encdir() {
	d=$1
	{
		echo "$(ls "$d"/*.enc | wc -l | tr -d ' ')"
		for f in "$d"/*.enc; do
			printf '%s %s\n' "$(basename "$f")" \
			    "$(sed -n 's/^STARTENCODING[[:space:]]*//p' "$f" | head -n 1)"
		done
	} > "$d/encodings.dir"
}

say "installing into $prefix"
misc=$prefix/misc
encodings=$prefix/encodings
mkdir -p "$misc" "$encodings/large"
install -m 444 "$pcf"/*.pcf "$misc/"
install -m 444 "$work/fonts.dir" "$misc/fonts.dir"
install -m 444 "$fa/misc/fonts.alias" "$misc/fonts.alias"
install -m 444 "$enc"/*.enc "$encodings/"
install -m 444 "$enc"/large/*.enc "$encodings/large/"
encdir "$encodings"
encdir "$encodings/large"
say "installed $(ls "$misc"/*.pcf | wc -l | tr -d ' ') PCF fonts in $misc"
