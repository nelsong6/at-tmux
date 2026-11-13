#!/bin/sh

# close-pane, close-window and close-session ask a pane's programs to close:
# its console sends them the close event, as closing a Windows Terminal tab
# does, and the pane goes once they have exited, whatever remain-on-exit says.
# Windows ends a program still running about five seconds later.
# win32-close-watch.ps1 records the events a program gets.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

DIR=$(mktemp -d)
WDIR=$(cygpath -m "$DIR")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -rf $DIR $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name} #{window_panes} closing=#{window_closing}' 2>&1
	for f in "$DIR"/mark-*; do
		[ -f "$f" ] && { echo "$f:"; cat "$f"; }
	done
	exit 1
}

WATCH=$(cygpath -wa "$(dirname "$0")/win32-close-watch.ps1")
PS="$SYSTEMROOT\System32\WindowsPowerShell\v1.0\powershell.exe"

# watch NAME [HANG]: the command for a program that records its events in
# mark-NAME and returns from its handler after HANG seconds.
watch() {
	echo "$PS" -NoProfile -File "$WATCH" -Mark "$WDIR/mark-$1" -Hang "${2:-0}"
}
marked() { tr -d '\r' <"$DIR/mark-$1" 2>/dev/null | grep -qx "$2"; }
has_window() {
	$TMUX lsw -t"=$1" -F '#{window_name}' 2>/dev/null | tr -d '\r' |
	    grep -qx "$2"
}
no_window() { ! has_window "$@"; }
no_session() { ! $TMUX has -t"=$1" 2>/dev/null; }
# shows TARGET FORMAT VALUE: FORMAT expands to VALUE at TARGET, asked anew
# each time.
shows() {
	[ "$($TMUX display -p -t "$1" "$2" 2>/dev/null | tr -d '\r')" = "$3" ]
}
upgrade_reason() { $TMUX display -p '#{server_upgrade}' | grep -q "$1"; }

$TMUX -f"$(cygpath -m $CFG)" new -d -s main -n keep || fail "start server"
$TMUX set -g @session-set-dir "$WDIR" || fail "set dir"

# A program that handles the close event finishes its handler, and its
# window goes with no exit error recorded.
$TMUX neww -d -t main: -n polite $(watch polite) || fail "start polite"
wait_for main:polite '^watching' || fail "polite did not start"
$TMUX close-window -t main:polite || fail "close-window"
wait_until no_window main polite || fail "polite window stayed"
marked polite 'event 2' || fail "polite got no close event"
marked polite 'handled' || fail "polite handler did not finish"
$TMUX show-messages | grep -q 'exited with status' &&
    fail "a closed pane's exit was recorded as an error"

# One that ignores it keeps its window, marked closing, until Windows ends it.
$TMUX neww -d -t main: -n stubborn $(watch stubborn 60) ||
    fail "start stubborn"
wait_for main:stubborn '^watching' || fail "stubborn did not start"
$TMUX close-window -t main:stubborn || fail "close stubborn"
wait_until marked stubborn 'event 2' || fail "stubborn got no close event"
[ "$($TMUX display -p -t main:stubborn '#{window_closing} #{pane_closing}' |
    tr -d '\r')" = "1 1" ] || fail "stubborn not shown as closing"
WAIT_TIMEOUT=20 wait_until no_window main stubborn ||
    fail "Windows did not end a program ignoring the close event"
marked stubborn 'handled' && fail "stubborn handler finished"

# The event reaches a program the pane's shell started, as well as the shell.
$TMUX neww -d -t main: -n shell || fail "start shell"
wait_ready main:shell || fail "shell not ready"
$TMUX send-keys -t main:shell "$(watch child)" Enter
wait_for main:shell '^watching' || fail "child did not start"
$TMUX close-window -t main:shell || fail "close shell"
wait_until no_window main shell || fail "shell window stayed"
marked child 'event 2' || fail "the shell's program got no close event"

# remain-on-exit does not keep a pane asked to close, a relaunching one
# included.
for remain in on relaunch; do
	$TMUX neww -d -t main: -n "remain-$remain" $(watch "remain-$remain") ||
	    fail "start remain-$remain"
	$TMUX set -w -t "main:remain-$remain" remain-on-exit $remain
	wait_for "main:remain-$remain" '^watching' ||
	    fail "remain-$remain did not start"
	$TMUX close-window -t "main:remain-$remain" ||
	    fail "close remain-$remain"
	wait_until no_window main "remain-$remain" ||
	    fail "remain-on-exit $remain kept a closed window"
done

# A pane already dead goes at once.
$TMUX neww -d -o remain-on-exit=on -t main: -n dead "$COMSPEC" //c exit 3 ||
    fail "start dead"
wait_until shows main:dead '#{pane_dead}' 1 || fail "dead pane did not die"
$TMUX close-pane -t main:dead || fail "close dead pane"
has_window main dead && fail "dead pane's window stayed"

# close-pane closes one pane; the window stays with the other. close-pane -a
# closes all but one.
P0=$($TMUX neww -d -P -F '#{pane_id}' -t main: -n split $(watch split-0) |
    tr -d '') || fail "start split"
P1=$($TMUX splitw -d -P -F '#{pane_id}' -t "$P0" $(watch split-1) |
    tr -d '') || fail "split 1"
