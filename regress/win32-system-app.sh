#!/bin/sh

# An app with one place (TMUX-167). remain-on-exit relaunch keeps a pane on any
# exit, its line saying so and that Enter starts it again, which it does; no
# other key does. new-window -M finds the app's window in any session, by its
# @<name>-window mark or by a lone pane started as its program, moves it into
# the target session, starts a dead program again and selects it, making a
# window only when there is none.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
PING=$(cygpath -w "$SYSTEMROOT/System32/PING.EXE")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
OUT=$(mktemp)
RUNS=$(mktemp)
WRUNS=$(cygpath -w "$RUNS")
CTL=$(mktemp)
SLEEPER=$(mktemp)
FAIL=0
cleanup() {
	$TMUX kill-server 2>/dev/null
	[ -s $SLEEPER ] && kill "$(cat $SLEEPER)" 2>/dev/null
	rm -f $CFG $OUT $RUNS $CTL $SLEEPER
}
trap cleanup 0 1 15

TFAIL=0
fail() {
	echo "FAIL: $1"
	FAIL=1
	TFAIL=1
}

pass() {
	[ $TFAIL -eq 0 ] && echo "PASS $1"
	TFAIL=0
}

value() { $TMUX display -p -t "$1" "$2" 2>/dev/null | tr -d '\r'; }
pane_dead() { [ "$(value "$1" '#{pane_dead}')" = 1 ]; }
runs() { wc -l <$RUNS | tr -d ' '; }
# Windows marked for app $1, in every session.
marked() {
	$TMUX lsw -a -F "#{?#{@$1-window},#{session_name},}" | tr -d '\r' |
	    grep -c .
}

$TMUX -f$CFG new -d -s w -n home -x 80 -y 24 </dev/null || exit 1
$TMUX new -d -s sys -n first -x 80 -y 24 </dev/null || exit 1

# --- Test 1: -M with no window makes one, named for the app and marked; with
# relaunch, a program that ends stays with its line. ---
$TMUX new-window -M app -d -t w: -o remain-on-exit=relaunch \
    "$CMDEXE" //c "echo run>>$WRUNS& echo up& exit 3" >$OUT 2>&1 ||
    fail "1: $(cat $OUT)"
wait_until pane_dead w:app || fail "1: the pane didn't stay, dead"
[ "$(value w:app '#{@app-window}')" = 1 ] || fail "1: no mark"
wait_for w:app '^app stopped (exit 3)\. Press Enter to relaunch\.$' ||
    fail "1: no relaunch line: $($TMUX capture-pane -p -t w:app | tr -d '\r')"
# The relaunch line goes on a new last line, which can scroll the first line
# of output into the history.
$TMUX capture-pane -p -S - -t w:app | tr -d '\r' | grep -q '^up' ||
    fail "1: the program's output went"
[ "$(runs)" = 1 ] || fail "1: ran $(runs) times"
pass "1: made, marked, kept on exit"

# --- Test 2: a key other than Enter does nothing; Enter starts the program
# again, in the same pane. ---
PANE=$(value w:app '#{pane_id}')
$TMUX send-keys -t w:app x
$TMUX send-keys -t w:app Space
[ "$(runs)" = 1 ] || fail "2: another key relaunched it"
$TMUX send-keys -t w:app Enter
wait_until test "$(runs)" = 2 || fail "2: Enter didn't relaunch it"
wait_until pane_dead w:app || fail "2: not dead again"
wait_for w:app '^app stopped (exit 3)' || fail "2: no line after the relaunch"
[ "$(value w:app '#{pane_id}')" = "$PANE" ] || fail "2: a new pane"
pass "2: Enter relaunches, nothing else does"

# --- Test 3: a program that exits 0 stays too. Another app's window running
# the same program isn't taken. ---
$TMUX new-window -M quiet -d -t w: -o remain-on-exit=relaunch \
    "$CMDEXE" //c "exit 0" >$OUT 2>&1 || fail "3: $(cat $OUT)"
wait_for w:quiet '^quiet stopped (exit 0)\. Press Enter to relaunch\.$' ||
    fail "3: a clean exit closed it or showed no line"
[ "$(value w:app '#{@quiet-window}')" = "" ] || fail "3: took app's window"
[ "$(runs)" = 2 ] || fail "3: app was relaunched"
pass "3: a clean exit keeps the window"

# --- Test 4: -M from another session moves the dead window there, starts it
# again and makes no second window. ---
ID=$(value w:app '#{window_id}')
$TMUX new-window -M app -d -t sys: -o remain-on-exit=relaunch \
    "$CMDEXE" //c "echo run>>$WRUNS& echo up& exit 3" >$OUT 2>&1 ||
    fail "4: $(cat $OUT)"
