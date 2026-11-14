#!/bin/sh

# display-palette (FZT-54): the rows a picker is given, and what its pick runs
# once the popup closes. win32-palette-pick.ps1 stands in for fzt: it saves the
# rows and prints the id of the row each test names. The client runs in a
# pseudo-console, as in Windows Terminal, and keys reach it with send-keys -K.

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

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
PICK="$(cygpath -m "$(dirname "$0")/win32-palette-pick.ps1")"

cat >"$OUT/test.conf" <<EOF
set -g default-shell "$PS"
set -g status off
bind -n F5 display-palette -w 100% -h 100% "$PS" -NoProfile -ExecutionPolicy Bypass -File "$PICK" -Dir "$(cygpath -m "$OUT")"
bind -N 'Rename the window' n command-prompt -I'#W' { rename-window -- '%%' }
bind -N 'Go to a window' W command-prompt -T window-target { select-window -t ':%%' }
bind -n F7 display-palette -b none -w 100% -h 100% "$PS" -NoProfile -ExecutionPolicy Bypass -File "$PICK" -Dir "$(cygpath -m "$OUT")"
bind -T panel / display-palette -P -w 100% -h 100% "$PS" -NoProfile -ExecutionPolicy Bypass -File "$PICK" -Dir "$(cygpath -m "$OUT")"
bind -n M-w display-menu Split s { split-window } '' "#{?#{==:1,0},Never,}" x { kill-server } Last l { last-window }
set -g @go-menu 'display-menu -T go "#{session_name}" g "select-window -t first"'
set -s command-alias[100] 'go-to=run-shell -C "#{E:@go-menu}"'
set -s command-alias-note[100] 'go-to=Go to a window = first'
set -s command-alias-note[101] 'nothing-by-this-name=Never shown'
set -s command-alias-tags[100] 'go-to=jump place,spot'
set -s command-alias-tags[101] 'nothing-by-this-name=nevertag'
set -g @no-menu 'display-menu -T none #{?#{==:1,0},"Never" n "kill-server",}'
set -s command-alias[101] 'go-nowhere=run-shell -C "#{E:@no-menu}"'
set -s command-alias[102] 'clock-mode=display-message clock'
bind -n F6 reorder-session
EOF
$TMUX -f "$(cygpath -m "$OUT/test.conf")" new -d -x100 -y30 -n first \
    </dev/null || exit 1
$TMUX new-window -d -n second || exit 1

"$PS" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
HOST=$!
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; exit 1; }
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')

# palette LINE ...: open the palette with the picker told LINE ... (name=value),
# and wait for the picker to exit.
picker_done() {
	[ -e "$OUT/done" ]
}
palette() {
	rm -f "$OUT/rows" "$OUT/done"
	printf '%s\n' "$@" >"$OUT/pick"
	$TMUX send-keys -K -c "$CLIENT" F5
	wait_until picker_done || { echo "picker never ran ($*)"; exit 1; }
}

window_count() {
	$TMUX list-windows 2>/dev/null | wc -l
}
count_is() {
	[ "$(window_count)" -eq "$1" ]
}
window_name() {
	$TMUX display -p '#{window_name}' 2>/dev/null | tr -d '\r'
}
window_name_is() {
	[ "$(window_name)" = "$1" ]
}
row() {
	tr -d '\r' <"$OUT/rows" | grep -q -- "$1"
}

# A command with no arguments runs as picked.
palette pick=new-window
wait_until count_is 3 || { echo "new-window did not run: $(window_count) windows"; exit 1; }
$TMUX kill-window
wait_until count_is 2 || exit 1
$TMUX select-window -t first

# The rows: a command with its description from the manual, an alias, a
# binding named by its note, a root binding's menu as a folder of the items it
# shows (Never is hidden by its format), and a chooser's sessions and windows.
fail_row() {
	echo "$1"
	tr -d '\r' <"$OUT/rows" | grep -- "$2"
	exit 1
}
row '^0	kill-pane	Destroy the given pane\.		[0-9]*	kill pane window$' ||
    fail_row "no kill-pane row" kill-pane
row '^0	splitp	alias for split-window		' || fail_row "no alias row" splitp
row '^0	Rename the window	command-prompt.*	new-name (now first)	' ||
    fail_row "no prompted binding row" Rename
