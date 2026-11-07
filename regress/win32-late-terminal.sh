#!/bin/sh

# Terminal options set after a client attached reach that client (TMUX-157:
# at-terminal attached before the NAS config could load, and Ctrl+Tab stayed
# dead after the config loaded, because the client never asked Windows Terminal
# for the kitty keyboard protocol). The client runs in a pane of a second
# server. The first server runs with -vvvv, which writes every byte it sends a
# client to tmux-out-<pid>.log, since a console keeps these requests to itself.

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
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; wait; rm -rf "$OUT"' 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

CFG="$OUT/late.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
set -s extended-keys on
set -gu terminal-features
set -s exit-empty off
EOF

ABS=$(cygpath -ma "$TEST_TMUX")
(cd "$OUT" && exec "$ABS" -vvvv -D -L"$TEST_SOCKET" -f "$CFG" </dev/null >/dev/null 2>&1) &

server_up() {
	$TMUX -N start-server 2>/dev/null
}
wait_until server_up || { echo "server never started"; exit 1; }
$TMUX new -d -x40 -y10 "Start-Sleep 120" </dev/null || exit 1

$OUTER -f "$CFG" new -d -x40 -y10 -e TERM=xterm-256color \
    "& '$ABS' -L$TEST_SOCKET attach" </dev/null || exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

# sent TEXT: how many times the server sent the client ESC and TEXT.
sent() {
	cat "$OUT"/tmux-out-*.log 2>/dev/null |
	    grep -ao "$(printf '\033')$1" | wc -l | tr -d ' '
}
sent_is() {
	[ "$(sent "$1")" = "$2" ]
}
features() {
	$TMUX list-clients -F '#{client_termfeatures}'
}
has_extkeys() {
	case ",$(features)," in *,extkeys,*) ;; *) return 1 ;; esac
}

has_extkeys && fail "the client began with extkeys, so nothing below tests it"
before=$(features)

$TMUX set -s terminal-features[90] 'xterm-256color:extkeys'
if wait_until has_extkeys; then
	echo "PASS: a feature set late reaches the attached client"
else
	fail "features still $(features)"
fi
case ",$(features)," in
*,RGB,*) echo "PASS: the client keeps the features it had" ;;
*) fail "was $before, now $(features)" ;;
esac

$TMUX set -s terminal-overrides[90] 'xterm-256color:Eneks=\E[>1u:Dseks=\E[<u'
if wait_until sent_is '\[>1u' 1; then
	echo "PASS: an override set late sends its request"
else
	fail "sent the request $(sent '\[>1u') times"
fi

# Windows Terminal stacks each request, and home-sync sources the config
# again on a running server. The last set changes the request, and its bytes
# coming through shows the repeats before it have been handled.
$TMUX set -s terminal-features[90] 'xterm-256color:extkeys'
$TMUX set -s terminal-overrides[90] 'xterm-256color:Eneks=\E[>1u:Dseks=\E[<u'
$TMUX set -s terminal-overrides[90] 'xterm-256color:Eneks=\E[>2u:Dseks=\E[<u'
if wait_until sent_is '\[>2u' 1; then
	echo "PASS: a changed request replaces the old one"
else
	fail "sent the changed request $(sent '\[>2u') times"
fi
if [ "$(sent '\[>1u')" = 1 ]; then
	echo "PASS: setting the same values again sends no second request"
else
	fail "sent the request $(sent '\[>1u') times"
fi
popped=$(sent '\[<u')
[ "$popped" = 1 ] || fail "ended the old request $popped times"

$TMUX set -s extended-keys off
if wait_until sent_is '\[<u' 2; then
	echo "PASS: turning extended-keys off ends the request"
else
	fail "ended the request $(sent '\[<u') times"
fi
$TMUX set -s extended-keys on
if wait_until sent_is '\[>2u' 2; then
	echo "PASS: turning extended-keys on sends the request"
else
	fail "sent the request $(sent '\[>2u') times"
fi

$TMUX list-clients | grep -q . || fail "the client is gone"

exit $FAIL
