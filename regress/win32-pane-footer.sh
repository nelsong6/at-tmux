#!/bin/sh

# A pane footer belongs to its pane: its row comes out of that pane alone, as wide as
# the pane, shown per the pane's condition, with clicks reaching the pane under them,
# and it survives output, resizing, zooming and a server upgrade.
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
set -g status off
set -g pane-footer '#[range=user|links]ROW_#{pane_id}_#{pane_width}#[norange]'
set -g pane-footer-condition '#{@row}'
set -g mouse on
bind -n MouseDown1Footer select-pane -t = \; set -gF @click '#{pane_id} #{mouse_status_range}'
EOF
$TMUX -f "$OUT/test.conf" new -d -s row -x 81 -y 24 </dev/null || exit 1
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF
$OUTER -f "$OUT/outer.conf" new -d -x 81 -y 24 </dev/null || exit 1
wait_ready row || exit 1
$OUTER send-keys "set TMUX=" Enter "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach -t row" Enter
screen() { $OUTER capture-pane -p | tr -d '\r'; }
height() { $TMUX display -p -t "$1" '#{pane_height}' | tr -d '\r'; }
attached() { [ "$($TMUX list-clients | wc -l)" = 1 ]; }
wait_until attached || exit 1

# Off until the pane's condition is true, and no row is taken.
[ "$(height %0)" = 24 ] || { echo 'a pane with no footer lost a row'; exit 1; }
$TMUX set -p -t %0 @row 1
one_row() { [ "$(height %0)" = 23 ] && screen | tail -1 | grep -q '^ROW_%0_81 *$'; }
wait_until one_row || { echo 'footer did not take its row'; screen; exit 1; }

# A split: the row stays under its own pane, and the plain pane keeps its full height.
plain=$($TMUX split-window -h -d -P -F '#{pane_id}' -t %0 | tr -d '\r')
width=$($TMUX display -p -t %0 '#{pane_width}' | tr -d '\r')
split_row() {
    [ "$(height %0)" = 23 ] && [ "$(height "$plain")" = 24 ] &&
    screen | tail -1 | grep -q "^ROW_%0_$width *[│|x]"
}
wait_until split_row || { echo 'footer is not its pane width'; screen; exit 1; }

# Two panes with rows each show their own, whichever has focus.
$TMUX set -p -t "$plain" @row 1
two_rows() {
    [ "$(height "$plain")" = 23 ] &&
    screen | tail -1 | grep -q "ROW_%0_.*ROW_${plain}_"
}
wait_until two_rows || { echo 'each pane does not show its own row'; screen; exit 1; }
$TMUX select-pane -t "$plain"
wait_until two_rows || { echo 'focus moved a row'; exit 1; }

# A click is on the pane under it: it selects that pane and resolves its range.
$OUTER send-keys -H 1b 5b 3c 30 3b 32 3b 32 34 4d 1b 5b 3c 30 3b 32 3b 32 34 6d
clicked() { [ "$($TMUX show -gqv @click | tr -d '\r')" = '%0 links' ]; }
wait_until clicked || { echo 'click did not reach its pane'; $TMUX show -gqv @click; exit 1; }

# A row of pane output doesn't overwrite the footer, and the condition gives it back.
$TMUX send-keys -t %0 'echo OUTPUT' Enter
wait_until two_rows || { echo 'output overwrote the footer'; screen; exit 1; }
$TMUX resize-pane -t %0 -x 30
narrow() { screen | tail -1 | grep -q '^ROW_%0_30 *[│|x]'; }
wait_until narrow || { echo 'footer did not follow the pane width'; screen; exit 1; }
$TMUX resize-pane -Z -t %0
zoomed() { [ "$(height %0)" = 23 ] && screen | tail -1 | grep -q '^ROW_%0_81 *$'; }
wait_until zoomed || { echo 'zoomed pane lost its footer'; screen; exit 1; }
$TMUX resize-pane -Z -t %0
$TMUX set -pu -t "$plain" @row
returned() { [ "$(height "$plain")" = 24 ]; }
wait_until returned || { echo 'row was not given back'; exit 1; }

# refresh-client -S reruns a #() row, which is how the strip is told its data changed.
echo first >"$OUT/row.txt"
$TMUX set -p -t %0 pane-footer "#(cat '$(cygpath -m "$OUT/row.txt")')"
row_is() { screen | tail -1 | grep -q "^$1"; }
wait_until row_is first || { echo 'a #() row did not run'; screen; exit 1; }
echo second >"$OUT/row.txt"
$TMUX refresh-client -S -t "$($TMUX list-clients -F '#{client_name}' | tr -d '\r')"
wait_until row_is second || { echo 'refresh-client -S did not rerun the row'; screen; exit 1; }
$TMUX set -pu -t %0 pane-footer
wait_until row_is ROW_%0_ || { echo 'the row did not go back'; screen; exit 1; }

# A row's job runs when told or when its command changes, not on a redraw (TMUX-112).
{
    echo '@echo run>>"%~dp0runs"'
    echo '@echo JOB_ROW'
} >"$OUT/row.cmd"
runs() { [ "$(wc -l <"$OUT/runs" | tr -d ' ')" = "$1" ]; }
$TMUX set -g status-interval 1
$TMUX set -p -t %0 pane-footer "#(call \"$(cygpath -m "$OUT")/row.cmd\" #{@row-arg})"
wait_until row_is JOB_ROW || { echo 'row job did not draw'; screen; exit 1; }
before=$(wc -l <"$OUT/runs" | tr -d ' ')
for title in one two three; do
    $TMUX select-pane -t %0 -T "$title"
    sleep 1.2
done
runs "$before" || { echo 'a redraw ran the row job again'; exit 1; }
$TMUX refresh-client -S -t "$($TMUX list-clients -F '#{client_name}' | tr -d '\r')"
told() { runs $((before + 1)); }
wait_until told || { echo 'refresh-client -S did not run the row job once'; exit 1; }
$TMUX set -p -t %0 @row-arg changed
changed() { runs $((before + 2)); }
wait_until changed || { echo 'a new command did not run the row job'; exit 1; }
$TMUX set -pu -t %0 pane-footer
wait_until row_is ROW_%0_ || { echo 'the row did not go back'; screen; exit 1; }

# It survives an upgrade: same panes, same rows.
old=$($TMUX display -p '#{pid}' | tr -d '\r')
panes=$($TMUX list-panes -a -F '#{pane_id}|#{pane_pid}')
$TMUX upgrade-server "$(cygpath -w "$TEST_TMUX")" || exit 1
upgraded() { [ "$($TMUX display -p '#{pid}' | tr -d '\r')" != "$old" ]; }
wait_until upgraded || exit 1
[ "$panes" = "$($TMUX list-panes -a -F '#{pane_id}|#{pane_pid}')" ] || exit 1
wait_until row_is ROW_%0_ || { echo 'footer did not survive an upgrade'; screen; exit 1; }
[ "$(height %0)" = 23 ] || { echo 'upgrade changed the pane height'; exit 1; }
echo 'ALL PANE FOOTER TESTS PASSED'
