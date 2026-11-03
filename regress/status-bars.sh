# Shared palette checks: named controls hide either status bar or both,
# resize the pane, and leave other sessions alone. Sourced by palette.sh
# and win32-palette.sh with their real attached client and test picker.

bar_session=$($TMUX display -p -c "$CLIENT" '#{client_session}' | tr -d '\r')
bar_height=$($TMUX display -p -c "$CLIENT" '#{client_height}' | tr -d '\r')
$TMUX new -d -s bars-other </dev/null || exit 1
bar_height_is() {
	[ "$($TMUX display -p -t "=$bar_session:" '#{pane_height}' | tr -d '\r')" = \
	    "$((bar_height - $1))" ]
}
bars_are() {
	wait_until bar_height_is "$1" ||
	    { echo "expected $1 status rows after $2"; exit 1; }
	[ "$($TMUX show -Av -t bars-other status | tr -d '\r')" = off ] ||
	    { echo "$2 changed another session"; exit 1; }
}

palette pick=toggle-status-bars
for command in toggle-status-bars toggle-window-bar toggle-session-bar; do
	row "^0	$command	[^	]*		[0-9]*	" ||
	    fail_row "no directly selectable $command row" "$command"
done
bars_are 2 toggle-status-bars
palette pick=toggle-session-bar
bars_are 1 toggle-session-bar
palette pick=toggle-window-bar
bars_are 0 toggle-window-bar
palette pick=toggle-session-bar
bars_are 1 toggle-session-bar
palette pick=toggle-window-bar
bars_are 2 toggle-window-bar
palette pick=toggle-status-bars
bars_are 0 toggle-status-bars

# Starting from status off, an individual command shows only its own bar.
palette pick=toggle-window-bar
bars_are 1 toggle-window-bar
[ "$($TMUX show -v -t "=$bar_session:" status-session-bar | tr -d '\r')" = off ] || exit 1
palette pick=toggle-status-bars
bars_are 0 toggle-status-bars
palette pick=toggle-session-bar
bars_are 1 toggle-session-bar
[ "$($TMUX show -v -t "=$bar_session:" status-window-bar | tr -d '\r')" = off ] || exit 1
palette pick=toggle-status-bars
bars_are 0 toggle-status-bars
palette pick=toggle-status-bars
bars_are 2 toggle-status-bars
palette pick=toggle-status-bars status=130
bars_are 2 cancelled-toggle

# Custom multiline status formats retain their requested number of rows.
$TMUX set -t "=$bar_session:" status-window-bar off
$TMUX set -t "=$bar_session:" status-session-bar off
$TMUX set -t "=$bar_session:" status 2
bars_are 2 custom-status
$TMUX set -t "=$bar_session:" status on
bars_are 0 hidden-individual-bars
palette pick=toggle-status-bars
bars_are 2 toggle-status-bars

# The session bar comes and goes as sessions are created and destroyed,
# including when it is the only enabled row.
$TMUX kill-session -t bars-other || exit 1
wait_until bar_height_is 1 || { echo "single session kept its session bar"; exit 1; }
palette pick=toggle-window-bar
wait_until bar_height_is 0 || exit 1
$TMUX new -d -s bars-other </dev/null || exit 1
bars_are 1 new-session
$TMUX kill-session -t bars-other || exit 1
wait_until bar_height_is 0 ||
    { echo "session-only bar stayed after session ended"; exit 1; }
palette pick=toggle-status-bars
wait_until bar_height_is 1 || exit 1
palette pick=toggle-status-bars
wait_until bar_height_is 0 || exit 1
