#!/bin/sh

# copy-window-name-to-clipboard and copy-session-name-to-clipboard put the
# name in a new paste buffer and send it to the client's terminal clipboard
# (OSC 52). The client runs in a pane of a second server with set-clipboard
# on, which stands in for Windows Terminal: the clipboard it receives becomes
# its own paste buffer.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15

CFG="$OUT/copy.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
set -g set-clipboard on
EOF

FAIL=0
fail() {
	echo "FAIL: $1"
	FAIL=1
}

$TMUX -f "$CFG" new -d -s 'work session' -n 'build window' -x40 -y10 \
    </dev/null || exit 1
$TMUX new-window -d -t 'work session' -n 'other window' || exit 1

# The client is -c, the window or session -t.
for c in window session; do
	$TMUX list-commands copy-$c-name-to-clipboard | grep -q \
	    "^copy-$c-name-to-clipboard \[-c target-client\] \[-t target-$c\]" || \
	    fail "copy-$c-name-to-clipboard usage: $($TMUX list-commands copy-$c-name-to-clipboard)"
done

# No client yet: nothing to copy to.
$TMUX copy-window-name-to-clipboard -t 'work session:build window' \
    2>/dev/null && fail "copied with no client attached"
[ -z "$($TMUX list-buffers 2>/dev/null)" ] || \
    fail "a failed copy left a paste buffer"

$OUTER -f "$CFG" new -d -x40 -y10 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

# The newest buffer of a server.
top() {
	$1 show-buffer 2>/dev/null
}
outer_has() {
	[ "$(top "$OUTER")" = "$EXPECTED" ]
}

# A window that isn't current, named by -t.
EXPECTED='other window'
$TMUX copy-window-name-to-clipboard -t 'work session:other window' || \
    fail "copy-window-name-to-clipboard failed"
[ "$(top "$TMUX")" = "$EXPECTED" ] || \
    fail "paste buffer is '$(top "$TMUX")', not '$EXPECTED'"
wait_until outer_has || fail "terminal clipboard got '$(top "$OUTER")', not '$EXPECTED'"

# With no -t, the client's current window.
EXPECTED='build window'
$TMUX copy-window-name-to-clipboard || \
    fail "copy-window-name-to-clipboard (current) failed"
wait_until outer_has || fail "terminal clipboard got '$(top "$OUTER")', not '$EXPECTED'"

EXPECTED='work session'
$TMUX copy-session-name-to-clipboard || \
    fail "copy-session-name-to-clipboard failed"
[ "$(top "$TMUX")" = "$EXPECTED" ] || \
    fail "paste buffer is '$(top "$TMUX")', not '$EXPECTED'"
wait_until outer_has || fail "terminal clipboard got '$(top "$OUTER")', not '$EXPECTED'"

# A window with no name copies nothing and says so.
$TMUX rename-window -t 'work session:other window' '' || exit 1
COUNT=$($TMUX list-buffers | wc -l)
ERR=$($TMUX copy-window-name-to-clipboard -t 'work session:1' 2>&1) && \
    fail "copied an empty name"
echo "$ERR" | grep -q "no name to copy" || fail "empty name error was '$ERR'"
[ "$($TMUX list-buffers | wc -l)" = "$COUNT" ] || \
    fail "an empty name made a paste buffer"

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

[ $FAIL = 0 ] || exit 1
echo "ALL COPY NAME TESTS PASSED"
exit 0
