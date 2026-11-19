#!/bin/sh

# A pane whose pipe-pane program is still running goes away cleanly, by
# kill-pane and by kill-server, and the server keeps running after the first
# (TMUX-241: freeing the pane closed the pipe, a socket, with the C runtime's
# close(), whose invalid argument handler ended the server).

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

fail() {
	echo "FAIL: $1"
	[ -n "$log" ] && [ -f "$log" ] && cat "$log"
	exit 1
}

# findstr reads its input until it ends, so the pipe stays open until tmux
# closes it.
READER="$(cygpath -w "$SYSTEMROOT/System32/findstr.exe") x"

# piped TARGET: TARGET's pipe is open.
piped() {
	[ "$($TMUX display -p -t "$1" '#{pane_pipe}' 2>/dev/null | tr -d '\r')" = 1 ]
}

# The server's %TEMP% is GetTempPath's, which reads TMP first.
TMP=$(cygpath -w "$OUT") $TMUX -fNUL new -d -s pipe -x 80 -y 24 </dev/null ||
    fail "new-session"
$TMUX set -g default-shell "$COMSPEC" || fail "default-shell"
server=$($TMUX display -p '#{pid}' | tr -d '\r')
[ -n "$server" ] || fail "no server pid"
log=$OUT/tmux-crash-$server.log

# kill-pane, with plenty of output still going through the pipe.
$TMUX split-window -d -t pipe: || fail "split-window"
wait_panes pipe: 2 || fail "no second pane"
$TMUX pipe-pane -O -t pipe:.1 "$READER" || fail "pipe-pane"
wait_until piped pipe:.1 || fail "pipe not open"
$TMUX send-keys -t pipe:.1 'for /l %i in (1,1,3000) do @echo line %i' Enter
wait_for pipe:.1 '^line 3000' || fail "output not printed"
$TMUX kill-pane -t pipe:.1 || fail "kill-pane"
wait_panes pipe: 1 || fail "piped pane not closed"
$TMUX has-session -t pipe 2>/dev/null || fail "server ended at kill-pane"

# kill-server, with the remaining pane piped.
$TMUX pipe-pane -O -t pipe:.0 "$READER" || fail "second pipe-pane"
wait_until piped pipe:.0 || fail "second pipe not open"
$TMUX kill-server || fail "kill-server"
wait_gone || fail "server still running after kill-server"
[ ! -f "$log" ] || fail "server crashed at kill-server"

echo 'ALL PIPE-PANE CLOSE TESTS PASSED'
