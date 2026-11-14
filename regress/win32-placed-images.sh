#!/bin/sh

# Placed images (TMUX-212): a program places an image by ID with the kitty
# graphics protocol and tmux keeps it, whatever is written or cleared over it,
# until the program deletes it. tmux draws it again over text written under it
# and on every redraw, sends it to the terminal as sixel, moves it as its rows
# scroll, answers a=q, and carries it across upgrade-server. A sixel image
# still goes when its row is cleared, as it always has. The client runs in a
# pane of a second server; what it sent its terminal is read from tmux's -vv
# output log, and a client redraw (refresh-client) shows what tmux holds.

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

HELPER=$(cygpath -w "$(cd "$(dirname "$0")" && pwd)/win32-kitty.ps1")
OUT=$(mktemp -d)
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1
EXE=$(cygpath -w "$TEST_TMUX")
CMDS=$(cygpath -w "$OUT/commands.txt")
: >commands.txt

fail() {
	echo "FAIL: $*"
	exit 1
}

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
cat >outer.conf <<EOF
set -g default-shell "$PS"
set -g status off
set -g window-size manual
# The outer server stands in for Windows Terminal, whose TERM is xterm-256color.
set -g default-terminal xterm-256color
EOF
cat >test.conf <<EOF
set -g default-shell "$PS"
set -as terminal-features ',xterm-256color:sixel'
set -g status off
EOF

$TMUX -vv -f test.conf new -d -x60 -y20 \
    "& '$PS' -NoProfile -ExecutionPolicy Bypass -File '$HELPER' -Commands '$CMDS'" \
    </dev/null || exit 1
$OUTER -f outer.conf new -d -x60 -y20 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail "client never attached"
cell_known() {
	case "$($TMUX list-clients -F '#{client_cell_width}x#{client_cell_height}' | tr -d '\r')" in
	[1-9]*x[1-9]*) return 0 ;;
	esac
	return 1
}
wait_until cell_known || fail "the client never learned its cell size"

# The newest output log: upgrade-server starts another.
log() { ls -t tmux-out-*.log 2>/dev/null | head -1; }
[ -n "$(log)" ] || fail "no output log"
ESC=$(printf '\033')

# run CMD...: have the pane's program do each command, and wait until it has
# (it writes a marker last).
N=0
run() {
	for _c in "$@"; do
		echo "$_c" >>commands.txt
	done
	N=$((N + 1))
	echo "text 20 40 done-$N" >>commands.txt
	wait_until shows "done-$N" || fail "the pane never ran: $*"
}
shows() { $TMUX capture-pane -p | tr -d '\r' | grep -q -- "$1"; }

# from: where the log is now; sent: what the client was sent since.
from() { LOG=$(log); BEFORE=$(wc -c <"$LOG"); }
sent() { tail -c +"$((BEFORE + 1))" "$LOG" >sent.txt; }
sixels() { LC_ALL=C grep -a -o "${ESC}P" sent.txt | wc -l; }
# held N: a redraw of the client draws N images.
held() {
	from
	$TMUX refresh-client
	_want=$1
	_held() { sent; [ "$(sixels)" -eq "$_want" ]; }
	wait_until _held || fail "${2:-}: a redraw drew $(sixels) images, want $_want"
}
# at ROW COL: what was sent puts an image there (1-based, the client's rows).
at() { LC_ALL=C grep -a -q "${ESC}\[$1;$2H${ESC}P" sent.txt; }

held 0 "before anything"

# Placing draws it, and the client keeps being sent it.
from
run "place 7 3 1 2x2"
sent
[ "$(sixels)" -ge 1 ] || fail "placing an image sent no sixel"
held 1 "placed"
at 3 1 || fail "the placed image isn't at row 3: $(cat -v sent.txt | head -c 400)"

# Text beside it changes nothing about it.
from
run "text 3 10 beside"
sent
[ "$(sixels)" -eq 0 ] || fail "text beside the image sent it again"

# Writing over it, clearing its row or the screen keeps it, drawn again.
for what in "text 3 1 XX" "clearline 3" "text 4 1 YY" "clearline 4" "cls"; do
	from
	run "$what"
	_redrawn() { sent; [ "$(sixels)" -ge 1 ]; }
	wait_until _redrawn || fail "after $what the image wasn't drawn again"
	held 1 "after $what"
done

# The same ID placed elsewhere replaces it.
run "place 7 6 1 2x2"
held 1 "moved"
at 6 1 || fail "the moved image isn't at row 6"

# Deleting it by ID removes it.
run "delete 7"
held 0 "deleted"

# Chunked transmission.
run "chunked 9 10 5"
held 1 "chunked"
at 10 5 || fail "the chunked image isn't at row 10 column 5"

# Scrolling moves it with its row.
run "scroll"
held 1 "scrolled"
at 9 5 || fail "the image didn't move up a row with its text"

# a=q answers, and says why it can't take a PNG.
run "query 31" "badquery 32"
srv=$(ls -t tmux-server-*.log | head -1)
grep -q 'i=31;OK' "$srv" || fail "no OK answer to a=q"
grep -q 'i=32;ENOTSUP' "$srv" || fail "no ENOTSUP answer to a=q for a PNG"

# A sixel image goes when its row is cleared, as before.
run "sixel 14 20"
held 2 "with a sixel image"
run "text 14 1 ZZ" "clearline 14"
held 1 "after clearing the sixel image's row"

# A synchronized update ends in a redraw that includes it.
from
run "sync 9 30 synced"
sent
[ "$(sixels)" -ge 1 ] || fail "a synchronized update's redraw left out the image"

# upgrade-server carries it.
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
$TMUX upgrade-server "$EXE" || fail "upgrade-server refused"
upgraded() {
	_p=$($TMUX display -p '#{pid}' 2>/dev/null | tr -d '\r')
	[ -n "$_p" ] && [ "$_p" != "$PID" ] && [ "$(log)" != "$LOG" ]
}
wait_until upgraded || fail "the server was never upgraded: $($TMUX display -p '#{server_upgrade}')"
held 1 "after upgrade-server"
at 9 5 || fail "the image moved in the upgrade"
run "delete 9"
held 0 "deleted after upgrade-server"

echo "PASS: placed images"
exit 0
