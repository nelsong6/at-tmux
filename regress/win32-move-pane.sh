#!/bin/sh

# export-pane and split-window -M move a running pane to another server: its
# program keeps running there with the screen it had, takes the new pane's
# size and input, outlives the server it came from, and closes the pane when
# it exits; none of the old server's pane options come with it, and the pane
# left behind is dead and says where it went. A move that can't happen leaves
# the pane where it was, still running (AHT-165, TMUX-228). Needs conpty.dll
# beside the tmux under test, as upgrade-server does.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
SRC="$TMUX"
DST="$TEST_TMUX -L$TEST_SOCKET-dst"
$SRC kill-server 2>/dev/null
$DST kill-server 2>/dev/null

OUT=$(mktemp -d)
trap "rm -rf $OUT; $SRC kill-server 2>/dev/null; $DST kill-server 2>/dev/null" 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

dst_has() {
	$DST capture-pane -t"$1" -p 2>/dev/null | tr -d '\r' | grep -q -- "$2"
}

dst_panes_are() {
	[ "$($DST list-panes -tdst 2>/dev/null | wc -l)" -eq "$1" ]
}

$SRC new -d -ssrc -x 100 -y 30 </dev/null || exit 1
$DST new -d -sdst -x 120 -y 40 </dev/null || exit 1
wait_ready src || { fail "the first server's shell never drew a prompt"; exit 1; }
TMUX="$DST" wait_ready dst || { fail "the second server's shell never drew a prompt"; exit 1; }

$SRC set -p -tsrc @carried yes
$SRC send-keys -tsrc "echo BEFORE_MOVE" Enter
wait_for src "^BEFORE_MOVE" || fail "the shell never ran the first command"
DST_PID=$($DST display -p '#{pid}' | tr -d '\r')
PANE_PID=$($SRC display -p -tsrc '#{pane_pid}' | tr -d '\r')

# A server that isn't there takes nothing, and the pane goes on as it was.
if $SRC export-pane -p 999999 -tsrc "$(cygpath -m "$OUT/none")" 2>/dev/null; then
	fail "export-pane to a process that doesn't exist succeeded"
fi
$SRC send-keys -tsrc "echo STILL_HERE" Enter
wait_for src "^STILL_HERE" || fail "the pane stopped after a move that failed"

# A file that isn't a pane makes no pane.
echo nothing >"$OUT/junk"
if $DST splitw -d -tdst -M "$(cygpath -m "$OUT/junk")" 2>/dev/null; then
	fail "split-window -M took a file that isn't a pane"
fi
dst_panes_are 1 || fail "split-window -M left a pane after failing"

$SRC export-pane -p "$DST_PID" -tsrc "$(cygpath -m "$OUT/pane")" ||
    fail "export-pane failed"
NEW=$($DST splitw -d -v -tdst -M "$(cygpath -m "$OUT/pane")" -P -F '#{pane_id}' |
    tr -d '\r')
[ -n "$NEW" ] || { fail "split-window -M made no pane"; exit 1; }

dst_has "$NEW" "^BEFORE_MOVE" || fail "the moved pane lost its screen"
[ "$($DST display -p -t"$NEW" '#{pane_pid}' | tr -d '\r')" = "$PANE_PID" ] ||
    fail "the moved pane runs another process"
[ -z "$($DST show -p -t"$NEW" -v @carried 2>/dev/null)" ] ||
    fail "the first server's pane options came with the pane"
[ "$($SRC display -p -tsrc '#{pane_dead}' | tr -d '\r')" = 1 ] ||
    fail "the pane left behind isn't dead"
pane_has src "Moved to the tmux server with process $DST_PID" ||
    fail "the pane left behind doesn't say where it went"

$DST send-keys -t"$NEW" "echo AFTER_MOVE" Enter
wait_until dst_has "$NEW" "^AFTER_MOVE" || fail "the moved pane takes no input"

WIDTH=$($DST display -p -t"$NEW" '#{pane_width}' | tr -d '\r')
# The test's PATH reaches the shell, and has no System32.
$DST send-keys -t"$NEW" '%SystemRoot%\System32\mode.com con' Enter
wait_until dst_has "$NEW" "Columns: *$WIDTH\$" ||
    fail "the moved program wasn't resized to its new pane ($WIDTH columns)"

$SRC kill-server
wait_gone
$DST send-keys -t"$NEW" "echo OUTLIVED" Enter
wait_until dst_has "$NEW" "^OUTLIVED" ||
    fail "the moved program stopped with the server it came from"

$DST send-keys -t"$NEW" "exit" Enter
wait_until dst_panes_are 1 || fail "the moved pane stayed after its program exited"

exit $FAIL
