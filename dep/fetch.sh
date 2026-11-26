#!/bin/sh

# A pinned package's source for the Mac and Linux builds, which configure runs
# (TMUX-239, AHT-204): sh dep/fetch.sh <srcdir> <port> <url> <file>...
# The version is the one the Windows build pins: the REF in
# dep/vcpkg-overlay-ports/<port>/portfile.cmake, the one place it is chosen.
# The work machines can't reach Forgejo, so the source comes from its GitHub
# push mirror (at-protocol's is private: git needs a GitHub sign-in, as for
# pushing at-tmux; logline's is public). <PORT>_URL (at-protocol's is
# AT_PROTOCOL_URL) names another copy. The source goes in dep/<port>, fetched
# again only when the REF changes or a <file> is missing; the REF is printed
# for configure.

srcdir=${1:-.}
name=$2
port="$srcdir/dep/vcpkg-overlay-ports/$name/portfile.cmake"
dir="$srcdir/dep/$name"
variable=$(echo "$name" | tr 'a-z-' 'A-Z_')_URL
eval "url=\${$variable:-$3}"
shift 3

ref=$(sed -n 's/^set(REF \([0-9a-f]\{40\}\))$/\1/p' "$port")
if [ -z "$ref" ]; then
	echo "no set(REF <commit>) in $port" >&2
	exit 1
fi
have=yes
for file in "$@"; do
	[ -f "$dir/$file" ] || have=no
done
if [ "$(cat "$dir/.ref" 2>/dev/null)" = "$ref" ] && [ $have = yes ]; then
	echo "$ref"
	exit 0
fi

rm -rf "$dir"
# No sign-in fails at once rather than waiting on a prompt configure can't show.
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
if ! git init -q "$dir" ||
    ! git -C "$dir" fetch -q --depth 1 "$url" "$ref" ||
    ! git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD; then
	rm -rf "$dir"
	echo "can't fetch $name $ref from $url" >&2
	exit 1
fi
echo "$ref" >"$dir/.ref"
echo "$ref"
