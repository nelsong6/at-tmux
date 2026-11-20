#!/bin/sh

# Exercise the named-key protocol across builds whose key numbers differ,
# including the signed pre-footer build's version-1 numeric state, and an
# upgrade from the last build with the strip's footer row and native side panel
# (AGT-49), whose keys, options and panel this build no longer has.
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
        $SOURCE bind -T custom C-MouseMovePane display -p PANE_MOVE || exit 1
    fi
    $SOURCE unbind -T root DoubleClick1Pane || exit 1
    $SOURCE list-keys | tr -d '\r' >"$OUT/before"
    before_pid=$(server_pid)
    pane_pid=$($SOURCE display -p '#{pane_pid}' | tr -d '\r')
    $SOURCE upgrade-server "$(cygpath -w "$target_exe")" || exit 1
    wait_until changed || { $TMUX display -p '#{server_upgrade}'; exit 1; }
    $TMUX list-keys | tr -d '\r' >"$OUT/after"
    # move-window is an at menu command on this build, so tmux's own prints
    # by its short name (TMUX-210).
    sed -i 's/move-window /movew /g' "$OUT/before" "$OUT/after"
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

if [ -n "$TEST_FOOTER_TMUX" ]; then
    # The footer build has a Footer mouse key bound by default and one bound
    # here, the strip's formats set as user options, and a side panel open on
    # an attached client. The upgrade drops all of them and keeps the rest.
    SOURCE="$TEST_FOOTER_TMUX -L$TEST_SOCKET"
    $SOURCE -f "$OUT/test.conf" new -d -s footer -x 120 -y 30 || exit 1
    wait_ready footer || exit 1
    $SOURCE bind -T custom MouseMoveFooter display -p FOOTER_MOVE || exit 1
    $SOURCE bind -T custom F11 display -p KEPT_F11 || exit 1
    $SOURCE set -g @kept yes || exit 1
    $SOURCE list-keys -T root MouseDown1Footer | grep -q strip-menu ||
        { echo "the footer build has no MouseDown1Footer default"; exit 1; }
    [ -n "$($SOURCE show -gqv @strip-menu | tr -d '\r')" ] ||
        { echo "the footer build sets no @strip-menu"; exit 1; }
    $OUTER -f "$OUT/test.conf" new -d -s outer -x 120 -y 30 \
        "$(cygpath -w "$TEST_FOOTER_TMUX")" -L "$TEST_SOCKET" attach -t footer || exit 1
    attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
    wait_until attached || { echo "the client never attached"; exit 1; }
    CLIENT=$($SOURCE list-clients -F '#{client_name}' | tr -d '\r')
    $SOURCE display-panel -c "$CLIENT" -T Links -b1 -g one -N -- \
        All a 'set -g @tab all' show-all Row r 'set -g @row yes' row || exit 1
    panel_open() {
        [ "$($SOURCE display -c "$CLIENT" -p '#{client_panel_width}' | tr -d '\r')" -gt 0 ]
    }
    wait_until panel_open || { echo "the footer build's panel never opened"; exit 1; }
    before_pid=$(server_pid)
    pane_pid=$($SOURCE display -p -t footer '#{pane_pid}' | tr -d '\r')
    $SOURCE upgrade-server "$(cygpath -w "$TEST_TMUX")" || exit 1
    wait_until changed || { $TMUX display -p '#{server_upgrade}'; exit 1; }
    [ "$($TMUX display -p -t footer '#{pane_pid}' | tr -d '\r')" = "$pane_pid" ] ||
        { echo "the pane did not survive the upgrade"; exit 1; }
    [ -n "$($TMUX list-clients)" ] || { echo "the client was lost"; exit 1; }
    $TMUX list-keys | grep -q Footer &&
        { echo "a Footer key survived:"; $TMUX list-keys | grep Footer; exit 1; }
    $TMUX list-keys -T custom F11 | grep -q KEPT_F11 ||
        { echo "the custom binding beside the Footer one was lost"; exit 1; }
    [ -z "$($TMUX show -gqv @strip-menu | tr -d '\r')" ] ||
        { echo "@strip-menu survived the upgrade"; exit 1; }
    [ "$($TMUX show -gqv @kept | tr -d '\r')" = yes ] ||
        { echo "a user option of the person's was lost"; exit 1; }
    # The panel's columns go back to the window.
    whole() {
        [ "$($TMUX display -p -t footer '#{window_width}' | tr -d '\r')" = \
          "$($TMUX list-clients -F '#{client_width}' | tr -d '\r')" ]
    }
    wait_until whole || { echo "the window is still narrowed for the panel"; exit 1; }
    $TMUX display-panel -C 2>/dev/null &&
        { echo "display-panel is still a command"; exit 1; }
    # Its default Ctrl+Shift+O ran display-panel, which this build has no
    # more: the key takes this build's default instead of going unbound.
    $TMUX list-keys -T root | grep -a 'C-S-o' | grep -q 'panel -session' ||
        { echo "Ctrl+Shift+O lost its default:"; $TMUX list-keys -T root | grep -a 'C-S-o'; exit 1; }
    $TMUX kill-server
    $OUTER kill-server 2>/dev/null
    echo 'PASS: an upgrade from the footer and side panel build drops their keys, options and panel, keeps the rest, and a default whose command went takes the new default'
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
