#!/bin/sh

# The key trace names the step a key stopped at: pressed and never read,
# taken by a menu, or stuck going into a pane whose console stopped reading
# (TMUX-131). A press is recorded with key-trace -p, as the keyboard hook would.
# The client runs in a pane of a second server; keys sent there reach it as
# keys from a terminal.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15

CFG="$OUT/trace.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
EOF

$TMUX -f "$CFG" new -d -x80 -y24 </dev/null || exit 1
$OUTER -f "$CFG" new -d -x80 -y24 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; exit 1; }

trace_has() {
	$TMUX key-trace 2>/dev/null | grep -q "$1"
}
message_has() {
	$TMUX show-messages 2>/dev/null | grep -q "$1"
}

# Pressed, read, and sent to the pane.
$TMUX key-trace -p || exit 1
$OUTER send-keys a
sent_to_pane() { trace_has 'went to pane %0'; }
wait_until sent_to_pane || { echo "key not traced to its pane"; $TMUX key-trace; exit 1; }

# Pressed and never read: told once two have gone unanswered, then cleared.
$TMUX key-trace -p
$TMUX key-trace -p
never_read() { message_has 'are not reaching tmux'; }
wait_until never_read || { echo "unread keys not reported"; $TMUX key-trace; exit 1; }
trace_has 'never read' || { echo "unread key not in the trace"; $TMUX key-trace; exit 1; }
$OUTER send-keys b
reach_again() { message_has 'keys reach tmux again'; }
wait_until reach_again || { echo "recovery not reported"; exit 1; }

# A key a menu takes is shown stopping there.
$TMUX display-menu -x0 -y0 one 1 'display-message picked' &
menu_open() { $OUTER capture-pane -p 2>/dev/null | grep -q one; }
wait_until menu_open || { echo "menu never drew"; exit 1; }
$TMUX key-trace -p
$OUTER send-keys z
to_menu() { trace_has 'went to a menu or popup'; }
wait_until to_menu || { echo "key taken by the menu not traced"; $TMUX key-trace; exit 1; }
$OUTER send-keys Escape

# A pane whose console has stopped reading: more input than the pipe holds
# leaves the write blocked, and that pane is named.
PS="$(cygpath -u "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
CONSOLE=$("$PS" -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"ParentProcessId=$(tr -d '\r' <<EOF
$($TMUX display-message -p '#{pid}')
EOF
)\" | Where-Object Name -match 'OpenConsole|conhost' | Select-Object -First 1 -ExpandProperty ProcessId" | tr -d '\r')
[ -n "$CONSOLE" ] || { echo "no console process found for the pane"; exit 1; }
SUSPEND="$(dirname "$0")/win32-suspend.ps1"
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SUSPEND")" -Id "$CONSOLE" -Suspend
i=0
while [ $i -lt 40 ]; do
	$TMUX send-keys -l "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	i=$((i + 1))
done
$TMUX key-trace -p
$OUTER send-keys c
stuck() { message_has 'keys are stuck going into pane %0'; }
wait_until stuck
RESULT=$?
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SUSPEND")" -Id "$CONSOLE"
[ $RESULT -eq 0 ] || { echo "blocked console not reported"; $TMUX show-messages | tail -5; exit 1; }
moving() { message_has 'keys reach pane %0 again'; }
wait_until moving || { echo "blocked console recovery not reported"; exit 1; }

exit 0
