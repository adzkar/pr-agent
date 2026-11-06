#!/usr/bin/env bash
# Fixtures for wrap() in ./pr-agent — the word-wrap behind the status TITLE
# column's multi-line cells. Extracts trunc + wrap; no GitHub, no terminal.
# Run from anywhere: tests/title_wrap.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^trunc()/,/^}/p;/^wrap()/,/^}/p' "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh TEXT W1 MAX [W2] -> source funcs, wrap (line 1 at W1, continuations
# at W2, defaulting to W1), print "FULL=<uncapped lines>" then WRAP_LINES
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=en_US.UTF-8   # force \${#var} to count multibyte chars, not bytes
WRAP_LINES=() WRAP_FULL=0
. "$T/funcs.sh"
wrap "\$1" "\$2" "\$3" "\${4:-\$2}"
printf 'FULL=%s\n' "\$WRAP_FULL"
printf '%s\n' "\${WRAP_LINES[@]}"
EOF
chmod +x "$T/run.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }

# try NAME WANT -- TEXT W1 MAX [W2]: want is FULL=n then the wrapped lines |-joined
try() {
  local name="$1" want="$2" got
  shift 2
  got="$("$T/run.sh" "$@" | paste -sd'|' -)"
  eq "$name" "$got" "$want"
}

echo "== basic wrapping =="
try "short title, one line"        "FULL=1|short"                     "short" 20 3
try "exact fit"                    "FULL=1|1234567890"                "1234567890" 10 3
try "empty -> one blank line"      "FULL=1|"                          "" 10 3
try "splits at word boundary"      "FULL=2|alpha|beta"                "alpha beta" 9 3
try "word join shares a line"      "FULL=2|alpha beta|gamma"          "alpha beta gamma" 12 3
try "word exactly fills next line" "FULL=2|aaa|bbb"                   "aaa bbb" 3 3

echo "== hard splits (word longer than width) =="
try "long word splits"             "FULL=3|abcd|efgh|ij"              "abcdefghij" 4 0
try "split continues with words"   "FULL=3|abcd|ef|zz"                "abcdef zz" 4 0
try "long word after short line"   "FULL=3|ab|cdcd|efgh"              "ab cdcdefgh" 4 0

echo "== max cap =="
try "under cap stays"              "FULL=2|a|b"                       "a b" 1 3
try "cap folds rest into …"        "FULL=4|a|bcdefghij|klmn op q…"    "a bcdefghij klmn op qr st" 10 3
try "cap 1 = truncate"             "FULL=2|one two t…"                "one two three" 10 1
try "cap 0 = no cap"               "FULL=5|a|a|a|a|a"                 "a a a a a" 1 0
try "… lands on last allowed line" "FULL=3|aaa bbb|ccc ddd e…"        "aaa bbb ccc ddd eee" 10 2
try "FULL stays uncapped"          "FULL=5|a|b|…"                     "a b c d e" 1 3

echo "== continuation width (W2) =="
try "cont lines use W2"            "FULL=3|alpha beta|gamma delta|epsilon" "alpha beta gamma delta epsilon" 10 3 15
try "W2 lets words join"           "FULL=3|one|two three|four"        "one two three four" 3 0 10
try "cap fold measures at W2"      "FULL=3|a bc|def ghij klm n…"      "a bc def ghij klm nop qrs" 5 2 15
try "W2 default = W1"              "FULL=2|aaa|bbb"                   "aaa bbb" 3 0

echo "== hostile input =="
try "glob chars kept literally"    "FULL=2|a * ? [x]|y"               "a * ? [x] y" 10 0
try "tabs collapse to spaces"      "FULL=3|a|b|c"                     "$(printf 'a\tb\tc')" 1 0
try "runs of spaces collapse"      "FULL=2|a b|c"                     "a   b     c" 3 0
try "unicode counts as chars"      "FULL=3|café|ドキュメン…"           "café ドキュメントいタイトル" 6 2

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
