#!/bin/sh

# tmux and the terminal agree how wide a character is. An emoji counted 1 column while
# the terminal drew it 2 pushed the rest of its row right, under a side panel or past
# the pane's edge (TMUX-159): a Windows wchar_t is 16 bits and can't hold one. The values
# go through a config file, since command-line arguments are in the ANSI code page.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d)
CFG=$(cygpath -ma "$OUT/width.conf")
trap '$TMUX kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

{
	printf 'set -g @clock "\360\237\225\222"\n'     # U+1F552, past U+FFFF
	printf 'set -g @robot "\360\237\244\226"\n'     # U+1F916
	printf 'set -g @folder "\360\237\223\202"\n'    # U+1F4C2
	printf 'set -g @check "\342\234\205"\n'         # U+2705, an emoji under U+FFFF
	printf 'set -g @cjk "\346\227\245"\n'           # U+65E5
	printf 'set -g @mean "\342\214\200"\n'          # U+2300, narrow
	printf 'set -g @accented "e\314\201"\n'         # e and a combining acute
	printf 'set -g @powerline "\356\202\260"\n'     # U+E0B0, private use
} >"$CFG"

$TMUX -f "$CFG" new -d -x80 -y5 || fail 'no server'

width() {
	got=$($TMUX display-message -p "#{w:@$1}" | tr -d '\r')
	[ "$got" = "$2" ] || fail "@$1 is $got wide, not $2"
}

width clock 2
width robot 2
width folder 2
width check 2
width cjk 2
width mean 1
width accented 1
width powerline 1

# The option that overrides a width reaches a character past U+FFFF too.
$TMUX set -g codepoint-widths 'U+1F552=1'
width clock 1
width robot 2

echo 'ALL CHARACTER WIDTH TESTS PASSED'
