#!/bin/sh

# Exercise the named-key protocol across builds whose key numbers differ,
# including the signed pre-footer build's version-1 numeric state.
PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
[ -n "$TEST_TMUX" ] && [ -n "$TEST_LEGACY_TMUX" ] || exit 1
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
printf "set -g default-shell '%s'\nset -g mouse on\nset -g status off\n" "$COMSPEC" >"$OUT/test.conf"
printf "bind -T custom -r -N 'unicode binding' M-é display -p UNICODE\n" >>"$OUT/test.conf"

server_pid() { $TMUX display -p '#{pid}' | tr -d '\r'; }
changed() { [ "$(server_pid)" != "$before_pid" ]; }

check_upgrade() {
    source_exe=$1
    target_exe=$2
    SOURCE="$source_exe -L$TEST_SOCKET"
    $SOURCE -f "$OUT/test.conf" new -d -s keys </dev/null || exit 1
    $SOURCE set -g prefix F2 || exit 1
    $SOURCE bind -T custom C-MouseDrag1Pane display -p CUSTOM_DRAG || exit 1
    $SOURCE bind -T custom F12 display -p CUSTOM_F12 || exit 1
    if [ "$source_exe" != "$TEST_LEGACY_TMUX" ]; then
        $SOURCE bind -T custom MouseMoveFooter display -p FOOTER_MOVE || exit 1
        $SOURCE bind -T custom C-MouseMovePane display -p PANE_MOVE || exit 1
    fi
    $SOURCE unbind -T root DoubleClick1Pane || exit 1
    $SOURCE list-keys | tr -d '\r' >"$OUT/before"
    before_pid=$(server_pid)
    pane_pid=$($SOURCE display -p '#{pane_pid}' | tr -d '\r')
    $SOURCE upgrade-server "$(cygpath -w "$target_exe")" || exit 1
    wait_until changed || { $TMUX display -p '#{server_upgrade}'; exit 1; }
    $TMUX list-keys | tr -d '\r' >"$OUT/after"
    if [ "$source_exe" = "$TEST_LEGACY_TMUX" ]; then
        # The pre-footer build's kill defaults, never rebound, come as this
        # build's close defaults (TMUX-207); win32-upgrade-defaults.sh
        # covers that.
        changed='^bind-key +-T (prefix +[&x<>]|root +(M-)?MouseDown3(Status|Pane)) '
        grep -Ev "$changed" "$OUT/before" >"$OUT/before.kept"
        grep -Ev "$changed" "$OUT/after" >"$OUT/after.kept"
        diff -u "$OUT/before.kept" "$OUT/after.kept" || exit 1
    else
        diff -u "$OUT/before" "$OUT/after" || exit 1
    fi
    [ "$($TMUX show -gv prefix | tr -d '\r')" = F2 ] || exit 1
    $TMUX list-keys -N -T custom | grep -q 'unicode binding' || exit 1
    [ "$($TMUX display -p '#{pane_pid}' | tr -d '\r')" = "$pane_pid" ] || exit 1
    $TMUX list-keys -T root MouseDrag1Pane | grep -q 'copy-mode -M' || exit 1
    $TMUX kill-server
}

check_upgrade "$TEST_LEGACY_TMUX" "$TEST_TMUX"
echo 'PASS: pre-footer upgrade preserves every binding, modifiers, notes, Unicode, unbinds, prefix and pane'

if [ -n "$TEST_SHIFTED_TMUX" ]; then
    check_upgrade "$TEST_LEGACY_TMUX" "$TEST_SHIFTED_TMUX"
    check_upgrade "$TEST_TMUX" "$TEST_SHIFTED_TMUX"
    check_upgrade "$TEST_SHIFTED_TMUX" "$TEST_TMUX"
    echo 'PASS: named keys survive changed numeric IDs in both directions'
fi

$TMUX -f "$OUT/test.conf" new -d -s incompatible || exit 1
before_pid=$(server_pid)
pane_pid=$($TMUX display -p '#{pane_pid}' | tr -d '\r')
$TMUX upgrade-server "$(cygpath -w "$TEST_LEGACY_TMUX")" || exit 1
refused() { $TMUX display -p '#{server_upgrade}' | grep -q '^failed'; }
wait_until refused || exit 1
[ "$(server_pid)" = "$before_pid" ] || exit 1
[ "$($TMUX display -p '#{pane_pid}' | tr -d '\r')" = "$pane_pid" ] || exit 1
$TMUX list-keys -T root MouseDrag1Pane | grep -q 'copy-mode -M' || exit 1
$TMUX kill-server
echo 'PASS: an incompatible old reader leaves the original server and pane running'

SOURCE="$TEST_LEGACY_TMUX -L$TEST_SOCKET"
$SOURCE -f "$OUT/test.conf" new -d -s drag -x 80 -y 20 || exit 1
wait_ready drag || exit 1
$SOURCE send-keys -t drag cls Enter 'echo DRAG_SELECT_ME' Enter
$OUTER -f "$OUT/test.conf" new -d -s outer -x 80 -y 20 \
    "$(cygpath -w "$TEST_LEGACY_TMUX")" -L "$TEST_SOCKET" attach -t drag || exit 1
drawn() { $OUTER capture-pane -p | grep -q '^DRAG_SELECT_ME'; }
wait_until drawn || { $OUTER capture-pane -p; exit 1; }
before_pid=$(server_pid)
$SOURCE upgrade-server "$(cygpath -w "$TEST_TMUX")" || exit 1
wait_until changed || exit 1
# Normal left-button press, drag and release, through a real nested client.
drag_row=$($OUTER capture-pane -p | tr -d '\r' | awk '/^DRAG_SELECT_ME/ { print NR; exit }')
[ -n "$drag_row" ] || exit 1
$OUTER send-keys -H $(printf '\033[<0;1;%sM\033[<32;6;%sM\033[<0;6;%sm' \
    "$drag_row" "$drag_row" "$drag_row" | od -An -tx1)
copied() { [ "$($TMUX show-buffer 2>/dev/null | tr -d '\r')" = DRAG_ ]; }
wait_until copied || { $TMUX show-buffer; exit 1; }
echo 'PASS: ordinary left-button dragging selects and copies text after the upgrade'
