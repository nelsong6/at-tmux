#!/bin/sh

# A continued command has the same meaning with LF or CRLF line endings.
PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUT=$(mktemp -d) || exit 1
if [ -n "$COMSPEC" ]; then
	. "$(dirname "$0")/win32-test.sh"
	FNULL=-fNUL
else
	TEST_SOCKET=tmux-crlf-$(basename "$OUT")
	FNULL=-f/dev/null
fi
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
cleanup() {
	$TMUX kill-server 2>/dev/null
	rm -f "$OUT/"*.conf
	rmdir "$OUT"
}
trap cleanup 0
trap 'exit 1' 1 2 15

fail() {
	echo "FAIL: $*"
	exit 1
}

file_path() {
	if [ -n "$COMSPEC" ]; then
		cygpath -ma "$1"
	else
		printf '%s\n' "$1"
	fi
}

option_is() {
	_value=$($TMUX show -gqv "$1" | tr -d '\r')
	[ "$_value" = "$2" ] || fail "$1: expected <$2>, got <$_value>"
}

check_options() {
	option_is @plain beforeafter
	option_is @double doublequoted
	option_is @single singlequoted
	option_is @even 'two\'
	option_is @next next
	option_is @hidden ''
	option_is @condition if
	option_is @condition-elif elif
	option_is @condition-else else
}

check_bare() {
	[ "$($TMUX display -p '#{==:#{@raw},#{@escaped}}' | tr -d '\r')" = 1 ] ||
	    fail "bare CR changed"
	[ "$($TMUX display -p '#{==:#{@bare},#{@escaped}}' | tr -d '\r')" = 1 ] ||
	    fail "escaped bare CR changed"
	[ "$($TMUX display -p '#{==:#{@dollar},#{@dollar-expected}}' | tr -d '\r')" = 1 ] ||
	    fail "dollar before escaped bare CR changed"
}

cat >"$OUT/lf.conf" <<'EOF'
set -g @plain before\
after
set -g @double "double\
quoted"
set -g @single 'single\
quoted'
set -g @even two\\
set -g @next next
# This comment continues\
set -g @hidden should-not-be-set
%if 1
set -g @condition if
%else
set -g @condition wrong
%endif
%if 0
set -g @condition-elif wrong
%elif 1
set -g @condition-elif elif
%else
set -g @condition-elif wrong
%endif
%if 0
set -g @condition-else wrong
%else
set -g @condition-else else
%endif
EOF
awk '{ printf "%s\r\n", $0 }' "$OUT/lf.conf" >"$OUT/crlf.conf"

for ending in lf crlf; do
	CFG=$(file_path "$OUT/$ending.conf")
	$TMUX $FNULL new -d -s config </dev/null || fail "$ending start"
	$TMUX source-file -n "$CFG" || fail "$ending parse-only"
	option_is @plain ''
	$TMUX source-file "$CFG" || fail "$ending source-file"
	check_options
	$TMUX kill-server
	wait_gone || fail "$ending source server did not exit"

	$TMUX -f "$CFG" new -d -s config </dev/null || fail "$ending startup"
	check_options
	$TMUX kill-server
	wait_gone || fail "$ending startup server did not exit"
	echo "PASS: $ending source-file, parse-only and startup config"
done

# A CR not followed by LF is data, including after an escape or a dollar.
printf 'set -g @raw "left\rright"\nset -g @escaped "left\\rright"\nset -g @bare "left\\\rright"\nset -g @dollar "$\\\rX"\nset -g @dollar-expected "$\\rX"\n' \
    >"$OUT/bare.conf"
$TMUX $FNULL new -d -s config </dev/null || fail "bare CR start"
$TMUX source-file "$(file_path "$OUT/bare.conf")" || fail "bare CR source"
check_bare
$TMUX kill-server
wait_gone || fail "bare CR source server did not exit"
$TMUX -f "$(file_path "$OUT/bare.conf")" new -d -s config </dev/null ||
    fail "bare CR startup"
check_bare

printf 'set -g @valid before\\\r\nafter\r\nno-such-command\r\n' >"$OUT/bad.conf"
ERR=$($TMUX source-file "$(file_path "$OUT/bad.conf")" 2>&1) &&
    fail "bad command exited 0"
case "$ERR" in
	*bad.conf:3:*) ;;
	*) fail "wrong physical line in error: $ERR" ;;
esac

for fixture in regress/conf/*.conf; do
	awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$fixture" >"$OUT/corpus.conf"
	$TMUX source-file -n "$(file_path "$OUT/corpus.conf")" ||
	    fail "CRLF copy of $(basename "$fixture")"
done
echo "ALL CONFIG LINE ENDING TESTS PASSED"
