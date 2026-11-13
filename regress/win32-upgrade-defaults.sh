#!/bin/sh

# upgrade-server brings the new build's default key bindings to every key
# nobody changed: a default changed in the new build replaces the old one, a
# default the new build dropped goes, and one it added appears; a key rebound
# or unbound on the old server stays as it was. TEST_DEFAULTS_TMUX is this
# build with prefix t changed, F9 added and z removed
# (build-upgrade-key-fixtures.ps1). TEST_LEGACY_TMUX predates the defaults
# being sent: its never-rebound kill defaults come as close defaults.
PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
[ -n "$TEST_TMUX" ] && [ -n "$TEST_DEFAULTS_TMUX" ] &&
    [ -n "$TEST_LEGACY_TMUX" ] || { echo "FAIL: fixture builds missing"; exit 1; }
TMUX="$TEST_TMUX -L$TEST_SOCKET"
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -f $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX list-keys -T prefix 2>&1 | grep -E ' (t|z|F9|w|n|F10|&|x) '
	exit 1
}

server_pid() { $TMUX display -p '#{pid}' | tr -d '\r'; }
changed() { [ "$(server_pid)" != "$before" ]; }
# binding KEY: prefix KEY's command, or nothing when it is unbound.
binding() {
	$TMUX list-keys -T prefix "$1" 2>/dev/null | tr -d '\r' |
	    sed 's/^bind-key *-T prefix *[^ ]* *//'
}

# upgrade FROM TO: start a server on FROM with a key rebound, one unbound
# and one of its own, then hand it to TO.
upgrade() {
	SOURCE="$1 -L$TEST_SOCKET"
	$SOURCE -f"$(cygpath -m $CFG)" new -d -s keys </dev/null ||
	    fail "start $1"
	$SOURCE bind w display-message USER_W || fail "rebind w"
	$SOURCE unbind n || fail "unbind n"
	$SOURCE bind F10 display-message USER_F10 || fail "bind F10"
	before=$(server_pid)
	$SOURCE upgrade-server "$(cygpath -w "$2")" || fail "upgrade-server"
	wait_until changed ||
	    fail "no upgrade: $($TMUX display -p '#{server_upgrade}')"
}

kept_user_changes() {
	[ "$(binding w)" = "display-message USER_W" ] ||
	    fail "$1: rebound w not kept"
	[ -z "$(binding n)" ] || fail "$1: unbound n came back"
	[ "$(binding F10)" = "display-message USER_F10" ] ||
	    fail "$1: user's F10 not kept"
}

upgrade "$TEST_DEFAULTS_TMUX" "$TEST_TMUX"
[ "$(binding t)" = clock-mode ] || fail "changed default t not this build's"
[ -z "$(binding F9)" ] || fail "default this build dropped is still bound"
[ "$(binding z)" = "resize-pane -Z" ] || fail "default this build added missing"
$TMUX list-keys -N -T prefix t | grep -q 'Show a clock' ||
    fail "t lost its note"
kept_user_changes "to this build"
$TMUX kill-server
wait_gone || fail "server did not exit"
echo 'PASS: defaults changed, dropped and added reach an upgraded server'

upgrade "$TEST_TMUX" "$TEST_DEFAULTS_TMUX"
[ "$(binding t)" = "display-message OLD_T" ] ||
    fail "the other way, t not the fixture's"
[ "$(binding F9)" = "display-message OLD_F9" ] ||
    fail "the other way, F9 missing"
[ -z "$(binding z)" ] || fail "the other way, z still bound"
kept_user_changes "to the fixture"
$TMUX kill-server
wait_gone || fail "server did not exit"
echo 'PASS: and the other way'

# A build before the defaults were sent: a binding still exactly one of its
# changed defaults is taken as never rebound.
SOURCE="$TEST_LEGACY_TMUX -L$TEST_SOCKET"
$SOURCE -f"$(cygpath -m $CFG)" new -d -s legacy </dev/null ||
    fail "start legacy"
$SOURCE bind '<' display-message USER_LT || fail "rebind <"
before=$(server_pid)
$SOURCE upgrade-server "$(cygpath -w "$TEST_TMUX")" || fail "upgrade legacy"
wait_until changed || fail "no legacy upgrade"
binding '&' | grep -q close-window || fail "legacy & not close-window"
binding x | grep -q close-pane || fail "legacy x not close-pane"
$TMUX list-keys -T root MouseDown3Status | grep -q 'close-window' ||
    fail "legacy window menu has no Close"
$TMUX list-keys -T root MouseDown3Pane | grep -q 'close-pane' ||
    fail "legacy pane menu has no Close"
[ "$(binding '<')" = "display-message USER_LT" ] ||
    fail "legacy rebound < not kept"
$TMUX list-keys -N -T prefix '&' | grep -q 'Close current window' ||
    fail "legacy & kept its old note"
echo 'PASS: an older build'"'"'s never-rebound kill defaults become close'

echo 'ALL UPGRADE DEFAULTS TESTS PASSED'