row '^0	M-w	' || fail_row "no root binding row" M-w
row '^1	Split		' || fail_row "no menu item row" Split
row '^1	Split			[0-9]*	$' || fail_row "a menu item has tags" Split
row '^1	Never	' && fail_row "a hidden menu item was offered" Never
row '^0	choose-tree	' || fail_row "no choose-tree row" choose-tree
row '^2	2: second	1 panes	' || fail_row "no window under a session" second
# An alias that runs a menu through run-shell -C, as send-to-session does: its format
# is expanded and its menu is a folder (building it once crashed the server).
# Its note (command-alias-note) is its description, taken whole after the
# first '='; an alias with none is described by what it runs.
row '^0	go-to	Go to a window = first	' || fail_row "no run-shell -C alias row with its note" go-to
row 'Never shown' && fail_row "a note for no alias was shown" 'Never shown'
# Its tags (command-alias-tags), split at spaces and commas, follow those of
# the commands it runs; tags for no alias go nowhere.
row '^0	go-to	Go to a window = first		[0-9]*	run shell miscellaneous jump place spot$' ||
    fail_row "go-to does not carry its command-alias-tags" go-to
row 'nevertag' && fail_row "tags for no alias were shown" nevertag
row '^1	0		' || fail_row "no item in the run-shell -C menu" "^1	0"
row "^0	go-nowhere	alias for run-shell.*		[0-9]*	run shell miscellaneous\$" ||
    fail_row "no row for a run-shell -C menu with nothing in it" go-nowhere
# An alias that takes a command's name replaces that command's row, as typing
# the name runs the alias.
[ "$(tr -d '\r' <"$OUT/rows" | grep -c '^0	clock-mode	')" = 1 ] &&
    row '^0	clock-mode	alias for display-message clock	' ||
    fail_row "clock-mode is not one alias row" clock-mode

# A folder of windows, for a window prompt and a chooser's windows alike, has
# each window's name in the colour the window bar gives it (its Claude state:
# blue working, amber waiting), as SGR codes, and the current window's name in
# brackets, as the bar does; a window with no state is plain (TMUX-205).
ESC=$(printf '\033')
BLUE="$ESC\[38;2;57;186;230m"
AMBER="$ESC\[38;2;255;180;84m"
OFF="$ESC\[39m"
$TMUX set -w -t :=first @claude working || exit 1
$TMUX set -w -t :=second @claude waiting || exit 1
palette pick=nothing
row '^0	Go to a window	' || fail_row "no window prompt row" 'Go to a window'
row "^1	1	$BLUE\\[first\\]$OFF	" ||
    fail_row "the current window is not blue and in brackets" '^1	1'
row "^1	2	${AMBER}second$OFF	" || fail_row "a waiting window is not amber" '^1	2'
row "^2	1: $BLUE\\[first\\]$OFF	1 panes	" ||
    fail_row "the chooser's current window is not blue and in brackets" first
row "^2	2: ${AMBER}second$OFF	1 panes	" ||
    fail_row "the chooser's waiting window is not amber" second
$TMUX set -wu -t :=first @claude || exit 1
$TMUX set -wu -t :=second @claude || exit 1
palette pick=nothing
row '^1	2	second	' || fail_row "a window with no state is not plain" '^1	2'

# Fixed alternatives are picked without typing an argument. Session picks
# affect both windows here, window picks only the current one, and neither
# changes another session.
status_session=$($TMUX display -p -c "$CLIENT" '#{client_session}' | tr -d '\r')
$TMUX new -d -s status-other </dev/null || exit 1
$TMUX set-session-status -t status-other waiting || exit 1
statuses_are() {
	[ "$($TMUX list-windows -t "$1" -F '#{?@claude,#{@claude},done}' |
	    tr -d '\r' | tr '\n' ' ')" = "$2 " ]
}
for state in working waiting done; do
	palette "pick=$state" under=set-session-status
	row '^0	set-session-status	[^	]*		[0-9]*	' ||
	    fail_row "set-session-status still asks for text" set-session-status
	row "^1	$state			[0-9]*	$" ||
	    fail_row "no $state choice" "$state"
	wait_until statuses_are "$status_session" "$state $state" ||
	    { echo "session choice $state did not set both windows"; exit 1; }
	statuses_are status-other waiting ||
	    { echo "session choice changed another session"; exit 1; }
done
for state in working waiting done; do
	palette "pick=$state" under=set-window-status
	row '^0	set-window-status	[^	]*		[0-9]*	' ||
	    fail_row "set-window-status still asks for text" set-window-status
	wait_until statuses_are "$status_session" "$state done" ||
	    { echo "window choice $state did not set only its window"; exit 1; }
	statuses_are status-other waiting ||
	    { echo "window choice changed another session"; exit 1; }
done
$TMUX kill-session -t status-other || exit 1

. "$(dirname "$0")/status-bars.sh"

# A pick that asks for text runs its template with the text, quotes and
# non-ASCII intact.
palette 'pick=Rename the window' 'text=pal "q" é'
wait_until window_name_is 'pal "q" é' ||
    { echo "rename got: $(window_name)"; exit 1; }