[ "$(value sys:app '#{window_id}')" = "$ID" ] || fail "4: not the same window"
[ "$(marked app)" = 1 ] || fail "4: $(marked app) windows marked"
$TMUX lsw -t w -F '#{window_id}' | tr -d '\r' | grep -qx "$ID" &&
    fail "4: still in w"
wait_until test "$(runs)" = 3 || fail "4: not relaunched"
pass "4: moved into the target session and relaunched"

# --- Test 5: a live app's window moves and keeps running: no restart. ---
$TMUX new-window -M pinger -d -t w: "$PING" -n 300 127.0.0.1 >$OUT 2>&1 ||
    fail "5: $(cat $OUT)"
PID=$(value w:pinger '#{pane_pid}')
$TMUX new-window -M pinger -d -t sys: "$PING" -n 300 127.0.0.1 >$OUT 2>&1 ||
    fail "5: $(cat $OUT)"
[ "$(value sys:pinger '#{pane_pid}')" = "$PID" ] || fail "5: restarted"
[ "$(marked pinger)" = 1 ] || fail "5: $(marked pinger) windows"
pass "5: a running app is moved, not restarted"
$TMUX kill-window -t sys:pinger

# --- Test 6: a window with no mark whose only pane was started as the same
# command is taken and marked; one where the program runs under a shell is
# not, nor one with other arguments. ---
$TMUX new-window -d -t w: -n loose "$PING" -n 300 127.0.0.1 || fail "6: loose"
$TMUX new-window -d -t w: -n shell "$CMDEXE" //k "$PING" -n 300 127.0.0.1 ||
    fail "6: shell"
$TMUX new-window -d -t w: -n other "$PING" -n 299 127.0.0.1 || fail "6: other"
LOOSE=$(value w:loose '#{window_id}')
$TMUX new-window -M ping -d -t sys: "$PING" -n 300 127.0.0.1 >$OUT 2>&1 ||
    fail "6: $(cat $OUT)"
[ "$(value sys:loose '#{window_id}')" = "$LOOSE" ] ||
    fail "6: the program's window wasn't taken"
[ "$(value sys:loose '#{@ping-window}')" = 1 ] || fail "6: not marked"
value w:shell '#{window_id}' | grep -q . || fail "6: the shell's window moved"
value w:other '#{window_id}' | grep -q . ||
    fail "6: a window with other arguments moved"
[ "$(marked ping)" = 1 ] || fail "6: $(marked ping) windows"
pass "6: a lone program's window is taken, a shell's is not"
$TMUX kill-window -t sys:loose
$TMUX kill-window -t w:shell
$TMUX kill-window -t w:other

# --- Test 7: without -d the window is selected; a bad name is refused and
# makes nothing. ---
$TMUX new-window -M app -t sys: "$CMDEXE" //c "exit 3" >$OUT 2>&1 ||
    true
[ "$(value sys: '#{window_name}')" = app ] || fail "7: not selected"
BEFORE=$($TMUX lsw -a | wc -l)
for bad in "" a=b a:b "a b" a.b; do
	if $TMUX new-window -M "$bad" -d "$CMDEXE" //c "exit 0" >$OUT 2>&1; then
		fail "7: -M '$bad' was taken"
	fi
done
[ "$($TMUX lsw -a | wc -l)" = "$BEFORE" ] || fail "7: a bad name made a window"
pass "7: selected, and bad names refused"

# --- Test 8: with -W, a relaunched app switches the client once it has drawn;
# one already running switches it at once. ---
(sleep 300 >/dev/null 2>&1 & echo $! >$SLEEPER; wait) |
    $TMUX -C attach -t w >$CTL 2>&1 &
wait_until has_clients $TMUX || { fail "8: no client"; exit 1; }
C=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
wait_until pane_dead sys:app || fail "8: app not dead"
N=$(runs)
$TMUX new-window -M app -t sys: -W "$C" "$CMDEXE" //c "exit 3" >$OUT 2>&1 ||
    fail "8: $(cat $OUT)"
[ "$(runs)" -gt "$N" ] || fail "8: not relaunched"
[ "$($TMUX list-clients -F '#{session_name}:#{window_name}' | tr -d '\r')" = sys:app ] ||
    fail "8: client not switched"
$TMUX switch-client -c "$C" -t w
$TMUX new-window -M pinger -d -t sys: "$PING" -n 300 127.0.0.1 >$OUT 2>&1 ||
    fail "8: pinger"
$TMUX new-window -M pinger -t sys: -W "$C" "$PING" -n 300 127.0.0.1 >$OUT 2>&1 ||
    fail "8: $(cat $OUT)"
[ "$($TMUX list-clients -F '#{session_name}:#{window_name}' | tr -d '\r')" = sys:pinger ] ||
    fail "8: client not switched to a running app"
pass "8: -W switches to the app"

exit $FAIL
