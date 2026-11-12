#!/bin/sh

# A window takes the cell size of the terminal its client attached from, which
# a program in it reads with CSI 16 t to size its images (AHT-129: a preview of
# at-claude in a client attached inside a pane drew its avatars for tmux's
# default 16x32 cell). The Windows console reports no pixels, so the client asks
# its terminal (CSI 14 t) and the answer comes after it attached: the client
# sizes no window until then. Checked for a window the client resizes and for
# one already at the client's size, whose cell is all that changes. The client
# runs in a pseudo-console whose host answers as a terminal with 10x20 cells.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15

PS="$(cygpath "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

cell() {
	$TMUX $1 -F "#{$2_cell_width}x#{$2_cell_height}" 2>/dev/null | tr -d '\r'
}
client_cell_is() {
	[ "$(cell list-clients client)" = "$1" ]
}
window_cell_is() {
	[ "$(cell 'display -p' window)" = "$1" ]
}

# attach_with SIZE: a client attaches from an 89x24 console to a window
# started at SIZE, and the window takes its 10x20 cell.
attach_with() {
	$TMUX -fNUL new -d -x"${1%x*}" -y"${1#*x}" </dev/null || exit 1
	"$PS" -NoProfile -ExecutionPolicy Bypass \
	    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
	    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
	    -Cols 89 -Rows 24 -ResizeFile "$(cygpath -w "$OUT/resize")" \
	    -CellWidth 10 -CellHeight 20 &
	host=$!

	if ! wait_until client_cell_is 10x20; then
		echo "window at $1: the client's cell is $(cell list-clients client), expected 10x20"
		exit 1
	fi
	if ! wait_until window_cell_is 10x20; then
		echo "window at $1: its cell is $(cell 'display -p' window), expected the client's 10x20"
		exit 1
	fi

	$TMUX kill-server 2>/dev/null
	wait $host
	wait_gone
}

attach_with 100x30
attach_with 89x23

echo "ALL CELL-SIZE TESTS PASSED"
exit 0
