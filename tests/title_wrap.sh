#!/usr/bin/env bash
# Fixtures for wrap() in ./pr-agent — the word-wrap behind the status TITLE
# column's multi-line cells. Extracts trunc + wrap; no GitHub, no terminal.
# Run from anywhere: tests/title_wrap.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^cell_ops()/,/^}/p;/^cell_len()/,/^}/p;/^trunc()/,/^}/p;/^wrap()/,/^}/p' "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh TEXT W MAX -> source funcs, wrap at one logical cell width, print
# "FULL=<uncapped lines>" then WRAP_LINES with per-line cell widths as [w]
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=en_US.UTF-8   # force \${#var} to count multibyte chars, not bytes
WRAP_LINES=() WRAP_FULL=0 WRAP_W=()
. "$T/funcs.sh"
wrap "\$1" "\$2" "\$3"
printf 'FULL=%s\n' "\$WRAP_FULL"
for i in "\${!WRAP_LINES[@]}"; do printf '[%s]%s\n' "\${WRAP_W[i]}" "\${WRAP_LINES[i]}"; done
EOF
chmod +x "$T/run.sh"

# runc.sh — same, but under LC_ALL=C: wrap pins its own UTF-8 ctype, so the C
# ambient must produce identical (codepoint-sliced, never byte-sliced) output
sed 's/export LC_ALL=en_US.UTF-8.*/export LC_ALL=C   # hostile ambient — wrap self-pins UTF-8/' \
  "$T/run.sh" >"$T/runc.sh"
chmod +x "$T/runc.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }

# try NAME WANT -- TEXT W MAX: want is FULL=n then the wrapped lines |-joined,
# each line prefixed [w] with its display-cell width
try() {
  local name="$1" want="$2" got
  shift 2
  got="$("$T/run.sh" "$@" | paste -sd'|' -)"
  eq "$name" "$got" "$want"
}

echo "== basic wrapping =="
try "short title, one line"        "FULL=1|[5]short"                  "short" 20 3
try "exact fit"                    "FULL=1|[10]1234567890"            "1234567890" 10 3
try "empty -> one blank line"      "FULL=1|[0]"                       "" 10 3
try "splits at word boundary"      "FULL=2|[5]alpha|[4]beta"          "alpha beta" 9 3
try "word join shares a line"      "FULL=2|[10]alpha beta|[5]gamma"   "alpha beta gamma" 12 3
try "word exactly fills next line" "FULL=2|[3]aaa|[3]bbb"             "aaa bbb" 3 3

echo "== hard splits (word longer than width) =="
try "long word splits"             "FULL=3|[4]abcd|[4]efgh|[2]ij"     "abcdefghij" 4 0
try "split continues with words"   "FULL=3|[4]abcd|[2]ef|[2]zz"       "abcdef zz" 4 0
try "long word after short line"   "FULL=3|[2]ab|[4]cdcd|[4]efgh"     "ab cdcdefgh" 4 0

echo "== max cap =="
try "under cap stays"              "FULL=2|[1]a|[1]b"                 "a b" 1 3
try "cap folds rest into …"        "FULL=4|[1]a|[9]bcdefghij|[10]klmn op q…" "a bcdefghij klmn op qr st" 10 3
try "cap 1 = truncate"             "FULL=2|[10]one two t…"            "one two three" 10 1
try "cap 0 = no cap"               "FULL=5|[1]a|[1]a|[1]a|[1]a|[1]a"  "a a a a a" 1 0
try "… lands on last allowed line" "FULL=3|[7]aaa bbb|[10]ccc ddd e…" "aaa bbb ccc ddd eee" 10 2
try "FULL stays uncapped"          "FULL=5|[1]a|[1]b|[1]…"            "a b c d e" 1 3

echo "== width guards =="
try "w <= 0 floors to 1"           "FULL=3|[1]a|[1]b|[1]c"            "abc" 0 0

echo "== hostile input =="
try "glob chars kept literally"    "FULL=2|[9]a * ? [x]|[1]y"           "a * ? [x] y" 10 0
try "tabs collapse to spaces"      "FULL=3|[1]a|[1]b|[1]c"            "$(printf 'a\tb\tc')" 1 0
try "runs of spaces collapse"      "FULL=2|[3]a b|[1]c"               "a   b     c" 3 0

echo "== display cells (CJK 2, combining 0) =="
try "cjk counts cells"             "FULL=3|[4]café|[12]ドキュメン …" "café ドキュメントいタイトル" 12 2
try "combining mark joins"         "FULL=1|[2]$(printf 'e\xcc\x81x')" "$(printf 'e\xcc\x81x')" 10 0
try "wide char straddles split"    "FULL=2|[4]aaド|[3]ドb"            "aaドドb" 5 0
try "wide word fills exactly"      "FULL=1|[10]ドキュメン"           "ドキュメン" 10 0

echo "== C ambient locale: wrap still counts codepoints =="
tryc() {
  local name="$1" want="$2" got
  shift 2
  got="$("$T/runc.sh" "$@" | paste -sd'|' -)"
  eq "$name" "$got" "$want"
}
tryc "cjk under LC_ALL=C"            "FULL=3|[4]café|[12]ドキュメン …" "café ドキュメントいタイトル" 12 2
tryc "wide char straddles under C"   "FULL=2|[4]aaド|[3]ドb"            "aaドドb" 5 0
tryc "ascii identical under C"       "FULL=2|[5]alpha|[4]beta"          "alpha beta" 9 3

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
