#!/bin/sh

# The at system's settings are built in (TMUX-210): a server reads no
# configuration file of its own, starts with them, returns to them on set -u,
# leaves what only the at server does (Win+`) to the at server, and lets a
# plain drag select over a program that asked only for clicks (TMUX-227), and
# passes a program's links on to the terminal (ATC-154). The programs at keeps
# running start from home-sync's programs.conf (AHT-193).

PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
HOMEDIR=$(mktemp -d)
PROGRAMS="$TEST_TMUX -L$TEST_SOCKET-programs"
trap "$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; $PROGRAMS kill-server 2>/dev/null; rm -rf $HOMEDIR" 0 1 15

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
USERPROFILE=$(cygpath -w "$HOMEDIR") \
    $TMUX new -d -s defaults </dev/null || fail "start"
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

# toggle-agent-sounds holds play-sound back and keeps bells from the terminal,
# the switch the looper turns too (GLC-49): a missing file is an error only
# while sounds play.
$TMUX play-sound -t defaults: /no-such-sound.wav 2>/dev/null &&
    fail "play-sound played a missing file"
$TMUX toggle-agent-sounds || fail "toggle-agent-sounds"
$TMUX play-sound -t defaults: /no-such-sound.wav ||
    fail "play-sound was not held back while muted"
[ "$(value bell-action)" = none ] || fail "bell-action is $(value bell-action) while muted"
$TMUX toggle-agent-sounds || fail "toggle-agent-sounds again"
$TMUX play-sound -t defaults: /no-such-sound.wav 2>/dev/null &&
    fail "play-sound is still held back"
[ "$(value bell-action)" = any ] || fail "bell-action is $(value bell-action) after unmuting"
echo 'PASS: toggle-agent-sounds mutes and unmutes sounds and bells'

[ -z "$($TMUX list-keys -T global 2>/dev/null)" ] ||
    fail "a test server has the at server's global keys"
[ -z "$(value @session-set-dir)" ] ||
    fail "a test server writes the session set"
echo 'PASS: only the at server has its global key and session set'

# A plain drag selects text over a program that asked only for clicks (mode
# 1000, as tcell's MouseButtonEvents does), and reaches one that asked for
# drags (1002) (TMUX-227). Real mouse packets reach an attached client through
# an outer server's pane.
cat >"$HOMEDIR/mode.sh" <<'EOF'
printf '\033[?%sh\033[?1006hSELECT THIS LINE\n' "$1"
exec sleep 600
EOF
program() { echo "$(cygpath -d /usr/bin/bash) $(cygpath -m "$HOMEDIR/mode.sh") $1"; }
flag() { $TMUX display -p -t drag "#{$1}" | tr -d '\r'; }
shown() { $TMUX capture-pane -p -t drag | grep -q 'SELECT THIS LINE'; }
# drag: presses on the line's first column, drags to the sixth and releases.
drag() {
	sleep 0.4 # tmux's click timer, so this is no double click
	$OUTER send-keys -H $(printf '\033[<0;1;%dM\033[<32;6;%dM\033[<0;6;%dm' "$row" "$row" "$row" | od -An -tx1)
}
$TMUX new -d -s drag -x 81 -y 24 "$(program 1000)" </dev/null || fail "start drag"
printf "set -g default-shell '%s'\nset -g status off\n" "$COMSPEC" >"$HOMEDIR/outer.conf"
$OUTER -f "$HOMEDIR/outer.conf" new -d -x 81 -y 24 </dev/null || fail "start outer"
# The client names its terminal as at-terminal's does.
$OUTER send-keys "set TMUX=" Enter "set TERM=xterm-256color" Enter "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach -t drag" Enter
attached() { [ "$($TMUX list-clients | wc -l)" = 1 ]; }
wait_until attached || fail "no client attached"
# The line's row on the client's screen, under the window bar.
row() { $OUTER capture-pane -p | tr -d '\r' | grep -n 'SELECT THIS LINE' | cut -d: -f1; }
drawn() { [ -n "$(row)" ]; }
wait_until drawn || fail "the client never drew the line"
row=$(row)
standard() { [ "$(flag mouse_standard_flag)" = 1 ] && shown; }
wait_until standard || fail "the pane never asked for clicks"
[ "$(flag mouse_button_flag)" = 0 ] || fail "mode 1000 set the drag flag"
drag
copied() {
	$TMUX show-buffer 2>/dev/null | grep -q '^SELEC' &&
	    [ "$(flag pane_in_mode)" = 0 ]
}
wait_until copied ||
    fail "a plain drag didn't select: buffer '$($TMUX show-buffer 2>/dev/null)'"