# A command that takes one argument is typed in the picker.
palette pick=rename-window 'text=two words'
wait_until window_name_is 'two words' ||
    { echo "rename-window got: $(window_name)"; exit 1; }

# A choice in a chooser's folder runs on the pressing client.
palette 'pick=2: second' under=choose-tree
wait_until window_name_is second ||
    { echo "choose-tree pick went to: $(window_name)"; exit 1; }

# A menu item runs.
palette pick=Split under=M-w
wait_panes : 2 || { echo "the menu item did not run"; exit 1; }

# A picker that exits non-zero (Escape in fzt) runs nothing.
palette pick=new-window status=130
sleep 0.5
count_is 2 || { echo "a cancelled pick ran"; exit 1; }

# The picker's standard error is the popup's console (FZT-75): with stdin and
# stdout pipes it was an invalid handle, and fzt-automate's C library panics
# without one.
rm -f "$OUT/stderr"
palette pick=nothing stderr=checked
[ -e "$OUT/stderr" ] || { echo "the picker never checked its stderr"; exit 1; }
[ "$(cat "$OUT/stderr")" = console ] ||
    { echo "the picker's stderr is $(cat "$OUT/stderr"), not the console"; exit 1; }

# A picker that fails (not 0, nor 130) leaves the popup open until a key: F5
# goes to the popup, not to a new palette. Then a key closes it, and F5 opens
# the palette again.
palette pick=nothing status=3 stderr=it-failed
sleep 0.5
rm -f "$OUT/done"
$TMUX send-keys -K -c "$CLIENT" F5
sleep 1
[ -e "$OUT/done" ] && { echo "a failed picker's popup closed by itself"; exit 1; }
$TMUX send-keys -K -c "$CLIENT" q
palette pick=nothing

# -b none gives the picker the border's cells: two more each way than the
# default. A border type tmux doesn't know opens nothing.
rm -f "$OUT/size"
palette pick=nothing size=1
framed=$(cat "$OUT/size")
rm -f "$OUT/size" "$OUT/done"
printf '%s
' pick=nothing size=1 >"$OUT/pick"
$TMUX send-keys -K -c "$CLIENT" F7
wait_until picker_done || { echo "picker never ran with -b none"; exit 1; }
bare=$(cat "$OUT/size")
[ "$(echo "$framed" | awk '{print $1 + 2, $2 + 2}')" = "$bare" ] ||
    { echo "-b none gave $bare, the default $framed"; exit 1; }
out=$($TMUX display-palette -b nonsense -c "$CLIENT" cmd 2>&1) &&
    { echo "a bad border type was accepted"; exit 1; }
echo "$out" | grep -q 'popup-border-lines' ||
    { echo "a bad border type said: $out"; exit 1; }

# reorder-session with no place is a folder of the places, and a pick moves
# the session of the tab it runs on; from a key it shows them in a menu
# (TMUX-74: a command-alias of that name had hidden the command).
$TMUX new -d -s later </dev/null || exit 1
here=$($TMUX display -p -c "$CLIENT" '#{client_session}' | tr -d '\r')
srow() { $TMUX display -p '#{S:#{session_name} }' | tr -d '\r' | sed 's/ $//'; }
srow_is() { [ "$(srow)" = "$1" ]; }
srow_is "$here later" || { echo "sessions row is $(srow)"; exit 1; }
palette pick=Back under=reorder-session
row '^0	reorder-session	' || fail_row "no reorder-session row" reorder-session
for place in Front Forward Backward Back; do
	row "^1	$place		" || fail_row "no $place under reorder-session" "^1	"
done
wait_until srow_is "later $here" ||
    { echo "Back under reorder-session left the row $(srow)"; exit 1; }
$TMUX send-keys -K -c "$CLIENT" F6
_tries=20
until srow_is "$here later"; do
	_tries=$((_tries - 1))
	[ $_tries -gt 0 ] ||
	    { echo "Front in reorder-session's menu left the row $(srow)"; exit 1; }
	$TMUX send-keys -K -c "$CLIENT" f 2>/dev/null
	sleep 0.5
done

# display-palette -P (ATC-72): the side panel's actions are the rows, each by
# the command name display-panel -N gave it, described by its text and key once
# (TMUX-206), or by its text when it has none, with the panel's own actions; /
# in the panel key table opens it. A pick runs as the panel would run it, and a
# pick the panel has moved on from runs nothing.
out=$($TMUX display-palette -P -c "$CLIENT" cmd 2>&1) &&
    { echo "-P opened with no panel"; exit 1; }
echo "$out" | grep -q 'no side panel' ||
    { echo "-P with no panel said: $out"; exit 1; }
