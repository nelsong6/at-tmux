#!/bin/sh
# A redraw under an open side panel paints nothing in the panel's columns but the panel:
# the window's "outside" fill there flashed as a column of dots before the panel covered
# it. Read from what the client really sent to its terminal, tmux's -vv output log.
PATH=/bin:/usr/bin
TERM=screen
export TERM
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
case "$(uname -s)" in
 MINGW*|MSYS*) . "$(dirname "$0")/win32-test.sh"; EXE=$(cygpath -ma "$TEST_TMUX"); PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe" ;;
 *) TEST_SOCKET="panel-fill-$$"; EXE="$TEST_TMUX"; PS=/bin/sh ;;
esac
TEST_TMUX=$(cd "$(dirname "$TEST_TMUX")" && pwd)/$(basename "$TEST_TMUX")
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d)
# The server's own logs stay open until it has gone.
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1
cat >test.conf <<EOF
set -g default-shell "$PS"
set -g status off
set -g pane-border-lines single
EOF
cat >outer.conf <<EOF
set -g default-shell "$PS"
set -g status off
EOF
$TMUX -vv -f test.conf new -d -x120 -y28 -s panel || exit 1
$OUTER -f outer.conf new -d -x120 -y28 "$EXE" "-L$TEST_SOCKET" attach-session || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || { echo 'no attached client'; exit 1; }
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
SOURCE=$($TMUX display -p '#{pane_id}' | tr -d '\r')
width_is() { [ "$($TMUX display -p '#{pane_width}' | tr -d '\r')" = "$1" ]; }
contains() { $OUTER capture-pane -p | tr -d '\r' | grep -q "$1"; }
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Links -g first -- -PANEL-CONTENT '' '' || exit 1
wait_until width_is 80 || { echo 'panel did not reserve 40 columns'; exit 1; }
wait_until contains PANEL-CONTENT || { echo 'panel not drawn'; exit 1; }
LOG=$(ls tmux-out-*.log 2>/dev/null | head -1)
[ -n "$LOG" ] || { echo 'no output log'; exit 1; }
before=$(wc -c <"$LOG")
# Changing the border style redraws the borders. The panel draws after them, so its
# new text in the log means the borders of that frame are there too.
$TMUX set -g pane-border-style fg=blue
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Links -g first -u -- -AFTER-REDRAW '' ''
redrawn() { tail -c +"$((before + 1))" "$LOG" | grep -a -q AFTER-REDRAW; }
wait_until redrawn || { echo 'the redraw never reached the terminal'; exit 1; }
tail -c +"$((before + 1))" "$LOG" >redraw.txt
fill=$(tr -cd '~' <redraw.txt | wc -c)
dots=$(grep -a -o "$(printf '\302\267')" redraw.txt | wc -l)
[ "$fill" -eq 0 ] && [ "$dots" -eq 0 ] ||
 { echo "the redraw painted the outside fill under the panel: $fill ~, $dots dots"; exit 1; }
echo 'ALL PANEL FILL TESTS PASSED'