P2=$($TMUX splitw -d -P -F '#{pane_id}' -t "$P0" $(watch split-2) |
    tr -d '') || fail "split 2"
for p in $P0 $P1 $P2; do
	wait_for "$p" '^watching' || fail "$p did not start"
done
$TMUX close-pane -t "$P2" || fail "close-pane"
wait_panes main:split 2 || fail "close-pane left the pane"
marked split-2 'event 2' || fail "closed pane got no close event"
[ "$($TMUX display -p -t main:split '#{window_closing}' | tr -d '\r')" = 0 ] ||
    fail "window with a pane left marked closing"
$TMUX close-pane -a -t "$P0" || fail "close-pane -a"
wait_panes main:split 1 || fail "close-pane -a left panes"
marked split-1 'event 2' || fail "close-pane -a sent no close event"
[ -f "$DIR/mark-split-0" ] && fail "close-pane -a closed the pane kept"

# close-window -a closes every other window in the session.
$TMUX neww -d -t main: -n other $(watch other) || fail "start other"
wait_for main:other '^watching' || fail "other did not start"
$TMUX close-window -a -t main:keep || fail "close-window -a"
wait_until no_window main other || fail "close-window -a left other"
wait_until no_window main split || fail "close-window -a left split"
has_window main keep || fail "close-window -a closed the window kept"

# reopen-window brings back a closed window with every pane it had, though
# its panes went one at a time.
$TMUX neww -d -t main: -n pair $(watch pair-0) || fail "start pair"
$TMUX splitw -d -t main:pair $(watch pair-1 60) || fail "split pair"
wait_for main:pair.0 '^watching' || fail "pair.0 did not start"
wait_for main:pair.1 '^watching' || fail "pair.1 did not start"
$TMUX close-window -t main:pair || fail "close pair"
WAIT_TIMEOUT=20 wait_until no_window main pair || fail "pair stayed"
$TMUX reopen-window -d || fail "reopen pair"
wait_until has_window main pair || fail "pair not reopened"
[ "$($TMUX display -p -t main:pair '#{window_panes}' | tr -d '\r')" = 2 ] ||
    fail "pair reopened without both panes"
$TMUX kill-window -t main:pair

# close-session ends the session with its last window, opening no
# keep-alive window; a window linked to another session only leaves it.
$TMUX new -d -s gone -n first $(watch first) || fail "start gone"
$TMUX neww -d -t gone: -n second $(watch second) || fail "second"
$TMUX neww -d -t main: -n shared $(watch shared) || fail "shared"
$TMUX link-window -s main:shared -t gone: || fail "link shared"
$TMUX set -t gone keep-alive-window spare
wait_for gone:first '^watching' || fail "first did not start"
wait_for gone:second '^watching' || fail "second did not start"
wait_for main:shared '^watching' || fail "shared did not start"
$TMUX close-session -t gone || fail "close-session"
wait_until no_session gone || fail "close-session left the session"
marked first 'event 2' || fail "first got no close event"
marked second 'event 2' || fail "second got no close event"
has_window main shared || fail "close-session closed a linked window"
[ -f "$DIR/mark-shared" ] && fail "linked window got a close event"
$TMUX kill-window -t main:shared

# close-session -a closes every other session.
$TMUX new -d -s a1 $(watch a1) || fail "start a1"
$TMUX new -d -s a2 $(watch a2) || fail "start a2"
wait_for a1: '^watching' || fail "a1 did not start"
wait_for a2: '^watching' || fail "a2 did not start"
$TMUX close-session -a -t main || fail "close-session -a"
wait_until no_session a1 || fail "close-session -a left a1"
wait_until no_session a2 || fail "close-session -a left a2"
$TMUX has -t=main || fail "close-session -a closed the session kept"

# The defaults: prefix & and x ask before closing, and the window and pane
# menus offer Close beside Kill.
$TMUX list-keys -T prefix '&' | grep -q 'close-window' ||
    fail "prefix & does not close the window"
$TMUX list-keys -T prefix x | grep -q 'close-pane' ||
    fail "prefix x does not close the pane"
$TMUX list-keys -T root MouseDown3Status | grep -q "Close.*close-window" ||
    fail "window menu has no Close"
$TMUX list-keys -T root MouseDown3Pane | grep -q "Close.*close-pane" ||
    fail "pane menu has no Close"

# An upgrade waits while a pane is closing (only conpty.dll's consoles can
# be handed over at all).
if [ -f "$(dirname "$TEST_TMUX")/conpty.dll" ]; then
	$TMUX neww -d -t main: -n slow $(watch slow 60) || fail "start slow"
	wait_for main:slow '^watching' || fail "slow did not start"
	$TMUX close-window -t main:slow || fail "close slow"
	$TMUX upgrade-server "$(cygpath -wa "$TEST_TMUX")" ||
	    fail "upgrade-server"
	wait_until upgrade_reason 'is closing' ||
	    fail "upgrade did not wait for the closing pane"
	WAIT_TIMEOUT=20 wait_until no_window main slow || fail "slow stayed"
	WAIT_TIMEOUT=20 wait_until shows main: '#{server_upgrade}' '' ||
	    fail "upgrade did not finish after the close"
fi

echo "ALL CLOSE TESTS PASSED"
