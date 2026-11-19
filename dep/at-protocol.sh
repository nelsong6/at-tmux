#!/bin/sh

# at-protocol's source for the Mac and Linux builds (TMUX-239), which configure
# runs. The version is the one the Windows build pins: the REF in
# dep/vcpkg-overlay-ports/at-protocol/portfile.cmake, the one place it is chosen.
# The work machines can't reach Forgejo, so the source comes from its GitHub
# push mirror (private: git needs a GitHub sign-in, as for pushing at-tmux).
# AT_PROTOCOL_URL names another copy. The source goes in dep/at-protocol, fetched
# again only when the REF changes; the REF is printed for configure.

srcdir=${1:-.}
port="$srcdir/dep/vcpkg-overlay-ports/at-protocol/portfile.cmake"
dir="$srcdir/dep/at-protocol"
url=${AT_PROTOCOL_URL:-https://github.com/romaine-life/at-protocol.git}

ref=$(sed -n 's/^set(REF \([0-9a-f]\{40\}\))$/\1/p' "$port")
if [ -z "$ref" ]; then
	echo "no set(REF <commit>) in $port" >&2
	exit 1
fi
if [ "$(cat "$dir/.ref" 2>/dev/null)" = "$ref" ] &&
    [ -f "$dir/src/at_protocol.c" ] && [ -f "$dir/include/at_protocol.h" ]; then
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
	echo "can't fetch at-protocol $ref from $url" >&2
	exit 1
fi
echo "$ref" >"$dir/.ref"
echo "$ref"
