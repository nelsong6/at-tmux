#!/bin/sh

# A command client reads and writes files for the server: source-file,
# load-buffer and save-buffer from a second client finish, keep the file's
# bytes, and report errors with exit 1. On Windows they used to wait forever
# (libevent can't watch a file descriptor that isn't a socket).
# Stdin is read as well: source-file -, load-buffer - and split-window -I
# used to get nothing and exit 0 on Windows.

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

fail() {
	echo "FAIL: $*"
	exit 1
}

# run COMMAND...: a tmux command that must finish within 10 s.
run() {
	timeout 10 $TMUX "$@"
	_rc=$?
	[ $_rc -eq 124 ] && fail "hung: $*"
	return $_rc
}

$TMUX -fNUL new -d </dev/null || fail "new"

printf 'set -g @one 1\r\nset -g @two 2\n' >$OUT/good.conf
run source-file $OUT/good.conf || fail "source-file"
[ "$($TMUX show -gv @one)" = 1 ] || fail "@one not set"
[ "$($TMUX show -gv @two)" = 2 ] || fail "@two not set"

printf 'set -g @three 3\nno-such-command\n' >$OUT/bad.conf
run source-file $OUT/bad.conf >/dev/null 2>&1 && fail "bad file exited 0"
run source-file $OUT/missing.conf 2>/dev/null && fail "missing file exited 0"

printf 'a\r\nb\000c' >$OUT/in.bin
run load-buffer -b in $OUT/in.bin || fail "load-buffer"
run save-buffer -b in $OUT/out.bin || fail "save-buffer"
cmp -s $OUT/in.bin $OUT/out.bin || fail "save-buffer changed the bytes"

# A command client's cwd and relative path are literal Windows paths, even
# when the server was started in a different directory.
EXE=$(cygpath -ma "$TEST_TMUX")
mkdir -p "$OUT/cwd with-[brackets].d/inner dir" || fail "relative directory"
printf 'set -g @relative "loaded relative"\n' \
    >"$OUT/cwd with-[brackets].d/inner dir/relative.conf"
(
	cd "$OUT/cwd with-[brackets].d" || exit 1
	MSYS2_ARG_CONV_EXCL='*' timeout 10 "$EXE" "-L$TEST_SOCKET" \
	    source-file "inner dir/relative.conf"
) || fail "relative source-file from a cwd with punctuation"
[ "$($TMUX show -gv @relative | tr -d '\r')" = "loaded relative" ] ||
    fail "relative file was not executed"
(
	cd "$OUT/cwd with-[brackets].d" || exit 1
	MSYS2_ARG_CONV_EXCL='*' timeout 10 "$EXE" "-L$TEST_SOCKET" \
	    source-file "inner dir/missing.conf"
) 2>/dev/null
_rc=$?
[ $_rc -eq 1 ] || fail "missing relative file exited $_rc instead of 1"

# Stdin, whatever it is, reaches the server as it was written.
printf 'set -g @piped "h\303\251llo"\r\nset -g @piped2 2\n' |
    run source-file - || fail "piped source-file"
[ "$($TMUX show -gv @piped)" = "$(printf 'h\303\251llo')" ] ||
    fail "piped @piped not set"
[ "$($TMUX show -gv @piped2)" = 2 ] || fail "piped @piped2 not set"

printf 'set -g @redirected 1\n' >$OUT/redirected.conf
run source-file - <$OUT/redirected.conf || fail "redirected source-file"
[ "$($TMUX show -gv @redirected)" = 1 ] || fail "redirected file not executed"

run source-file - </dev/null || fail "source-file of empty stdin"

printf 'set -g @four 4\nno-such-command\n' |
    run source-file - >/dev/null 2>&1 && fail "piped bad commands exited 0"

: >$OUT/unreadable
run source-file - 0>$OUT/unreadable 2>$OUT/err &&
    fail "unreadable stdin exited 0"
tr -d '\r' <$OUT/err | grep -q ': -$' ||
    fail "unreadable stdin error: $(cat $OUT/err)"

# More than a pipe or a tmux message holds, with every byte value.
head -c 300000 /dev/urandom >$OUT/stdin.bin
run load-buffer -b stdin - <$OUT/stdin.bin || fail "load-buffer from a file"
run save-buffer -b stdin $OUT/saved.bin || fail "save stdin buffer"
cmp -s $OUT/stdin.bin $OUT/saved.bin || fail "load-buffer changed stdin's bytes"
cat $OUT/stdin.bin | run load-buffer -b piped - || fail "load-buffer from a pipe"
run save-buffer -b piped $OUT/saved.bin || fail "save piped buffer"
cmp -s $OUT/stdin.bin $OUT/saved.bin || fail "load-buffer changed piped bytes"

# A pane fed from stdin shows it as it arrives, before stdin ends.
(
	printf 'early-line\n'
	wait_for :.1 '^early-line' || touch $OUT/late
) | run split-window -I
[ ! -e $OUT/late ] || fail "stdin reached the pane only when it ended"
$TMUX kill-pane -t:.1

# A stdin nobody closes doesn't keep a client whose server has gone.
(
	while [ ! -e $OUT/stop ]; do
		sleep 0.1
	done
) | (
	timeout 20 $TMUX set -g @reading 1 \; source-file - 2>/dev/null
	echo $? >$OUT/rc
) &
reading() {
	[ "$($TMUX show -gv @reading 2>/dev/null)" = 1 ]
}
wait_until reading || fail "client reading stdin did not start"
$TMUX kill-server 2>/dev/null
wait_until test -e $OUT/rc
_found=$?
touch $OUT/stop
wait
[ $_found -eq 0 ] || fail "client kept reading stdin after its server ended"
[ "$(cat $OUT/rc)" != 124 ] || fail "client outlived its server"

$TMUX kill-server 2>/dev/null

echo "ALL FILE TESTS PASSED"
exit 0
