#!/bin/sh

# play-sound runs the platform's player from the server, without waiting, and a
# new sound stops the one playing. Each call leaves an info line in tmux's log,
# played or held back with -s (TMUX-168), and none at error level, which marks
# only failures (TMUX-169). Windows has its own check in win32-caller.sh.

TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-play-sound"
$TMUX kill-server 2>/dev/null

DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; rm -rf "$DIR"' 0 1 15
mkdir "$DIR/bin" "$DIR/empty" "$DIR/log" "$DIR/events"
TMUX_LOG=$DIR/tmux.log
export TMUX_LOG
: >"$DIR/one.wav"
: >"$DIR/two.wav"
: >"$DIR/three.wav"

case $(uname) in
Darwin) player=afplay ;;
*) player=pw-play ;;
esac
cat >"$DIR/bin/$player" <<SCRIPT
#!/bin/sh
trap 'echo "stopped \$1" >>"$DIR/played"; exit 0' TERM
echo "started \$1" >>"$DIR/played"
case \$1 in
*one.wav) sleep 10 & wait ;;
esac
SCRIPT
chmod +x "$DIR/bin/$player"

fail() {
	echo "play-sound: $1" >&2
	exit 1
}

wait_for() {
	i=0
	while [ $i -lt 50 ]; do
		grep -q "$1" "$DIR/played" 2>/dev/null && return 0
		i=$((i + 1))
		sleep 0.1
	done
	fail "never saw \"$1\" in: $(cat "$DIR/played" 2>/dev/null)"
}

$TMUX -f/dev/null new -d -x 80 -y 24 || exit 1
$TMUX set-environment -g PATH "$DIR/bin:/bin:/usr/bin"

out=$($TMUX play-sound "$DIR/missing.wav" 2>&1) && fail "a missing file succeeded"
echo "$out" | grep -q "can't read" || fail "wrong error: $out"

$TMUX play-sound "$DIR/one.wav" || fail "the first sound failed"
wait_for "started $DIR/one.wav"
$TMUX play-sound "$DIR/two.wav" || fail "the second sound failed"
wait_for "stopped $DIR/one.wav"
wait_for "started $DIR/two.wav"
grep -q " info sound played path=$DIR/two.wav socket=" "$DIR/tmux.log" ||
	fail "no record of the sound played: $(cat "$DIR/tmux.log")"

# -s plays nothing and records why, as a format for the target.
$TMUX set -w @hold 'landing x #1'
$TMUX play-sound -t: -s 'held: #{@hold}' "$DIR/one.wav" || fail "-s failed"
$TMUX play-sound -t: "$DIR/three.wav" || fail "a sound for a window failed"
wait_for "started $DIR/three.wav"
[ "$(grep -c "started $DIR/one.wav" "$DIR/played")" = 1 ] ||
	fail "-s played the sound: $(cat "$DIR/played")"
grep -q " info sound not played path=$DIR/one.wav window=@0 window_name=.* why=\"held: landing x #1\" " "$DIR/tmux.log" ||
	fail "no record of the sound held back: $(cat "$DIR/tmux.log")"
grep -q " info sound played path=$DIR/three.wav window=@0 " "$DIR/tmux.log" ||
	fail "no record of the window's sound: $(cat "$DIR/tmux.log")"
grep -q " error sound \(not \)\{0,1\}played" "$DIR/tmux.log" &&
	fail "a sound played or held back is logged as an error: $(cat "$DIR/tmux.log")"
grep -q " error command failed command=play-sound error=\"can't read $DIR/missing.wav" "$DIR/tmux.log" ||
	fail "a sound that failed is not logged as an error: $(cat "$DIR/tmux.log")"

$TMUX set-environment -g PATH "$DIR/empty"
out=$($TMUX play-sound "$DIR/two.wav" 2>&1) && fail "no player succeeded"
echo "$out" | grep -q "no sound player" || fail "wrong error: $out"

exit 0
