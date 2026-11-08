#!/bin/sh

# {caller} names the pane a command was run from, not the current window, so a
# program in a background window can set its own window's options; play-sound
# refuses a file it can't read, and records a sound held back with -s
# (TMUX-168).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

FNULL="-fNUL"
trap "$TMUX kill-server 2>/dev/null" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name}' 2>&1
	exit 1
}

opt() {
	$TMUX show -wqv -t "$1" "$2" 2>/dev/null | tr -d '\r'
}

opt_is() {
	[ "$(opt "$1" "$2")" = "$3" ]
}

WTMUX=$(cygpath -w "$(readlink -f "$TEST_TMUX")")

$TMUX $FNULL new -d -s p -n front </dev/null || fail "start server"
$TMUX set -g remain-on-exit on || fail "remain-on-exit"

# A program in a background window sets an option on its own window.
$TMUX new-window -d -t p: -n back "$WTMUX" set -w -t '{caller}' @hook yes ||
    fail "new-window"
wait_until opt_is p:back @hook yes ||
    fail "{caller}: the background window has no @hook"
[ -z "$(opt p:front @hook)" ] || fail "{caller}: the current window got @hook"

# Without a target the same command still means the current window.
$TMUX new-window -d -t p: -n back2 "$WTMUX" set -w @plain yes ||
    fail "new-window back2"
wait_until opt_is p:front @plain yes ||
    fail "no target: the current window has no @plain"

# Outside any pane there is no caller.
out=$(env -u TMUX -u TMUX_PANE $TMUX set -w -t '{caller}' @x 1 2>&1) &&
    fail "{caller} from outside a pane succeeded"
echo "$out" | grep -q 'caller' || fail "{caller}: wrong error: $out"

# play-sound fails on a file it can't read.
out=$($TMUX play-sound 'C:\no\such\file.wav' 2>&1) &&
    fail "play-sound of a missing file succeeded"
echo "$out" | grep -q "can't read" || fail "play-sound: wrong error: $out"

# -s plays nothing and records why in the server's log, as a format for the target.
$TMUX set -w -t p:front @hold 'landing x #1' || fail "set @hold"
$TMUX play-sound -t p:front -s 'held: #{@hold}' 'C:/no/such/file.wav' ||
    fail "play-sound -s failed"
cat "$TMUX_ERROR_LOG_DIR"/tmux-*.log | tr -d '\r' |
    grep -q 'play-sound did not play C:/no/such/file.wav for window @[0-9]* (front): held: landing x #1$' ||
    fail "play-sound -s: no record in: $(cat "$TMUX_ERROR_LOG_DIR"/tmux-*.log)"

exit 0
