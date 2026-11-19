#!/bin/sh

# The conversation strip's built-in formats, drawn by an attached client. Its usage
# part (ATC-96) is drawn with its own style, measured by the width it draws, and
# dropped whole, never cut, before the PR or the work package would be cut short;
# the narrow layout never shows it. The CI part (AGT-43) is drawn before the usage
# part, with its own style, and dropped whole the same way, before the usage part is.
PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF
# Through a file: a command line would not carry the UTF-8 whole.
cat >"$OUT/strip.conf" <<'EOF'
set -p -t %0 @claude-session s1
set -p -t %0 @strip-active s1
set -p -t %0 @strip-who nelson
set -p -t %0 @strip-pr "repo ##12 · open"
set -p -t %0 @strip-pr-colour "#8A9199"
set -p -t %0 @strip-ticket HOMECFG-238
set -p -t %0 @strip-more "+4 ›"
EOF
cat >"$OUT/usage.conf" <<'EOF'
set -p -t %0 @strip-usage '105k/1M ctx · $0.97 │ #[fg=#F07178]week 100%#[fg=default] · resets Wed 7:59am'
EOF
USAGE='105k/1M ctx · $0.97 │ week 100% · resets Wed 7:59am'
cat >"$OUT/ci.conf" <<'EOF2'
set -p -t %0 @strip-ci '#[range=user|ci]CI 4 running · #[fg=#FFAD66]9 waiting, oldest 25m#[fg=default] · 3 queued to merge#[norange]'
EOF2
CI='CI 4 running · 9 waiting, oldest 25m · 3 queued to merge'

$TMUX -f "$OUT/test.conf" new -d -s strip -x 120 -y 10 </dev/null || exit 1
$OUTER -f "$OUT/outer.conf" new -d -x 120 -y 10 </dev/null || exit 1
wait_ready strip || exit 1
$TMUX source-file "$(cygpath -w "$OUT/strip.conf")" || exit 1
$OUTER send-keys "set TMUX=" Enter "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach -t strip" Enter
attached() { [ "$($TMUX list-clients | wc -l)" = 1 ]; }
wait_until attached || exit 1

row() { $OUTER capture-pane -p | tr -d '\r' | tail -1 | sed 's/ *$//'; }
styled() { $OUTER capture-pane -p -e | tr -d '\r' | tail -1; }
width() {
    $OUTER resize-window -x "$1"
    at_width() { [ "$($TMUX display -p -t %0 '#{pane_width}' | tr -d '\r')" = "$1" ]; }
    wait_until at_width "$1" || { echo "the pane did not reach width $1"; exit 1; }
}
usage() {
    if [ "$1" = on ]; then
        $TMUX source-file "$(cygpath -w "$OUT/usage.conf")" || exit 1
    else
        $TMUX set -pu -t %0 @strip-usage
    fi
}
ci() {
    if [ "$1" = on ]; then
        $TMUX source-file "$(cygpath -w "$OUT/ci.conf")" || exit 1
    else
        $TMUX set -pu -t %0 @strip-ci
    fi
}
row_is() { [ "$(row)" = "$1" ]; }
# Whether the format, at the pane's width now, draws the usage part: a captured
# row can still be the last width's when it fits in this one too.
shown() { [ "$($TMUX display -p -t %0 '#{E:@us-on}' | tr -d '\r')" = "$1" ]; }

WIDE=' nelson │ repo #12 · open │ HOMECFG-238 │ +4 ›'
WIDE_US=" nelson │ repo #12 · open │ HOMECFG-238 │ $USAGE │ +4 ›"
width 120
wait_until row_is "$WIDE" || { echo "the strip is not drawn: '$(row)'"; exit 1; }
usage on
wait_until row_is "$WIDE_US" || { echo "a wide strip has no usage: '$(row)'"; exit 1; }
styled | grep -q "$(printf '\033')\[38;2;240;113;120mweek 100%" ||
    { echo 'the usage part has lost its style'; styled | od -c | head; exit 1; }