PANE=$($TMUX display -p -c "$CLIENT" '#{pane_id}' | tr -d '\r')
open_panel() {
	$TMUX display-panel -c "$CLIENT" -t "$PANE" -T Links -b2 -g "$1" -N -- \
	    All a 'set -g @tab all' show-all PRs p 'set -g @tab prs' show-prs \
	    -INFO-ROW '' '' '' \
	    ' Copy URL  #[dim][c]' c 'set -g @copied yes' copy-url \
	    Next n 'set -gF @gen "#{panel_action_generation}"' '' || exit 1
}
# panel_palette LINE ...: press / in the focused panel with the picker told
# LINE ..., and wait for the picker to exit.
panel_palette() {
	rm -f "$OUT/rows" "$OUT/done" "$OUT/release"
	printf '%s\n' "$@" >"$OUT/pick"
	MSYS2_ARG_CONV_EXCL="*" $TMUX send-keys -K -c "$CLIENT" /
	wait_until picker_done || { echo "panel picker never ran ($*)"; exit 1; }
}
option_is() {
	[ "$($TMUX show -gqv "$1" | tr -d '\r')" = "$2" ]
}
focused_is() {
	[ "$($TMUX display -c "$CLIENT" -p '#{client_panel_focused}' | tr -d '\r')" = "$1" ]
}
panel_width_is() {
	[ "$($TMUX display -c "$CLIENT" -p '#{client_panel_width}' | tr -d '\r')" = "$1" ]
}
generation_set() {
	case "$($TMUX show -gqv @gen | tr -d '\r')" in p*) return 0 ;; esac
	return 1
}
open_panel one
wait_until focused_is 1 || { echo "the panel never took the keyboard"; exit 1; }
panel_palette pick=copy-url
wait_until option_is @copied yes || { echo "copy-url did not run"; exit 1; }
row '^0	show-all	All  \[a\]		[0-9]*	$' || fail_row "no All tab row" All
row '^0	copy-url	Copy URL  \[c\]		' ||
    fail_row "copy-url is not described once by its key" Copy
row '^0	Next	\[n\]		' || fail_row "an unnamed row is not named by its text" Next
row '^0	close-panel	Close the panel  \[Escape\]		' || fail_row "no Close row" Close
row '^0	unfocus-panel	Give the keyboard back to the pane  \[Tab\]		' ||
    fail_row "no Tab row" keyboard
row '^0	page-up	' || fail_row "no page-up row" page
row '^0	page-down	' || fail_row "no page-down row" page
row 'INFO-ROW' && fail_row "an informational row was offered" INFO-ROW
row 'kill-pane' && fail_row "-P listed tmux's commands" kill-pane
panel_palette pick=show-prs
wait_until option_is @tab prs || { echo "the PRs tab did not run"; exit 1; }
panel_palette pick=Next
wait_until generation_set ||
    { echo "a pick got no panel_action_generation: $($TMUX show -gqv @gen)"; exit 1; }
# The panel moves to another view while the picker is open: its pick of a row
# that view lacks runs nothing. Mark, picked next, runs after where it would
# have.
$TMUX set -g @copied no
rm -f "$OUT/rows" "$OUT/done" "$OUT/release"
printf '%s\n' pick=copy-url hold=1 >"$OUT/pick"
MSYS2_ARG_CONV_EXCL="*" $TMUX send-keys -K -c "$CLIENT" /
rows_saved() { [ -e "$OUT/rows" ]; }
wait_until rows_saved || { echo "the held picker never got its rows"; exit 1; }
$TMUX display-panel -c "$CLIENT" -t "$PANE" -T Other -g two -- \
    Mark m 'set -g @mark yes' 'Copy elsewhere' c 'set -g @copied wrong' || exit 1
: >"$OUT/release"
wait_until picker_done || { echo "the held picker never finished"; exit 1; }
panel_palette pick=Mark
wait_until option_is @mark yes || { echo "Mark did not run"; exit 1; }
option_is @copied no ||
    { echo "a pick ran on a view that moved on: @copied $($TMUX show -gqv @copied)"; exit 1; }
# The panel's own actions: back to the pane, then close.
open_panel three
wait_until focused_is 1 || exit 1
panel_palette pick=unfocus-panel
wait_until focused_is 0 || { echo "the Tab row kept the keyboard"; exit 1; }
open_panel four
wait_until focused_is 1 || exit 1
panel_palette pick=close-panel
wait_until panel_width_is 0 || { echo "the Escape row left the panel open"; exit 1; }

$TMUX kill-server 2>/dev/null
wait $HOST

echo "ALL PALETTE TESTS PASSED"
exit 0
