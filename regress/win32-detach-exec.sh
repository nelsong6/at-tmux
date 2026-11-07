#!/bin/sh

# A client started by detach-client -E has the same terminal features as the
# one it replaced (TMUX-161). The replaced client waits for the new one on the
# same console, and the terminal's first reply went missing while it did. The
# client runs in a pseudo-console, as in Windows Terminal, whose console host
# answers the requests.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; wait; rm -rf "$OUT"' 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

PS="$(cygpath "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
WIN=$(cygpath -wa "$TEST_TMUX")

$TMUX -fNUL new -d -x80 -y24 </dev/null || exit 1

env -u TERM "$PS" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
    -Command "\"$WIN\" -L$TEST_SOCKET attach" \
    -Cols 80 -Rows 24 -ResizeFile "$(cygpath -w "$OUT/resize")" &

client() {
	$TMUX list-clients -F '#{client_name}' 2>/dev/null | head -1 | tr -d '\r'
}
features() {
	$TMUX list-clients -F '#{client_termfeatures}' 2>/dev/null | tr -d '\r'
}
has_margins() {
	case ",$(features)," in *,margins,*) ;; *) return 1 ;; esac
}

attached() {
	[ -n "$(client)" ]
}
wait_until attached || { echo "client never attached"; exit 1; }
wait_until has_margins || { echo "the terminal never answered: $(features)"; exit 1; }
FIRST=$(client)
WANT=$(features)

$TMUX detach-client -t "$FIRST" -E "$WIN -L$TEST_SOCKET attach"

replaced() {
	_c=$(client)
	[ -n "$_c" ] && [ "$_c" != "$FIRST" ]
}
WAIT_TIMEOUT=30 wait_until replaced || { echo "client never replaced"; exit 1; }

same() {
	[ "$(features)" = "$WANT" ]
}
if wait_until same; then
	echo "PASS: the new client has the features of the one it replaced"
else
	fail "had $WANT, now $(features)"
fi

exit $FAIL
