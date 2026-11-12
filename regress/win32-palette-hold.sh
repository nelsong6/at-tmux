#!/bin/sh

# display-palette -R holds the palette while the modifiers of the key that
# opened it are down (TMUX-202): released with no key pressed, the picker gets
# Enter and its pick runs; a key pressed first ends the hold, so the palette
# stays open, and while the modifiers are down the opening key and Tab reach
# the picker as Down and Shift+Tab as Up. win32-palette-keys.ps1 stands in for
# fzt and records the keys it gets. The user option @palette-hold-held stands
# in for the held key: nothing holds Ctrl here. The client runs in a
# pseudo-console, and keys reach it with send-keys -K.

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
KEYS="$(cygpath -m "$(dirname "$0")/win32-palette-keys.ps1")"
PICKER="\"$PS\" -NoProfile -ExecutionPolicy Bypass -File \"$KEYS\" -Dir \"$(cygpath -m "$OUT")\""

cat >"$OUT/test.conf" <<EOF
set -g default-shell "$PS"
set -g status off
bind -n C-t display-palette -R -w 100% -h 100% $PICKER
bind -n C-BTab display-palette -R -w 100% -h 100% $PICKER
EOF
$TMUX -f "$(cygpath -m "$OUT/test.conf")" new -d -x100 -y30 -n first \
    </dev/null || exit 1
echo new-window >"$OUT/pick"

"$PS" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; exit 1; }
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')

ready() {
	[ -e "$OUT/ready" ]
}
KEYS_GOT=
keys_are() {
	KEYS_GOT=$(cat "$OUT/keys" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
	[ "$KEYS_GOT" = "$1 " ]
}
window_count() {
	$TMUX list-windows 2>/dev/null | wc -l | tr -d ' '
}
count_is() {
	[ "$(window_count)" -eq "$1" ]
}
# open KEY: hold the key, open the palette with it, and wait for the picker.
open() {
	rm -f "$OUT/ready" "$OUT/keys"
	$TMUX set -g @palette-hold-held 1
	$TMUX send-keys -K -c "$CLIENT" "$1"
	wait_until ready || { echo "$1 opened no picker"; exit 1; }
}
release() {
	$TMUX set -gu @palette-hold-held
}
expect_keys() {
	wait_until keys_are "$2" ||
	    { echo "$1: the picker got '$KEYS_GOT', expected '$2 '"; exit 1; }
}

# -R needs a key with a modifier behind it.
$TMUX display-palette -c "$CLIENT" -R x 2>"$OUT/err" &&
    { echo "-R without a key was accepted"; exit 1; }
grep -q 'needs a key with a modifier' "$OUT/err" ||
    { echo "-R without a key: $(cat "$OUT/err")"; exit 1; }

# Released with no key pressed: Enter, and the pick runs.
open C-t
sleep 0.3
[ -e "$OUT/keys" ] && { echo "the held palette got keys: $(cat "$OUT/keys")"; exit 1; }
release
expect_keys "release" "Enter"
wait_until count_is 2 || { echo "the pick did not run: $(window_count) windows"; exit 1; }

# The opening key again is Down and ends the hold: released, nothing more
# reaches the picker, and the palette is open until Enter.
open C-t
$TMUX send-keys -K -c "$CLIENT" C-t
expect_keys "second press" "Down"
$TMUX send-keys -K -c "$CLIENT" C-t
expect_keys "third press" "Down Down"
release
sleep 0.5
keys_are "Down Down" || { echo "released after a press, the picker got '$KEYS_GOT'"; exit 1; }
count_is 2 || { echo "the palette chose on release after a press"; exit 1; }
$TMUX send-keys -K -c "$CLIENT" Enter
expect_keys "Enter after the hold ended" "Down Down Enter"
wait_until count_is 3 || { echo "Enter's pick did not run"; exit 1; }

# Ctrl+Shift+Tab is Up, and Tab with Ctrl down is Down, whichever key opened it.
open C-BTab
$TMUX send-keys -K -c "$CLIENT" C-BTab \; send-keys -K -c "$CLIENT" C-Tab
expect_keys "Ctrl+Shift+Tab then Ctrl+Tab" "Up Down"
release
$TMUX send-keys -K -c "$CLIENT" Enter
expect_keys "Enter" "Up Down Enter"
wait_until count_is 4 || { echo "Enter's pick did not run"; exit 1; }

$TMUX kill-server 2>/dev/null

echo "ALL PALETTE HOLD TESTS PASSED"
exit 0
