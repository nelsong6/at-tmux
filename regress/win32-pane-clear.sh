#!/bin/sh

# A pane clearing its screen must preserve its neighbours and native borders.
# The Windows client's console consumes DECSLRM, so a margin-based scroll clear
# used to erase full terminal rows instead of the requested pane rectangle.
PATH=/bin:/usr/bin
TERM=screen
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
cat >"$OUT/clear.ps1" <<'EOF'
param([string]$Signal, [string]$Label)
$esc = [char]27
[Console]::Write("$esc[H$esc[2J$Label")
while (-not (Test-Path -LiteralPath $Signal)) { Start-Sleep -Milliseconds 25 }
[Console]::Write("$esc[H$esc[2J$Label-2")
while ($true) { Start-Sleep -Seconds 1 }
EOF
cat >"$OUT/tmux.conf" <<EOF
set -g status off
set -gw pane-border-lines double
set -s terminal-features[90] 'xterm-256color:margins'
set -s terminal-features[91] 'screen:margins'
set -s terminal-features[92] 'tmux-256color:margins'
EOF
SCRIPT=$(cygpath -ma "$OUT/clear.ps1")
LEFT=$(cygpath -ma "$OUT/left")
RIGHT=$(cygpath -ma "$OUT/right")
OWNER=$($TMUX -f "$OUT/tmux.conf" new -d -x60 -y12 -P -F '#{pane_id}' \
    "$PS" -NoProfile -File "$SCRIPT" "$LEFT" LEFT </dev/null | tr -d '\r') || exit 1
OTHER=$($TMUX split-window -d -h -l29 -P -F '#{pane_id}' \
    "$PS" -NoProfile -File "$SCRIPT" "$RIGHT" RIGHT | tr -d '\r') || exit 1
$OUTER -f "$OUT/tmux.conf" new -d -x60 -y12 \
    "$(cygpath -ma "$TEST_TMUX")" -L"$TEST_SOCKET" attach </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || { echo 'client never attached'; exit 1; }
initial() {
    $OUTER capture-pane -p 2>/dev/null | head -1 | tr -d '\r' | \
        grep -q 'LEFT.*║RIGHT'
}
wait_until initial || { echo 'initial panes or border not drawn'; $OUTER capture-pane -p; exit 1; }
touch "$OUT/left"
left_cleared() {
    $TMUX capture-pane -p -t "$OWNER" 2>/dev/null | head -1 | tr -d '\r' | grep -q '^LEFT-2'
}
wait_until left_cleared || { echo 'left fixture did not clear'; exit 1; }
left_preserved() {
    $OUTER capture-pane -p 2>/dev/null | head -1 | tr -d '\r' | \
        grep -q 'LEFT-2.*║RIGHT'
}
wait_until left_preserved || { echo 'left clear erased neighbour or border'; $OUTER capture-pane -p; exit 1; }
touch "$OUT/right"
right_cleared() {
    $TMUX capture-pane -p -t "$OTHER" 2>/dev/null | head -1 | tr -d '\r' | grep -q '^RIGHT-2'
}
wait_until right_cleared || { echo 'right fixture did not clear'; exit 1; }
both_preserved() {
    $OUTER capture-pane -p 2>/dev/null | head -1 | tr -d '\r' | \
        grep -q 'LEFT-2.*║RIGHT-2'
}
wait_until both_preserved || { echo 'right clear erased neighbour or border'; $OUTER capture-pane -p; exit 1; }
echo 'ALL PANE CLEAR TESTS PASSED'
