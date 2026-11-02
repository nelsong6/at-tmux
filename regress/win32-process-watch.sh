#!/bin/sh

# The server sees every child it starts exit, however many it has started and
# however many run at once (TMUX-54). Before the fix it watched them in a table
# of 64: an exited child's entry came back only when it was the newest, so a
# server that had run enough overlapping jobs stopped seeing exits, and with 64
# running at once it spun a core and saw none again. A popup, run-shell job or
# pane then stayed open after its program had gone.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-process-watch"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

trap "$TMUX kill-server 2>/dev/null" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX show-messages -J 2>&1 | tr -d '\r' | head -5
	exit 1
}

# Jobs the server still counts as running.
jobs_left() {
	$TMUX show-messages -J 2>/dev/null | tr -d '\r' | grep -c '^Job'
}

no_jobs() {
	[ "$(jobs_left)" = 0 ]
}

# A job run in the foreground returns.
run_returns() {
	out=$($TMUX run-shell 'echo watched' 2>&1 | tr -d '\r') &&
	    [ "$out" = watched ]
}

$TMUX -fNUL new -d </dev/null || fail "new-session"

# A job that runs for about N-1 seconds; cmd finds ping by its full path, as
# PATH here is /bin:/usr/bin.
PING='%SystemRoot%\System32\ping.exe 127.0.0.1 >NUL -n'

# 1. Seventy jobs running at once (more than one wait call can hold) are each
# seen to exit.
i=0
while [ $i -lt 70 ]; do
	$TMUX run-shell -b "$PING 4" || fail "run-shell -b $i"
	i=$((i + 1))
done
[ "$(jobs_left)" -ge 60 ] || fail "only $(jobs_left) of 70 jobs running at once"
WAIT_TIMEOUT=30 wait_until no_jobs || fail "$(jobs_left) of 70 jobs never seen to exit"
run_returns || fail "run-shell after 70 jobs"

# 2. Overlapping jobs that end oldest first, the order that used up the old
# table, a round at a time until far more than 64 have ended.
round=0
while [ $round -lt 5 ]; do
	i=0
	while [ $i -lt 20 ]; do
		$TMUX run-shell -b "$PING 2" ||
		    fail "run-shell -b, round $round"
		i=$((i + 1))
	done
	$TMUX run-shell -b "$PING 4" || fail "long job, round $round"
	WAIT_TIMEOUT=20 wait_until no_jobs ||
	    fail "$(jobs_left) jobs never seen to exit in round $round"
	round=$((round + 1))
done

# A program that keeps running holds a watch of its own, and what starts after
# it is still seen to exit: a job and a pane.
$TMUX new-window -d -n long cmd.exe //c "$PING 600" || fail "long window"
run_returns || fail "run-shell beside a long-running window"
$TMUX new-window -d -n brief cmd.exe //c exit 0 || fail "brief window"
brief_gone() {
	! $TMUX list-windows -F '#{window_name}' | tr -d '\r' | grep -qx brief
}
wait_until brief_gone || fail "a pane whose program exited is still open"
$TMUX list-windows -F '#{window_name}' | tr -d '\r' | grep -qx long ||
    fail "the long-running window ended early"

$TMUX kill-server 2>/dev/null

echo "ALL PROCESS WATCH TESTS PASSED"
exit 0
