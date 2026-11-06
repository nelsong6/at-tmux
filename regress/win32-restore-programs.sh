#!/bin/sh

# What a pane comes back as from reopen-window and restore-set: an agent by its
# ID, a program by its start command, exactly as it was started, and a shell for
# a dead pane, a marked pane, an agent with no ID, and a program that can't
# start, which costs only itself. A window keeps its @<name>-window marks.
# Snapshots and closed-windows of version 1 stay readable.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

DIR=$(mktemp -d)
WDIR=$(cygpath -m "$DIR")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -rf $DIR $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name} #{window_panes}' 2>&1
	$TMUX show-messages 2>&1 | tail -10
	cat "$DIR"/live/*.set 2>&1
	cat "$DIR/closed-windows" 2>&1
	exit 1
}

SYS=$(cygpath -w "$SYSTEMROOT")
PING="$SYS\System32\PING.EXE"
T=$(printf '\t')

$TMUX -f"$(cygpath -m $CFG)" new -d -s main -n one || fail "start server"
SNAP="$DIR/live/$(basename "$($TMUX display -p '#{socket_path}' | tr -d '\r').set")"
$TMUX set -g @session-set-dir "$WDIR" || fail "set dir"
$TMUX set -g @session-set-resume 'claude.exe --resume {id}' || fail "set resume"
$TMUX set -g @session-set-resume-codex 'codex.exe --no-daemon resume {id}' ||
    fail "set Codex resume"

value() { $TMUX display -p -t "$1" "$2" | tr -d '\r'; }
start_of() { value "$1" '#{pane_start_command}'; }
has_window() {
	$TMUX lsw -t=main -F '#{window_name}' 2>/dev/null | tr -d '\r' |
	    grep -qx "$1"
}
snap_has() { grep -q -- "$1" "$SNAP" 2>/dev/null; }
closed() { grep -c -v '^tmux-session-set ' "$DIR/closed-windows" 2>/dev/null; }

# reopen NAME: close a window that a snapshot holds, and open it again.
reopen() {
	wait_until snap_has "${T}$1${T}" || fail "$1 not in the snapshot"
	: >"$DIR/closed-windows"
	$TMUX kill-window -t "=main:$1" || fail "kill $1"
	wait_until test "$(closed)" = 1 || fail "$1 not recorded"
	$TMUX reopen-window -d || fail "reopen $1"
	wait_until has_window "$1" || fail "$1 not reopened"
}
is_shell() {
	[ -z "$(start_of "$1")" ] || fail "$2: start command $(start_of "$1")"
}

# 1. A program comes back with its arguments as they were, and with no shell.
$TMUX new-window -d -t main: -n prog "$PING" -n 300 -w 1234 127.0.0.1 ||
    fail "prog window"
was=$(start_of main:prog)
reopen prog
[ "$(start_of main:prog)" = "$was" ] ||
    fail "start command changed: $(start_of main:prog)"
wait_until test "$(value main:prog '#{pane_current_command}')" = PING ||
    fail "not running PING"
$TMUX kill-window -t main:prog

# A program reports no folder, so it comes back in the one it started in.
MSYS_NO_PATHCONV=1 $TMUX new-window -d -t main: -n folder -c 'C:\Windows' \
    "$COMSPEC" /k cd || fail "folder window"
wait_for main:folder '^C:.Windows$' || fail "folder window not in its folder"
reopen folder
wait_for main:folder '^C:.Windows$' || fail "program didn't come back in its folder"
$TMUX kill-window -t main:folder

# 2. So do arguments tmux's own parser and format engine treat specially, and a
# one-argument command, which goes to the shell.
MSYS_NO_PATHCONV=1 $TMUX new-window -d -t main: -n odd "$COMSPEC" /k echo \
    'a b' '$HOME' '#{pane_id}' '100%' 'x;y' '\;' "it's" '"q"' '~' 'tail\' '' ||
    fail "odd window"
was=$(start_of main:odd)
reopen odd
[ "$(start_of main:odd)" = "$was" ] ||
    fail "arguments changed: $was became $(start_of main:odd)"
wait_for main:odd '^a b \$HOME #{pane_id} 100% x;y ; it' ||
    fail "the program didn't get its arguments"
$TMUX kill-window -t main:odd

$TMUX new-window -d -t main: -n line "$PING -n 300 127.0.0.1 >nul" ||
    fail "line window"
was=$(start_of main:line)
reopen line
[ "$(start_of main:line)" = "$was" ] || fail "one-argument command changed"
$TMUX kill-window -t main:line

# 3. A program typed into a shell is seen, and the pane comes back as a shell.
$TMUX new-window -d -t main: -n typed || fail "typed window"
wait_ready main:typed
$TMUX send-keys -t main:typed "$PING -n 300 127.0.0.1 >nul" Enter
wait_until snap_has "${T}typed${T}.*${T}PING${T}" ||
    fail "typed program not seen"
reopen typed
is_shell main:typed "a shell came back running something"
$TMUX kill-window -t main:typed

# 4. A dead pane holds a one-shot that already ended.
$TMUX new-window -d -t main: -n dead -o remain-on-exit=on "$COMSPEC /c exit 3" ||
    fail "dead window"
wait_until test "$(value main:dead '#{pane_dead}')" = 1 || fail "pane not dead"
wait_until sh -c "! grep -q 'exit 3' '$SNAP'" ||
    fail "a dead pane's command in the snapshot"
reopen dead
is_shell main:dead "a dead pane"
$TMUX kill-window -t main:dead

# 5. A launcher marks a pane or its window when a rerun would repeat what it did.
$TMUX new-window -d -t main: -n marked -o @session-set-shell=1 "$PING" -n 300 127.0.0.1 ||
    fail "marked window"
reopen marked
is_shell main:marked "a window marked @session-set-shell"
$TMUX kill-window -t main:marked

$TMUX new-window -d -t main: -n paned "$PING" -n 300 127.0.0.1 || fail "paned window"
$TMUX set -p -t main:paned @session-set-shell 1 || fail "mark pane"
wait_until sh -c "! grep -q '${T}paned${T}.*127.0.0.1' '$SNAP'" ||
    fail "a marked pane's command in the snapshot"
reopen paned
is_shell main:paned "a pane marked @session-set-shell"
$TMUX kill-window -t main:paned

# 6. An agent with no ID must not rerun: its command can be the brief it was
# opened on. Whatever its folder, quoting or .exe, and however it was started.
mkdir "$DIR/with space"
cp "$COMSPEC" "$DIR/with space/claude.exe"
cp "$COMSPEC" "$DIR/codex.exe"
cp "$COMSPEC" "$DIR/CLAUDE.EXE"
MSYS_NO_PATHCONV=1 $TMUX new-window -d -t main: -n agent1 \
    "\"$(cygpath -w "$DIR/with space/claude.exe")\"" /k 'do the brief' || fail "agent1"
MSYS_NO_PATHCONV=1 $TMUX new-window -d -t main: -n agent2 \
    "$(cygpath -w "$DIR/codex.exe")" /k 'do the brief' || fail "agent2"
MSYS_NO_PATHCONV=1 $TMUX new-window -d -t main: -n agent3 \
    "$(cygpath -w "$DIR/CLAUDE.EXE") /k do the brief" || fail "agent3"
wait_until snap_has "${T}agent3${T}" || fail "agents not saved"
snap_has 'do the brief' && fail "an agent's brief is in the snapshot"
for w in agent1 agent2 agent3; do
	reopen $w
	is_shell main:$w "an agent with no ID"
	$TMUX kill-window -t main:$w
done

# 7. A program that can't start costs only itself, and says so.
cp "$SYSTEMROOT/System32/PING.EXE" "$DIR/gone.exe"
$TMUX new-window -d -t main: -n gone "$(cygpath -w "$DIR/gone.exe")" -n 300 127.0.0.1 ||
    fail "gone window"
$TMUX split-window -d -t main:gone "$PING" -n 300 127.0.0.1 || fail "gone split"
wait_until snap_has "${T}gone${T}" || fail "gone not saved"
: >"$DIR/closed-windows"
$TMUX kill-window -t main:gone || fail "kill gone"
wait_until test "$(closed)" = 1 || fail "gone not recorded"
rm -f "$DIR/gone.exe"
$TMUX reopen-window -d || fail "a program that can't start failed reopen-window"
wait_until has_window gone || fail "gone not reopened"
[ "$(value main:gone '#{window_panes}')" = 2 ] ||
    fail "the failed program's window lost a pane"
is_shell main:gone.0 "a program that can't start"
[ -n "$(start_of main:gone.1)" ] || fail "the pane beside it lost its program"
$TMUX show-messages | tr -d '\r' | grep -q "a shell in place of: can't start .*gone.exe" ||
    fail "the failure isn't reported"
$TMUX kill-window -t main:gone

# 8. A rerun that fails stays on screen in a window's first pane, and closes in
# any other, so a program's own helper pane leaves no dead pane beside it.
FLAKY="if exist \"$WDIR/flag\" (exit 3) else $PING -n 300 127.0.0.1 >nul"
$TMUX new-window -d -t main: -n flaky "$FLAKY" || fail "flaky window"
$TMUX split-window -d -t main:flaky "$FLAKY" || fail "flaky split"
wait_until snap_has "${T}flaky${T}" || fail "flaky not saved"
: >"$DIR/closed-windows"
$TMUX kill-window -t main:flaky || fail "kill flaky"
wait_until test "$(closed)" = 1 || fail "flaky not recorded"
: >"$DIR/flag"
$TMUX reopen-window -d || fail "reopen flaky"
one_pane() { [ "$(value main:flaky '#{window_panes}')" = 1 ]; }
wait_until one_pane || fail "the failed helper pane stayed"
wait_until test "$(value main:flaky '#{pane_dead}')" = 1 ||
    fail "the failed first pane didn't stay"
wait_for main:flaky '^Pane is dead (status 3' || fail "the failure isn't on screen"
$TMUX kill-window -t main:flaky
rm -f "$DIR/flag"

# 9. A window's @<name>-window marks come back, and only those.
$TMUX new-window -d -t main: -n mark -o @alerts-window=1 -o @other=1 "$PING" -n 300 127.0.0.1 ||
    fail "mark window"
reopen mark
[ "$($TMUX show -wv -t main:mark @alerts-window | tr -d '\r')" = 1 ] ||
    fail "the mark didn't come back"
[ -z "$($TMUX show -wv -t main:mark @other 2>/dev/null | tr -d '\r')" ] ||
    fail "another option came back"

# 10. A restore does the same as a reopen: a rerun program, its mark, a failure
# kept on screen, and a program that can't start named at the end.
$TMUX new-window -d -t main: -n prog "$PING" -n 300 -w 1234 127.0.0.1 ||
    fail "second prog window"
cp "$SYSTEMROOT/System32/PING.EXE" "$DIR/gone.exe"
$TMUX new-window -d -t main: -n gone "$(cygpath -w "$DIR/gone.exe")" -n 300 127.0.0.1 ||
    fail "second gone window"
wait_until snap_has "${T}gone${T}" || fail "windows not saved"
was=$(start_of main:prog)
cp "$SNAP" "$DIR/set.set"
$TMUX kill-window -t main:gone
wait_until sh -c "! grep -q '${T}gone${T}' '$SNAP'" || fail "gone still saved"
rm -f "$DIR/gone.exe"
if $TMUX restore-set -d set.set 2>"$DIR/out"; then
	fail "a program that can't start wasn't reported"
fi
tr -d '\r' <"$DIR/out" | grep -q "^restored [0-9]* of [0-9]* windows, a shell in place of: main-2:[0-9]* (gone), can't start" ||
    fail "the restore doesn't name it: $(cat "$DIR/out")"
[ "$(start_of =main-2:prog)" = "$was" ] || fail "restore changed the start command"
[ "$($TMUX show -pv -t =main-2:prog remain-on-exit | tr -d '\r')" = failed ] ||
    fail "a rerun program won't keep its failure on screen"
[ "$($TMUX show -wv -t =main-2:mark @alerts-window | tr -d '\r')" = 1 ] ||
    fail "restore lost the mark"
is_shell =main-2:gone "a restored program that can't start"
$TMUX kill-session -t =main-2 || fail "clean up"

# 11. closed-windows from before the version line is converted on the next write
# and still reopens, as a shell.
layout=$(value main:one '#{window_layout}')
printf '%s\tmain\tC:/\t9\t0\told\t%s\t0\tC:/Windows\t\tPING\n' 1 "$layout" \
    >"$DIR/closed-windows"
$TMUX new-window -d -t main: -n fresh "$PING" -n 300 127.0.0.1 || fail "fresh window"
wait_until snap_has "${T}fresh${T}" || fail "fresh not saved"
$TMUX kill-window -t main:fresh || fail "kill fresh"
wait_until test "$(closed)" = 2 || fail "fresh not recorded"
head -1 "$DIR/closed-windows" | grep -q '^tmux-session-set 2' ||
    fail "closed-windows has no version line"
sed -n 3p "$DIR/closed-windows" | grep -q "${T}${T}PING${T}$" ||
    fail "the old line wasn't converted"
$TMUX reopen-window -d || fail "reopen fresh"
wait_until has_window fresh || fail "fresh not reopened"
$TMUX reopen-window -d || fail "reopen old"
wait_until has_window old || fail "old line not reopened"
is_shell main:old "a version 1 closed window"

# 12. So does a snapshot of version 1: IDs resume, and programs are shells.
{
	printf 'tmux-session-set 1\nstart\t1\npid\t1\nseen\t1\nclosed\t0\n'
	printf 'restoring\t0\nattached\tv1\nsocket\tv1\n'
	printf 'window\t1\t80\t24\tv1\tC:/\t1\t0\tprogram\t%s\t0\tC:/Windows\t\tPING\n' "$layout"
	printf 'window\t0\t80\t24\tv1\tC:/\t2\t0\tagent\t%s\t0\tC:/Windows\tabc\tclaude\n' "$layout"
} >"$DIR/v1.set"
$TMUX set -g @session-set-resume "$PING -n 300 127.0.0.1 -w {id}" || fail "set resume"
$TMUX restore-set -d v1.set || fail "restore a version 1 snapshot"
is_shell =v1:program "a version 1 snapshot's program"
start_of =v1:agent | grep -q -- '-w abc' || fail "a version 1 snapshot's ID"

exit 0
