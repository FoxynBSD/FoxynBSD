#!/bin/sh
#
# Check the boot menu logos in stand/boot/dloader/cmds.c: Wisdom
# (wisdom_orange, wisdom_red, wisdom_mono) and Fred (fred_indigo,
# fred_red, fred_mono).
#
#	- each array has LOGO_LINES (16) lines;
#	- each line is 33 columns once its ANSI color sequences (ESC [ ... m)
#	  are taken out, and has only printable ASCII besides them;
#	- a line with colors ends with the reset, ESC [ 0 m;
#	- the variants of a logo have the same characters at the same places:
#	  only their colors differ.
#
# Usage:
#	tools/linux/check-logos.sh [-p] [cmds.c]
#
#	-p	also print each logo's characters (the plain version)

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
PRINT=
if [ "${1:-}" = -p ]; then PRINT=1; shift; fi
FILE=${1:-$SRCDIR/stand/boot/dloader/cmds.c}
[ -f "$FILE" ] || { echo "check-logos.sh: no $FILE" >&2; exit 2; }

LC_ALL=C awk -v print_art="$PRINT" '
BEGIN {
	esc = sprintf("%c", 27)
	split("wisdom_orange wisdom_red wisdom_mono fred_indigo fred_red fred_mono", names, " ")
	for (i in names)
		want[names[i]] = 1
	bad = 0
}
/^#define[ \t]+LOGO_LINES[ \t]/ { lines = $3 }
# static char *name[LOGO_LINES] = {
/^static char \*[a-z_]+\[LOGO_LINES\]/ {
	name = $3
	sub(/^\*/, "", name)
	sub(/\[.*/, "", name)
	if (!(name in want)) { name = ""; next }
	n[name] = 0
}
name != "" {
	s = $0
	# The quoted strings on this line, in order.
	while (match(s, /"([^"\\]|\\.)*"/)) {
		str = substr(s, RSTART + 1, RLENGTH - 2)
		s = substr(s, RSTART + RLENGTH)
		gsub(/\\\\/, "\\", str)
		gsub(/\\"/, "\"", str)
		raw = str
		plain = str
		gsub(esc "\\[[0-9;]*m", "", plain)
		k = ++n[name]
		art[name, k] = plain
		if (index(plain, esc) != 0) {
			printf "%s line %d: an escape other than a color sequence\n", name, k
			bad = 1
		}
		if (plain ~ /[^ -~]/) {
			printf "%s line %d: a character that is not printable ASCII\n", name, k
			bad = 1
		}
		if (length(plain) != 33) {
			printf "%s line %d: %d columns, not 33: [%s]\n", name, k, length(plain), plain
			bad = 1
		}
		if (raw != plain && substr(raw, length(raw) - 3) != esc "[0m") {
			printf "%s line %d: colors without the reset (ESC[0m) at the end\n", name, k
			bad = 1
		}
	}
	if ($0 ~ /};/)
		name = ""
}
END {
	if (lines != 16) {
		printf "LOGO_LINES is %s, not 16\n", lines
		bad = 1
	}
	for (i = 1; i <= 6; i++) {
		nm = names[i]
		if (!(nm in n)) {
			printf "%s: not found\n", nm
			bad = 1
			continue
		}
		if (n[nm] != lines) {
			printf "%s: %d lines, not %d\n", nm, n[nm], lines
			bad = 1
		}
	}
	# The colored variants against the plain one.
	split("wisdom_orange:wisdom_mono wisdom_red:wisdom_mono fred_indigo:fred_mono fred_red:fred_mono", pairs, " ")
	for (p in pairs) {
		split(pairs[p], ab, ":")
		for (k = 1; k <= lines; k++)
			if (art[ab[1], k] != art[ab[2], k]) {
				printf "%s line %d differs from %s: [%s] [%s]\n", ab[1], k, ab[2], art[ab[1], k], art[ab[2], k]
				bad = 1
			}
	}
	if (print_art != "")
		for (i = 3; i <= 6; i += 3)
			for (k = 1; k <= lines; k++)
				printf "%-13s |%s|\n", names[i], art[names[i], k]
	if (bad)
		exit 1
	print "logos: 6 arrays of " lines " lines, 33 columns; variants agree"
}' "$FILE"