echo 'PASS: a wide strip shows the usage part, its style drawn'

# The usage part takes its drawn 51 columns and a separator, 54; the PR wants 15+2
# and the work package, longer than the 10 columns it can be cut to, 11+2. At 119
# the who part is 19 and what is left, 119-19-4-12 = 84, is exactly 54+17+13; at 118
# it is one short, where keeping only the work package's 10 would still show usage.
# Counting the style bytes (81 columns) would drop it 30 columns sooner.
width 119
shown 1 && wait_until row_is "$WIDE_US" ||
    { echo "at its narrowest the usage part is cut or missing: '$(row)'"; exit 1; }
width 118
shown 0 && wait_until row_is "$WIDE" ||
    { echo "a strip too narrow for it still shows the usage part: '$(row)'"; exit 1; }
usage off
wait_until row_is "$WIDE" || { echo "dropping usage changed the row: '$(row)'"; exit 1; }
echo 'PASS: the usage part is dropped whole, and the PR and ticket are as without it'

width 80
usage on
shown 0 && wait_until row_is "$WIDE" || { echo "an 80-column strip shows the usage part: '$(row)'"; exit 1; }
width 30
shown 0 || { echo 'the narrow layout budgets the usage part'; exit 1; }
narrow() { row | grep -q '›$' && ! row | grep -q 'ctx'; }
wait_until narrow || { echo "the narrow strip shows the usage part: '$(row)'"; exit 1; }
echo 'PASS: narrower strips do not show it'

# The CI part takes its 56 columns and a separator, 59. Alone, at 125 the who part is
# 20 and what is left, 125-20-4-12 = 89, is exactly 59+17+13; at 124 it is one short.
usage off
ci_shown() { [ "$($TMUX display -p -t %0 '#{E:@ci-on}' | tr -d '\r')" = "$1" ]; }
WIDE_CI=" nelson │ repo #12 · open │ HOMECFG-238 │ $CI │ +4 ›"
width 125
ci on
ci_shown 1 && wait_until row_is "$WIDE_CI" || { echo "a wide strip has no CI part: '$(row)'"; exit 1; }
styled | grep -q "$(printf '\033')\[38;2;255;173;102m9 waiting, oldest 25m" ||
    { echo 'the CI part has lost its style'; styled | od -c | head; exit 1; }
echo 'PASS: a wide strip shows the CI part, its style drawn'
width 124
ci_shown 0 && wait_until row_is "$WIDE" || { echo "a strip too narrow for it still shows the CI part: '$(row)'"; exit 1; }
echo 'PASS: the CI part is dropped whole, and the PR and ticket are as without it'

# With the usage part too, both fit from 181: the who part is 22 and 181-22-4-12 = 143
# is 54+59+17+13. At 180 the CI part goes first and the usage part stays.
usage on
width 181
WIDE_BOTH=" nelson │ repo #12 · open │ HOMECFG-238 │ $CI │ $USAGE │ +4 ›"
ci_shown 1 && shown 1 && wait_until row_is "$WIDE_BOTH" ||
    { echo "a strip wide for both lacks one: '$(row)'"; exit 1; }
width 180
ci_shown 0 && shown 1 && wait_until row_is "$WIDE_US" ||
    { echo "one column short, the CI part didn't go before the usage part: '$(row)'"; exit 1; }
echo 'PASS: the CI part is drawn before the usage part and dropped before it'
width 30
ci_shown 0 || { echo 'the narrow layout budgets the CI part'; exit 1; }
narrow_ci() { row | grep -q '›$' && ! row | grep -q 'queued'; }
wait_until narrow_ci || { echo "the narrow strip shows the CI part: '$(row)'"; exit 1; }
echo 'PASS: the narrow strip does not show the CI part'

echo 'ALL STRIP TESTS PASSED'
exit 0
