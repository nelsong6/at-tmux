#!/bin/sh
# Client-local, native side panel: real drawing, input, bounds and lifecycle.
PATH=/bin:/usr/bin
TERM=screen
export TERM
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
case "$(uname -s)" in
 MINGW*|MSYS*) . "$(dirname "$0")/win32-test.sh"; EXE=$(cygpath -ma "$TEST_TMUX"); PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe" ;;
 *) TEST_SOCKET="panel-$$"; EXE="$TEST_TMUX"; PS=/bin/sh ;;
esac
PATH="$(cd "$(dirname "$TEST_TMUX")" && pwd):$PATH"
export PATH
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
cat >"$OUT/test.conf" <<EOF
set -g default-shell "$PS"
set -g status off
set -g mouse on
set -g @show-footer 1
set -g pane-footer 'PANEL_FOOTER_#{client_panel_width}_#{client_panel_focused}'
set -g pane-footer-condition '#{==:#{@show-footer},1}'
bind -T panel / set -gF @slash '#{pane_id}'
EOF
cat >"$OUT/outer.conf" <<EOF
set -g default-shell "$PS"
set -g status off
EOF
$TMUX -f "$OUT/test.conf" new -d -x120 -y28 -s panel || exit 1
$OUTER -f "$OUT/outer.conf" new -d -x120 -y28 "$EXE" "-L$TEST_SOCKET" attach-session || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || { echo 'no attached client'; exit 1; }
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
SOURCE=$($TMUX display -p '#{pane_id}' | tr -d '\r')
width_is() { [ "$($TMUX display -p '#{pane_width}' | tr -d '\r')" = "$1" ]; }
contains() { $OUTER capture-pane -p | tr -d '\r' | grep -q "$1"; }
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Links -b4 -g first -- \
 All a 'set -g @tab all' PRs p 'set -g @tab prs' Tickets t 'set -g @tab tickets' History h 'set -g @tab history' \
 -PANEL-CONTENT '' '' 'Choose action' x 'set -g @picked yes' || exit 1
wait_until width_is 80 || { echo 'panel did not reserve 40 columns'; exit 1; }
wait_until contains 'All.*PRs.*Tickets.*History' || { $OUTER capture-pane -p; exit 1; }
wait_until contains PANEL-CONTENT || { echo 'panel not drawn'; exit 1; }
wait_until contains '|PANEL-CONTENT' || { echo 'panel divider is not ASCII'; $OUTER capture-pane -p; exit 1; }
[ "$($TMUX list-panes | wc -l)" -eq 1 ] || { echo 'created a pane'; exit 1; }
$TMUX send-keys -K -c "$CLIENT" t
option_is() { [ "$($TMUX show -gv "$1" | tr -d '\r')" = "$2" ]; }
wait_until option_is @tab tickets || { echo 'tab shortcut failed'; exit 1; }
# Real terminal mouse packets select tabs without desktop input.
$OUTER send-keys -l "$(printf '\033[<0;92;2M\033[<0;92;2m')"
wait_until option_is @tab prs || { echo 'mouse tab failed'; exit 1; }
$TMUX send-keys -K -c "$CLIENT" x
wait_until option_is @picked yes || { echo 'action failed'; exit 1; }
wait_until width_is 80 || exit 1
wait_until contains PANEL_FOOTER_40_1 || { echo 'conditional footer lost panel formats'; exit 1; }
# A key the focused panel doesn't take runs its binding in the panel key table, from
# the source pane, and the footer names / as the panel's prompt while it is bound.
wait_until contains '/ commands' || { echo 'the footer does not name the panel prompt'; $OUTER capture-pane -p; exit 1; }
MSYS2_ARG_CONV_EXCL="*" $TMUX send-keys -K -c "$CLIENT" /
wait_until option_is @slash "$SOURCE" || { echo "the panel key table did not run from the source pane: $($TMUX show -gqv @slash)"; exit 1; }
$TMUX send-keys -K -c "$CLIENT" Tab
focused_is() { [ "$($TMUX display -c "$CLIENT" -p '#{client_panel_focused}' | tr -d '\r')" = "$1" ]; }
wait_until focused_is 0 || exit 1
$TMUX send-keys -K -c "$CLIENT" 'echo PANEL-ALIVE' Enter
pane_contains() { $TMUX capture-pane -p | tr -d '\r' | grep -q PANEL-ALIVE; }
wait_until pane_contains || { echo 'conversation input was swallowed'; exit 1; }
wait_until contains PANEL-CONTENT || { echo 'app output erased panel'; exit 1; }
# Hover and the wheel are not clicks: over a tab, the rows and [x] they leave
# focus, the tab, the actions and the panel as they were.
$TMUX set -g @picked no
$OUTER send-keys -l "$(printf '\033[<35;102;2M\033[<35;85;3M\033[<35;85;4M\033[<35;85;5M\033[<35;85;6M\033[<35;118;1M\033[<65;85;5Mecho HOVER-ALIVE\r')"
hover_typed() { $TMUX capture-pane -p | tr -d '\r' | grep -q HOVER-ALIVE; }
wait_until hover_typed || { echo 'hover took keyboard focus'; exit 1; }
focused_is 0 && option_is @tab prs && option_is @picked no && width_is 80 ||
 { echo "hover acted as a click: focused $($TMUX display -c "$CLIENT" -p '#{client_panel_focused}'), tab $($TMUX show -gv @tab), picked $($TMUX show -gv @picked), width $($TMUX display -p '#{pane_width}')"; exit 1; }
