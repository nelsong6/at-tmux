#!/bin/sh

# A background run-shell started by a command-line client, a config file or a
# hook has nobody watching for it: its output and failed exit go to the message
# log (the failure to the error log too), never into whichever pane is current,
# even with a client attached (TMUX-101). One started by a key press is shown in
# that client's pane, and one with -t in its pane, as before. The client runs in
# a pseudo-console and keys reach it with send-keys -K.

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
export TMUX_ERROR_LOG_DIR=$(cygpath -w "$OUT")
fail() { echo "FAIL: $*"; exit 1; }

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
bind -n F5 run-shell -b "echo tmux101-pressed& exit 5"
run-shell -b "echo tmux101-config& exit 6"
EOF
$TMUX -f "$(cygpath -m "$OUT/test.conf")" new -d -x100 -y30 -s w -n home \
    </dev/null || fail "start server"
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
LOG="$OUT/tmux-$PID.log"

"$PS" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || fail "client never attached"
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
$TMUX split-window -d -t w:home || fail "split"

messages() {
	$TMUX show-messages 2>/dev/null | tr -d '\r'
}
logged() {
	messages | grep -q -- "$1"
}
in_mode() {
	$TMUX list-panes -a -F '#{pane_in_mode}' | tr -d '\r' | grep -q 1
}

# The config's job, started before any client attached.
wait_until logged "returned 6" || fail "config job's exit not in the message log"
logged "'echo tmux101-config& exit 6': tmux101-config" || fail "config job's output not in the message log"

# A command-line client's job, with a client attached: the case that put the
# alerts listener's exit into a pane.
$TMUX run-shell -b "echo tmux101-cli& exit 3" || fail "run-shell -b"
wait_until logged "returned 3" || fail "command-line job's exit not in the message log"
logged "'echo tmux101-cli& exit 3': tmux101-cli" || fail "command-line job's output not in the message log"
grep -q "returned 3" "$LOG" || fail "command-line job's exit not in the error log"
grep -q "tmux101-cli\$" "$LOG" && fail "output line in the error log"
in_mode && fail "a background job's output took over a pane"

# One that succeeds quietly leaves nothing.
$TMUX run-shell -b "exit 0" || fail "run-shell -b quiet"
$TMUX run-shell "exit 0" || fail "run-shell quiet"
logged "'exit 0'" && fail "a quiet job was logged"

# A key press: the pressing client's pane, not the log.
$TMUX send-keys -K -c "$CLIENT" F5 || fail "press F5"
wait_until in_mode || fail "pressed job not shown in the client's pane"
active=$($TMUX display -p -t w:home '#{pane_id}' | tr -d '\r')
[ "$($TMUX display -p -t "$active" '#{pane_in_mode}' | tr -d '\r')" = 1 ] || fail "pressed job shown in another pane"
$TMUX capture-pane -M -p -t "$active" | grep -q "tmux101-pressed" || fail "pressed job's output missing"
logged "returned 5" && fail "pressed job's exit went to the message log"
$TMUX send-keys -t "$active" -X cancel 2>/dev/null || $TMUX copy-mode -q -t "$active"

# -t: that pane, even when it is not the current one.
other=$($TMUX list-panes -t w:home -F '#{pane_id} #{pane_active}' | tr -d '\r' | awk '$2 == 0 { print $1 }')
$TMUX run-shell -b -t "$other" "echo tmux101-target& exit 4" || fail "run-shell -b -t"
target_in_mode() {
	[ "$($TMUX display -p -t "$other" '#{pane_in_mode}' | tr -d '\r')" = 1 ]
}
wait_until target_in_mode || fail "-t job not shown in its pane"
$TMUX capture-pane -M -p -t "$other" | grep -q "returned 4" || fail "-t job's exit missing from its pane"
logged "returned 4" && fail "-t job's exit went to the message log"

echo "PASS: background run-shell output reaches the message log, a pressed key's client pane, or its -t pane"
