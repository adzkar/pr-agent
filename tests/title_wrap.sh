#!/usr/bin/env bash
# Fixtures for wrap() in ./pr-agent — the word-wrap behind the status TITLE
# column's multi-line cells. Extracts trunc + wrap; no GitHub, no terminal.
# Run from anywhere: tests/title_wrap.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^trunc()/,/^}/p;/^wrap()/,/^}/p' "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh TEXT WIDTH MAX -> source funcs, wrap, print WRAP_LINES one per line
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=en_US.UTF-8   # force \${#var} to count multibyte chars, not bytes
WRAP_LINES=()
. "$T/funcs.sh"
wrap "\$1" "\$2" "\$3"
printf '%s\n' "\${WRAP_LINES[@]}"
EOF
chmod +x "$T/run.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }

# try NAME WANT -- TEXT WIDTH MAX: want is the wrapped lines |-joined
try() {
  local name="$1" want="$2" got
  shift 2
  got="$("$T/run.sh" "$1" "$2" "$3" | paste -sd'|' -)"
  eq "$name" "$got" "$want"
}

echo "== basic wrapping =="
try "short title, one line"        "short"                        "short" 20 3
try "exact fit"                    "1234567890"                   "1234567890" 10 3
try "empty -> one blank line"      ""                             "" 10 3
try "splits at word boundary"      "alpha|beta"                   "alpha beta" 9 3
try "word join shares a line"      "alpha beta|gamma"             "alpha beta gamma" 12 3
try "word exactly fills next line" "aaa|bbb"                      "aaa bbb" 3 3

echo "== hard splits (word longer than width) =="
try "long word splits"             "abcd|efgh|ij"                 "abcdefghij" 4 0
try "split continues with words"   "abcd|ef|zz"                   "abcdef zz" 4 0
try "long word after short line"   "ab|cdcd|efgh"                 "ab cdcdefgh" 4 0

echo "== max cap =="
try "under cap stays"              "a|b"                          "a b" 1 3
try "cap folds rest into …"        "a|bcdefghij|klmn op q…"       "a bcdefghij klmn op qr st" 10 3
try "cap 1 = truncate"             "one two t…"                   "one two three" 10 1
try "cap 0 = no cap"               "a|a|a|a|a"                    "a a a a a" 1 0
try "… lands on last allowed line" "aaa bbb|ccc ddd e…"           "aaa bbb ccc ddd eee" 10 2

echo "== hostile input =="
try "glob chars kept literally"    "a * ? [x]|y"                  "a * ? [x] y" 10 0
try "tabs collapse to spaces"      "a|b|c"                        "$(printf 'a\tb\tc')" 1 0
try "runs of spaces collapse"      "a b|c"                        "a   b     c" 3 0
try "unicode counts as chars"      "café|ドキュメン…"              "café ドキュメントいタイトル" 6 2

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