echo 'PASS: a plain drag selects over a program that asked only for clicks'

$TMUX delete-buffer
$TMUX respawn-pane -k -t drag "$(program 1002)"
button() { [ "$(flag mouse_button_flag)" = 1 ] && shown; }
wait_until button || fail "the pane never asked for drags"
drag
sleep 1
[ "$(flag pane_in_mode)" = 0 ] || fail "a drag the program asked for started copy mode"
! $TMUX show-buffer >/dev/null 2>&1 || fail "a drag the program asked for was copied"
echo 'PASS: a drag reaches a program that asked for drags'

# A program's links reach the terminal as OSC 8 hyperlinks, so at-terminal
# opens one on Ctrl+click and a plain click, one that only focuses a pane,
# opens nothing (ATC-154). The outer server's pane holds what the client drew,
# its links included.
features() { $TMUX display -p '#{client_termfeatures}' | tr -d '\r'; }
features | grep -q hyperlinks ||
    fail "the client has no hyperlinks feature: $(features)"
cat >"$HOMEDIR/link.sh" <<'EOF'
printf '\033]8;;https://example.com/at-link\033\\LINK TEXT\033]8;;\033\\\n'
exec sleep 600
EOF
$TMUX respawn-pane -k -t drag \
    "$(cygpath -d /usr/bin/bash) $(cygpath -m "$HOMEDIR/link.sh")"
linked() {
	$OUTER capture-pane -ep | tr -d '\r' |
	    grep -q 'https://example.com/at-link.*LINK TEXT'
}
wait_until linked ||
    fail "the link never reached the terminal: $($OUTER capture-pane -ep | grep 'LINK TEXT' | od -c | head -5)"
echo "PASS: a program's link reaches the terminal as a hyperlink"

# home-sync's programs.conf gives every server the system-session alias, and
# its starts are the at server's alone, run as it starts (AHT-193).
mkdir "$HOMEDIR/at-home"
cat >"$HOMEDIR/at-home/programs.conf" <<EOF
set -s command-alias[112] 'system-session=display-message from-programs-conf'
set -g @at-programs-start "run-shell -b 'echo started >$(cygpath -m "$HOMEDIR")/started'"
EOF
TMUX_PROGRAMS_CONF= LOCALAPPDATA=$(cygpath -w "$HOMEDIR") $PROGRAMS new -d -s programs </dev/null ||
    fail "start with programs.conf"
$PROGRAMS show -s command-alias | grep -q 'system-session=display-message from-programs-conf' ||
    fail "programs.conf's system-session is missing"
[ -n "$($PROGRAMS show -gv @at-programs-start)" ] ||
    fail "programs.conf's starts are missing"
$PROGRAMS run-shell 'echo ran' >/dev/null || fail "the server stopped answering"
[ ! -e "$HOMEDIR/started" ] || fail "a test server ran the at server's starts"
# What the at server runs as it starts starts them.
$PROGRAMS run-shell -C '#{@at-programs-start}' || fail "run the starts"
started() { [ -e "$HOMEDIR/started" ]; }
wait_until started || fail "@at-programs-start started nothing"
$PROGRAMS kill-server
echo "PASS: every server reads programs.conf, and only the at server starts its programs"

echo 'ALL AT DEFAULTS TESTS PASSED'
exit 0
