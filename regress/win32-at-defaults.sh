#!/bin/sh

# The at system's settings are built in (TMUX-210): a server reads no
# configuration file of its own, starts with them, returns to them on set -u,
# and leaves what only the at server does (Win+`) to the at server.

PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
HOMEDIR=$(mktemp -d)
trap "$TMUX kill-server 2>/dev/null; rm -rf $HOMEDIR" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}
value() { $TMUX show -gv "$1" | tr -d '\r'; }
binding() {
	$TMUX list-keys -T "$1" "$2" 2>/dev/null | tr -d '\r' |
	    sed 's/^bind-key *-T [^ ]* *[^ ]* *//'
}

# A ~/.tmux.conf is there, and is not read.
printf 'set -g @from-file yes\nset -g base-index 7\n' >"$HOMEDIR/.tmux.conf"
USERPROFILE=$(cygpath -w "$HOMEDIR") $TMUX new -d -s defaults </dev/null ||
    fail "start"
[ -z "$($TMUX display -p '#{config_files}' | tr -d '\r')" ] ||
    fail "a configuration file was loaded"
[ -z "$(value @from-file)" ] || fail "~/.tmux.conf was read"
echo 'PASS: no configuration file is read'

[ "$(value base-index)" = 1 ] || fail "base-index is $(value base-index)"
[ "$(value prefix)" = None ] || fail "prefix is $(value prefix)"
[ "$(value mouse)" = on ] || fail "mouse is $(value mouse)"
[ -n "$(value @fzt-automate)" ] || fail "@fzt-automate missing"
binding root C-b | grep -q -- '--open tmux' || fail "Ctrl+B is not the at menu"
binding root M-Tab | grep -q -- '--open windows' ||
    fail "Alt+Tab does not open the windows folder"
binding root M-BTab | grep -q -- '--open windows' ||
    fail "Alt+Shift+Tab does not open the windows folder"
[ "$(binding prefix t)" = new-window ] || fail "prefix t is $(binding prefix t)"
echo 'PASS: the built-in settings are there'

$TMUX set -g base-index 5 || fail "set base-index"
$TMUX set -gu base-index || fail "unset base-index"
[ "$(value base-index)" = 1 ] || fail "set -u gave base-index $(value base-index)"
$TMUX toggle-bypass-label || fail "toggle-bypass-label"
[ -z "$(value pane-hidden-text)" ] || fail "the bypass label is still hidden"
$TMUX toggle-bypass-label || fail "toggle-bypass-label again"
$TMUX show -g pane-hidden-text | grep -q 'bypass permissions on' ||
    fail "the bypass label is not hidden again"
echo 'PASS: set -u returns to the built-in settings'

[ -z "$($TMUX list-keys -T global 2>/dev/null)" ] ||
    fail "a test server has the at server's global keys"
[ -z "$(value @session-set-dir)" ] ||
    fail "a test server writes the session set"
echo 'PASS: only the at server has its global key and session set'

echo 'ALL AT DEFAULTS TESTS PASSED'
exit 0
