#!/bin/sh

# A footer reserves its own row without moving the top bars, and survives pane
# output, prompts, resizing, hidden bars and a server upgrade.
PATH=/bin:/usr/bin
TERM=screen
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status on
set -g status-session-bar off
set -g status-format[0] 'TOP_BAR'
set -g status-footer '#[range=user|links]BOTTOM_#{pane_id}#[norange]'
set -g mouse on
bind -n MouseDown1Footer set -gF @footer-click '#{mouse_status_range}'
EOF
$TMUX -f "$OUT/test.conf" new -d -s footer -x 80 -y 24 </dev/null || exit 1
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF
$OUTER -f "$OUT/outer.conf" new -d -x 80 -y 24 </dev/null || exit 1
wait_ready footer || exit 1
$OUTER send-keys "set TMUX=" Enter "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach -t footer" Enter
drawn() { $OUTER capture-pane -p | tr -d '\r' | grep -q "$1"; }
wait_until drawn BOTTOM_ || { $OUTER capture-pane -p; exit 1; }
check_rows() {
    [ "$($OUTER capture-pane -p | tr -d '\r' | head -1 | sed 's/ *$//')" = TOP_BAR ] &&
    [ "$($OUTER capture-pane -p | tr -d '\r' | tail -1 | sed 's/ *$//')" = BOTTOM_%0 ]
}
wait_until check_rows || { echo 'bars are not at opposite edges'; exit 1; }
[ "$($TMUX display -p '#{pane_height}' | tr -d '\r')" = 22 ] || exit 1
# Conditional visibility returns the row when switching windows and panes.
$TMUX set -g status-footer-condition '#{@show-footer}'
full_height() { [ "$($TMUX display -p '#{pane_height}' | tr -d '\r')" = 23 ] && ! drawn BOTTOM_; }
wait_until full_height || { echo 'hidden footer still reserves a row'; exit 1; }
$TMUX set -p @show-footer 1
wait_until check_rows || exit 1
$TMUX new-window -d -n app
$TMUX select-window -t footer:app
wait_until full_height || exit 1
$TMUX select-window -t footer:0
wait_until check_rows || exit 1
split=$($TMUX split-window -h -d -P -F '#{pane_id}' | tr -d '\r')
$TMUX select-pane -t "$split"
wait_until full_height || { echo 'selecting a plain pane kept the footer'; exit 1; }
$TMUX select-pane -t %0
wait_until check_rows || exit 1
$TMUX kill-pane -t "$split"
$TMUX kill-window -t footer:app
# Mouse stays separate from the pre-existing status bindings.
$OUTER send-keys -H 1b 5b 3c 30 3b 32 3b 32 34 4d 1b 5b 3c 30 3b 32 3b 32 34 6d
clicked() { [ "$($TMUX show -gqv @footer-click | tr -d '\r')" = links ]; }
wait_until clicked || { echo 'footer click did not resolve its range'; $TMUX show -gqv @footer-click; $TMUX list-keys -T root MouseDown1Footer; exit 1; }
$TMUX send-keys 'for /L %i in (1,1,35) do @echo SCROLL_%i' Enter
wait_until drawn SCROLL_35 || exit 1
check_rows || exit 1
$TMUX command-prompt -p PROMPT_TEST 'set -g @prompt-result %%' &
prompt_pid=$!
wait_until drawn PROMPT_TEST || exit 1
drawn BOTTOM_ || exit 1
$TMUX send-keys -K Escape
wait "$prompt_pid"
$OUTER resize-window -x 60 -y 18
small() { [ "$($TMUX display -p '#{pane_height}' | tr -d '\r')" = 16 ]; }
wait_until small || exit 1
$TMUX set -g status off
hidden() { [ "$($TMUX display -p '#{pane_height}' | tr -d '\r')" = 17 ]; }
wait_until hidden || exit 1
wait_until drawn BOTTOM_ || exit 1
old=$($TMUX display -p '#{pid}' | tr -d '\r')
panes=$($TMUX list-panes -a -F '#{pane_id}|#{pane_pid}')
$TMUX upgrade-server "$(cygpath -w "$TEST_TMUX")" || exit 1
upgraded() { [ "$($TMUX display -p '#{pid}' | tr -d '\r')" != "$old" ]; }
wait_until upgraded || exit 1
[ "$panes" = "$($TMUX list-panes -a -F '#{pane_id}|#{pane_pid}')" ] || exit 1
wait_until drawn BOTTOM_ || exit 1
$TMUX set -g status-footer ''
removed() { [ "$($TMUX display -p '#{pane_height}' | tr -d '\r')" = 18 ]; }
wait_until removed || exit 1
echo 'ALL FOOTER TESTS PASSED'
