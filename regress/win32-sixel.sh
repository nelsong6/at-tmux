#!/bin/sh

# A sixel image a pane prints reaches the attached client's terminal as a sixel
# image, not as tmux's "SIXEL IMAGE" text placeholder, and still does after the
# client is resized (TMUX-190). The Windows console reports no pixel size, so
# the client asks its terminal (CSI 14 t); without the answer tmux can't scale
# an image and draws the placeholder. The client runs in a pane of a second
# server, which stands in for Windows Terminal; what it sent its terminal is
# read from tmux's -vv output log.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TEST_TMUX=$(cd "$(dirname "$TEST_TMUX")" && pwd)/$(basename "$TEST_TMUX")
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
# The server's own logs stay open until it has gone.
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1

# The outer server answers device attributes as a VT100, not a level 4
# terminal listing sixel as Windows Terminal does, so the feature is given here.
# Windows are sized by hand: resizing a pane drops its images, and the resize
# below is the client's alone.
cat >test.conf <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
set -g window-size manual
set -as terminal-features ',xterm-256color:sixel'
EOF

# A red block 20 pixels wide and 12 high, on a cleared screen. The double quote
# is [char]34: the pane's command line loses a literal one.
E='[string][char]27'
Q='[string][char]34'
PRINT="[Console]::Write($E + '[H' + $E + '[2J' + $E + 'Pq' + $Q + '1;1;20;12#1;2;100;0;0#1!20~-!20~' + $E + '\\' + 'AFTER-IMAGE')"
$TMUX -vv -f test.conf new -d -x40 -y10 \
    "while (-not (Test-Path '$(cygpath -m "$OUT/go")')) { Start-Sleep -Milliseconds 50 }; $PRINT; Start-Sleep 60" \
    </dev/null || exit 1
$OUTER -f test.conf new -d -x40 -y10 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }
cell_known() {
	case "$($TMUX list-clients -F '#{client_cell_width}x#{client_cell_height}' | tr -d '\r')" in
	[1-9]*x[1-9]*) return 0 ;;
	esac
	return 1
}
wait_until cell_known || { echo "the client never learned its cell size"; exit 1; }

LOG=$(ls tmux-out-*.log 2>/dev/null | head -1)
[ -n "$LOG" ] || { echo 'no output log'; exit 1; }

# drawn FROM: from byte FROM of the log, the client drew the text that follows
# the image, and with it the image as a sixel and no placeholder.
drawn() {
	tail -c +"$(($1 + 1))" "$LOG" >drawn.txt
	grep -a -q AFTER-IMAGE drawn.txt
}
check() {
	if ! wait_until drawn "$1"; then
		echo "$2: the client never drew the pane"
		$OUTER capture-pane -p
		exit 1
	fi
	if grep -a -q 'SIXEL IMAGE' drawn.txt; then
		echo "$2: the client drew the text placeholder"
		exit 1
	fi
	if ! grep -a -q "$(printf '\033')P0;[0-9]*q" drawn.txt; then
		echo "$2: the client sent no sixel image"
		exit 1
	fi
}

touch "$OUT/go"
check 0 "first draw"

# A resize gives the client a new size in cells, not pixels: it keeps its cell
# size, so the image never falls back to the placeholder while it asks again.
before=$(wc -c <"$LOG")
$OUTER resize-window -x 50 -y 12
check "$before" "after a resize"

echo "ALL SIXEL TESTS PASSED"
exit 0