# A row is highlighted only while the mouse is on it: on the row, on plain text, on it
# again, then off the panel. The highlight shows while the panel has focus.
$OUTER send-keys -l "$(printf '\033[<0;85;3M\033[<0;85;3m')"
wait_until focused_is 1 || { echo 'a click on text did not focus the panel'; exit 1; }
highlighted() { $OUTER capture-pane -e -p | tr -d '\r' | grep 'Choose action' | grep -q '43m\|43;'; }
not_highlighted() { ! highlighted; }
$OUTER send-keys -l "$(printf '\033[<35;85;4M')"
wait_until highlighted || { echo 'hover did not highlight the row'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<35;85;3M')"
wait_until not_highlighted || { echo 'the highlight stayed on plain text'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<35;85;4M')"
wait_until highlighted || { echo 'hover did not highlight the row again'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<35;10;4M')"
wait_until not_highlighted || { echo 'the highlight stayed after leaving the panel'; exit 1; }
$TMUX send-keys -K -c "$CLIENT" Tab
wait_until focused_is 0 || { echo 'Tab did not return focus'; exit 1; }
# Dragging the divider sets the width, live, and holds it inside its bounds. Motion with
# no press on the divider moves nothing.
# Each no-move is read once a tab click sent behind it has landed.
$OUTER send-keys -l "$(printf '\033[<32;61;5M\033[<35;61;5M\033[<0;95;2M\033[<0;95;2m')"
wait_until option_is @tab tickets || { echo 'tab click behind the stray drag failed'; exit 1; }
width_is 80 || { echo 'a drag that started off the divider resized the panel'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<0;81;5M\033[<32;71;5M')"
wait_until width_is 70 || { echo 'dragging did not move the divider'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<32;61;5M\033[<0;61;5m')"
wait_until width_is 60 || { echo 'drag did not reach the mouse'; exit 1; }
[ "$($TMUX show -gv panel-width | tr -d '\r')" = 60 ] || { echo 'the drag was not kept'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<35;40;5M\033[<0;70;2M\033[<0;70;2m')"
wait_until option_is @tab prs || { echo 'tab click behind the motion failed'; exit 1; }
width_is 60 || { echo 'motion after the release kept resizing'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<0;61;5M\033[<32;2;5M\033[<0;2;5m')"
wait_until width_is 30 || { echo 'the window lost its least width'; $TMUX display -p '#{pane_width}'; exit 1; }
$OUTER send-keys -l "$(printf '\033[<0;31;5M\033[<32;119;5M\033[<0;119;5m')"
wait_until width_is 96 || { echo 'the panel lost its least width'; $TMUX display -p '#{pane_width}'; exit 1; }
$TMUX set -g panel-width 50
wait_until width_is 70 || { echo 'setting panel-width did not move it'; exit 1; }
$TMUX set -gu panel-width
wait_until width_is 80 || { echo 'unsetting panel-width did not restore it'; exit 1; }
$TMUX send-keys -K -c "$CLIENT" Tab
wait_until focused_is 0 || { echo 'Tab did not return focus after the drags'; exit 1; }
# A delayed refresh must not replace a newly navigated view.
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T New -g second -- -NEW-VIEW '' ''
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Stale -g first -u -- -STALE-VIEW '' ''
wait_until contains NEW-VIEW || exit 1
if contains STALE-VIEW; then echo 'stale update won'; exit 1; fi
# Switching windows hides its panel; returning reserves space again.
$TMUX new-window -n other || exit 1
wait_until width_is 120 || { echo 'panel leaked into another window'; $TMUX list-windows -F '#{window_id}|#{window_name}|#{window_width}|#{window_active}'; exit 1; }
$TMUX select-window -t panel:^
wait_until width_is 80 || exit 1
# A queued navigation cannot replace a newer view or steal conversation focus.
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Wrong -g third -G first -- -STALE-VIEW '' ''
wait_until contains NEW-VIEW || exit 1
$TMUX send-keys -K -c "$CLIENT" Tab
wait_until focused_is 0 || exit 1
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Next -g third -G second -- -NEXT-VIEW '' ''
wait_until contains NEXT-VIEW || exit 1
wait_until focused_is 0 || { echo 'navigation stole conversation focus'; exit 1; }
$TMUX display-panel -c "$CLIENT" -C
wait_until width_is 120 || { echo 'close did not return columns'; exit 1; }
# Generations belong to input order, independently of background command order.
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Navigation -- Next n 'set -gF @navigation "#{panel_action_generation}"'
$TMUX send-keys -K -c "$CLIENT" n
navigation_set() { [ -n "$($TMUX show -gqv @navigation | tr -d '\r')" ]; }
wait_until navigation_set || exit 1
first_navigation=$($TMUX show -gqv @navigation | tr -d '\r')
$TMUX send-keys -K -c "$CLIENT" n
navigation_changed() { [ "$($TMUX show -gqv @navigation | tr -d '\r')" != "$first_navigation" ]; }
wait_until navigation_changed || exit 1
last_navigation=$($TMUX show -gqv @navigation | tr -d '\r')
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Last -g accepted -G "$last_navigation" -- -LATEST-NAVIGATION '' ''
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Old -g rejected -G "$first_navigation" -- -STALE-VIEW '' ''
wait_until contains LATEST-NAVIGATION || exit 1
$TMUX send-keys -K -c "$CLIENT" Escape
wait_until width_is 120 || exit 1
# A queued navigation cannot reopen a closed panel.
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Reopen -g fourth -G third -- -STALE-VIEW '' ''
wait_until width_is 120 || exit 1
# Closing also invalidates the refresh generation.
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Stale -g second -u -- -STALE-VIEW '' ''
wait_until width_is 120 || exit 1
# A long list is scrollable with PageDown; it need not fit in the terminal.
set --
i=1
while [ "$i" -le 70 ]; do set -- "$@" "-SCROLL-ROW-$i" '' '' ''; i=$((i+1)); done
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Scroll -g scroll -N -- Action x "set -g @hidden activated" scroll-action "$@"
$TMUX send-keys -K -c "$CLIENT" x
wait_until option_is @hidden activated || exit 1
$TMUX set -g @hidden untouched
$TMUX send-keys -K -c "$CLIENT" NPage Enter
wait_until option_is @hidden untouched || { echo 'scrolled-away action ran'; exit 1; }
wait_until contains SCROLL-ROW-27 || { echo 'scroll failed'; $OUTER capture-pane -p; exit 1; }
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Refreshed -g scroll -u -N -- Action x "set -g @hidden activated" scroll-action "$@"
wait_until contains SCROLL-ROW-27 || { echo 'refresh reset scroll'; exit 1; }
# Upgrade preserves panel content, scroll and focus along with pane processes.
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
PANES=$($TMUX list-panes -F '#{pane_id}|#{pane_pid}')
$TMUX set -g panel-width 45
$TMUX upgrade-server "$EXE" || exit 1
upgraded() { now=$($TMUX display -p '#{pid}' | tr -d '\r'); [ -n "$now" ] && [ "$now" != "$PID" ]; }
wait_until upgraded || { $TMUX display -p '#{server_upgrade}'; exit 1; }
[ "$($TMUX list-panes -F '#{pane_id}|#{pane_pid}')" = "$PANES" ] || exit 1
wait_until contains SCROLL-ROW-27 || { echo 'upgrade lost panel scroll'; exit 1; }
[ "$($TMUX show -gv panel-width | tr -d '\r')" = 45 ] || { echo 'upgrade lost the panel width'; exit 1; }
# The upgrade kept each row's command name, which display-palette -P lists it by.
here=$(cd "$(dirname "$0")" && pwd)
echo pick=none >"$OUT/pick"
case "$(uname -s)" in
 MINGW*|MSYS*) $TMUX display-palette -P -c "$CLIENT" -w 100% -h 100% "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -m "$here/win32-palette-pick.ps1")" -Dir "$(cygpath -m "$OUT")" ;;
 *) $TMUX display-palette -P -c "$CLIENT" -w 100% -h 100% /bin/sh "$here/palette-pick.sh" "$OUT" ;;
esac
picked() { [ -e "$OUT/done" ]; }
wait_until picked || { echo 'the panel palette never ran after the upgrade'; exit 1; }
grep -q "^0	scroll-action	Action  \[x\]	" "$OUT/rows" || { echo 'upgrade lost the command name'; cat "$OUT/rows"; exit 1; }
$TMUX set -gu panel-width
wait_until width_is 80 || exit 1
$TMUX display-panel -c "$CLIENT" -C
wait_until width_is 120 || exit 1
if [ -n "$TEST_STRIP" ]; then
 mkdir -p "$OUT/state/tmux-strip"
 cat >"$OUT/state/tmux-strip/codex-panel-test.json" <<'EOF'
{"focus":{"team":"Panel provider integration","person":"nelson","ticket":"42"},"tickets":[{"id":"42","key":"TMUX-42","title":"Full Unicode 日本語 title"}],"history":[{"at":1,"text":"Recorded conversation history"}]}
EOF
 state="$OUT/state"
 case "$(uname -s)" in MINGW*|MSYS*) state=$(cygpath -ma "$state");; esac
 $TMUX set-environment -g XDG_STATE_HOME "$state"
 socket=$($TMUX display -p '#{socket_path}' | tr -d '\r')
 XDG_STATE_HOME="$state" "$TEST_STRIP" menu --session panel-test --agent codex --socket "$socket" --client "$CLIENT" --part links || exit 1
 wait_until contains ' Conversation ' || { $OUTER capture-pane -p; exit 1; }
 wait_until contains 'TMUX-42' || exit 1
 $TMUX send-keys -K -c "$CLIENT" h
 wait_until contains 'Recorded conversation history' || { echo 'provider navigation failed'; $OUTER capture-pane -p; exit 1; }
 $TMUX send-keys -K -c "$CLIENT" Escape
 wait_until width_is 120 || exit 1
fi
# Paragraphs reflow to the resized client, retaining text beyond the old edge.
long=$(printf '%0100d' 0)
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Reflow -- "-$long REFLOW-END" '' ''
wait_until contains REFLOW-END || exit 1
$OUTER resize-window -x90 -y24
wait_until width_is 60 || { echo 'resize did not reserve the new width'; exit 1; }
wait_until contains REFLOW-END || { echo 'resize lost paragraph text'; $OUTER capture-pane -p; exit 1; }
# A long row breaks between words, and the lines it wraps onto keep its margin.
words=
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do words="$words WRAP$n"; done
$TMUX display-panel -c "$CLIENT" -t "$SOURCE" -T Wrap -- "-#[fg=red]$words" '' ''
wait_until contains 'WRAP12' || { echo 'wrapped row not drawn'; $OUTER capture-pane -p; exit 1; }
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
 contains "WRAP$n" || { echo "WRAP$n was broken mid-word"; $OUTER capture-pane -p; exit 1; }
done
! contains '|WRAP' || { echo 'a wrapped line lost its margin'; $OUTER capture-pane -p; exit 1; }
$TMUX display-panel -c "$CLIENT" -C
wait_until width_is 90 || exit 1
# The line under a pane with a footer is one line: no cells of it fall outside the
# window's borders, which simple lines draw as periods.
$TMUX set -g pane-border-lines simple
$TMUX splitw -d -v -l 8
border_whole() { $OUTER capture-pane -p | tr -d '\r' | grep -q '^-\{90\}$'; }
wait_until border_whole || { echo 'border under a footer is broken'; $OUTER capture-pane -p; exit 1; }
printf 'ALL PANEL TESTS PASSED\n'
