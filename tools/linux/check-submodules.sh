#!/bin/sh
#
# Check the git submodules of the tree (see docs/contrib.md).
#
#	tools/linux/check-submodules.sh [-r] [-q]
#
# Without -r, the records, which need no checkout of the submodules (the
# lint workflow): each submodule in .gitmodules is under contrib/, has a
# contrib/<name>.README.DRAGONFLY whose "commit =" is the commit the tree
# records for it, and a "url =" equal to the one in .gitmodules.
#
# With -r (build.sh, before it builds): also that each submodule is
# checked out, at the recorded commit, without changes.  A submodule that
# is not checked out is an error that says how to get it.
#
# -q: print nothing when all is well.

set -eu

SRCDIR=$(cd "$(dirname "$0")/../.." && pwd)
READY=0 QUIET=0
for a; do
	case $a in
	-r) READY=1 ;;
	-q) QUIET=1 ;;
	*) echo "usage: check-submodules.sh [-r] [-q]" >&2; exit 2 ;;
	esac
done

cd "$SRCDIR"
[ -f .gitmodules ] || { [ $QUIET = 1 ] || echo "submodules: none"; exit 0; }

bad=0 n=0
err() { echo "check-submodules.sh: $*" >&2; bad=1; }

# A tree without git (a tarball): only check that the sources are there.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
	for p in $(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' .gitmodules); do
		n=$((n + 1))
		[ -n "$(ls -A "$p" 2>/dev/null)" ] ||
		    err "$p: empty, and this tree is not a git checkout"
	done
	[ $bad = 0 ] || exit 1
	[ $QUIET = 1 ] || echo "submodules: $n present (no git)"
	exit 0
fi

for key in $(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$'); do
	n=$((n + 1))
	p=$(git config -f .gitmodules "$key")
	name=${key#submodule.}; name=${name%.path}
	url=$(git config -f .gitmodules "submodule.$name.url" || :)
	case $p in
	contrib/*/*|contrib/) err "$p: a submodule goes right under contrib/"; continue ;;
	contrib/*) ;;
	*) err "$p: a submodule goes under contrib/"; continue ;;
	esac
	# The commit the tree records (the gitlink), from the index.
	rec=$(git ls-files -s -- "$p" | awk '$1 == "160000" { print $2 }')
	[ -n "$rec" ] || { err "$p: in .gitmodules but not a submodule in the tree"; continue; }
	readme=$p.README.DRAGONFLY
	if [ ! -f "$readme" ]; then
		err "$p: no $readme (url, tag, commit, what is built)"
	else
		c=$(sed -n 's/^commit[[:space:]]*=[[:space:]]*//p' "$readme")
		[ "$c" = "$rec" ] ||
		    err "$readme: commit = ${c:-(none)}, the tree has $rec"
		u=$(sed -n 's/^url[[:space:]]*=[[:space:]]*//p' "$readme")
		[ "$u" = "$url" ] ||
		    err "$readme: url = ${u:-(none)}, .gitmodules has $url"
		grep -q '^tag[[:space:]]*=' "$readme" ||
		    err "$readme: no tag = line (the upstream release)"
	fi
	[ $READY = 1 ] || continue
	if [ ! -e "$p/.git" ]; then
		err "$p is not checked out: run
	git submodule update --init --recursive
(or clone with --recurse-submodules)"
		continue
	fi
	head=$(git -C "$p" rev-parse HEAD)
	[ "$head" = "$rec" ] ||
	    err "$p is at $head, the tree records $rec: run git submodule update $p"
	[ -z "$(git -C "$p" status --porcelain --untracked-files=all)" ] ||
	    err "$p has changes: the build never writes there, and local changes belong in the build directory (docs/contrib.md)"
done

[ $bad = 0 ] || exit 1
[ $QUIET = 1 ] || echo "submodules: $n ok"
