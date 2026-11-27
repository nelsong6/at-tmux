#!/bin/sh

# Spare space (ATT-37, docs/at-protocol.md): a fullscreen at-terminal's rows are
# whole pixels, so less than a row is left over, which a program can ask to go
# above a row of its pane instead of under the last row. The program sends
# at-protocol spare-space with its pane's row; tmux tells each client that
# speaks at-protocol the screen row that is, or none, when it changes. The
# client runs in a pane of a second server, the test plays the terminal by
# answering its hello, and what the client was sent is read from tmux's -vv
# output log.

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
	echo "--- the server log's end:"
	tail -40 "$(ls -t tmux-server-*.log 2>/dev/null | head -1)" | cut -c1-200
	echo "--- the pane:"
	$TMUX capture-pane -p | cat -v
	exit 1
}

PS="$(cygpath -m "$POWERSHELL_EXE")"
cat >outer.conf <<EOF
set -g default-shell "$PS"
set -g status off
set -g window-size manual
set -g default-terminal xterm-256color
EOF
cat >test.conf <<EOF
set -g default-shell "$PS"
set -g status off
set -g status-position bottom
EOF

helper() { echo "& '$PS' -NoProfile -ExecutionPolicy Bypass -File '$HELPER' -Commands '$1'"; }
$TMUX -vv -f test.conf new -d -x60 -y20 "$(helper "$CMDS")" </dev/null || exit 1
$OUTER -f outer.conf new -d -x60 -y20 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail "client never attached"

# The newest output log: upgrade-server starts another.
log() { ls -t tmux-out-*.log 2>/dev/null | head -1; }
[ -n "$(log)" ] || fail "no output log"
ESC=$(printf '\033')

# run CMD...: have the pane's program do each command, and wait until it has
# (it writes a marker last).
N=0
run() {
	for _c in "$@"; do
		echo "$_c" >>"${FILE:-commands.txt}"
	done
	N=$((N + 1))
	echo "text 20 40 done-$N" >>"${FILE:-commands.txt}"
	wait_until shows "done-$N" || fail "the pane never ran: $*"
}
shows() { $TMUX capture-pane -p | tr -d '\r' | grep -q -- "$1"; }

# from: where the log is now; sent: what the client was sent since.
from() { LOG=$(log); BEFORE=$(wc -c <"$LOG"); }
sent() { tail -c +"$((BEFORE + 1))" "$LOG" >sent.txt; }

# spare ROW|none: the spare-space message the terminal is sent, kind 5 and the
# row as four bytes, little-endian.
octal() { printf "\\$(printf '%03o' $(($1 & 255)))"; }
spare() {
	if [ "$1" = none ]; then _r=4294967295; else _r=$1; fi
	printf '%s_at;%s' "$ESC" "$({ printf '\005'; octal $_r; octal $((_r >> 8)); octal $((_r >> 16)); octal $((_r >> 24)); } | base64 -w0)"
}
# Every spare-space message sent since from (no images here, so kind 5 is the
# only one whose base64 starts with B), and the last.
spares() { sent; LC_ALL=C grep -a -o "${ESC}_at;B[A-Za-z0-9+/=]*" sent.txt; }
last_is() { [ "$(spares | tail -1)" = "$(spare "$1")" ]; }
# expect WANT WHAT: the client is told WANT.
expect() {
	wait_until last_is "$1" ||
	    fail "$2: the client was last told '$(spares | tail -1 | cut -c2-)', want $1 ('$(spare "$1" | cut -c2-)')"
}
# quiet WHAT: the client was told nothing since from, once it has drawn the
# pane's next marker.
quiet() {
	run
	drew() { sent; LC_ALL=C grep -a -q "done-$N" sent.txt; }
	wait_until drew || fail "$1: the client never drew done-$N"
	[ -z "$(spares)" ] || fail "$1: the client was told $(spares | wc -l) spare-space messages, want none"
}

# A client whose terminal hasn't said it speaks at-protocol is told nothing,
# and the request is no pane title.
from
run "spare 5"
quiet "a terminal that doesn't speak at-protocol"
case "$($TMUX display -p '#{pane_title}' | tr -d '\r')" in
*at\;*) fail "the request became the pane title: $($TMUX display -p '#{pane_title}')" ;;
esac

# hello VERSION: the APC string a terminal answers with, as hex for send-keys -H.
V=$($TMUX display -p '#{at_protocol_version}' | tr -d '\r')
[ -n "$V" ] || fail "no at_protocol_version format"
hello() {
	printf '\033_at;%s\033\\' "$(printf '\001%s%s' "$(printf "\\$(printf '%03o' ${#1})")" "$1" | base64 -w0)" |
	    od -An -tx1 | tr -d '\n'
}
from
$OUTER send-keys -t 0 -H $(hello "$V")
expect 5 "a terminal that speaks at-protocol, the pane alone"

# Drawing again with nothing changed sends nothing.
from
$TMUX refresh-client
quiet "a redraw"

# A status line above the window moves the row down; below, it doesn't.
from
$TMUX set -g status-position top \; set -g status on
expect 6 "a status line on top"
$TMUX set -g status-position bottom
expect 5 "a status line at the bottom"
$TMUX set -g status off

# A pane beside it isn't the whole width: none; alone again, its row.
from
$TMUX split-window -h
expect none "a pane split beside another"
$TMUX kill-pane
expect 5 "the split closed"

# A pane above it (5 rows and a border) moves its rows down, and its request
# counts though it isn't the active pane.
from
$TMUX split-window -v -b -l 5
[ "$($TMUX display -p -t '{bottom}' '#{pane_top}' | tr -d '\r')" = 6 ] ||
    fail "the pane below starts at $($TMUX display -p -t '{bottom}' '#{pane_top}'), want 6"
expect 11 "a pane above it"
$TMUX kill-pane
expect 5 "the pane above closed"

# The program moves it, asks for none, and for a row its pane hasn't.
from
run "spare 7"
expect 7 "the program asked for row 7"
run "spare none"
expect none "the program asked for none"
from
run "spare 20"
quiet "a row past the pane's last"
run "spare 7"
expect 7 "the program asked for row 7 again"

# A window with no request: none; back, its row.
from
$TMUX new-window
expect none "a window with no request"
$TMUX last-window
expect 7 "back to the window that asked"

# upgrade-server carries the request; the client says hello to the new server.
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
$TMUX upgrade-server "$EXE" || fail "upgrade-server refused"
upgraded() {
	_p=$($TMUX display -p '#{pid}' 2>/dev/null | tr -d '\r')
	[ -n "$_p" ] && [ "$_p" != "$PID" ] && [ "$(log)" != "$LOG" ]
}
wait_until upgraded || fail "the server was never upgraded: $($TMUX display -p '#{server_upgrade}')"
from
$OUTER send-keys -t 0 -H $(hello "$V")
expect 7 "after upgrade-server"

# A new program in the pane hasn't asked: none.
: >commands2.txt
from
$TMUX respawn-pane -k "$(helper "$(cygpath -w "$OUT/commands2.txt")")" || fail "respawn-pane failed"
expect none "the pane respawned"
FILE=commands2.txt run "spare 3"
expect 3 "the new program asked for row 3"

echo "PASS: spare space"
exit 0
