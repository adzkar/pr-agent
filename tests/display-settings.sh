#!/usr/bin/env bash
# Fixtures for the settings resolver in ./pr-agent: env > saved > default
# precedence, SRC_* provenance, and invalid-input handling. Extracts
# resolve_str/resolve_num/setting_src/load_settings; fake STATE_DIR — no
# GitHub, no terminal, no file mutation. Run from anywhere.
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^resolve_str()/,/^}/p;/^resolve_num()/,/^}/p;/^setting_src()/,/^}/p;/^load_settings()/,/^}/p' \
  "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh STATE_DIR -> source funcs, load_settings, report key display settings
# and the rejection notes. SETTING_NOTES/RES must exist before sourcing.
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
. "$T/funcs.sh"
load_settings
printf 'TABLE_ROWS=%s(%s)\n' "\$TABLE_ROWS" "\$(setting_src TABLE_ROWS)"
printf 'ACTIVITY_LINES=%s(%s)\n' "\$ACTIVITY_LINES" "\$(setting_src ACTIVITY_LINES)"
printf 'TITLE_W=%s(%s)\n' "\$TITLE_W" "\$(setting_src TITLE_W)"
printf 'TITLE_LINES=%s(%s)\n' "\$TITLE_LINES" "\$(setting_src TITLE_LINES)"
printf 'AUTHOR_FILTER=%s(%s)\n' "\${AUTHOR_FILTER:-∅}" "\$(setting_src AUTHOR_FILTER)"
printf 'SKIP_RE=%s(%s)\n' "\$SKIP_RE" "\$(setting_src SKIP_RE)"
printf 'NOTES=%s\n' "\$SETTING_NOTES"
EOF
chmod +x "$T/run.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
cfg() { mkdir -p "$T/$1"; printf '%s\n' "$2" >"$T/$1/config"; echo "$T/$1"; }

echo "== defaults: no config =="
d="$(cfg fresh '')"; rm "$d/config"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES='
eq "all defaults" "$("$T/run.sh" "$d" | paste -sd'|' -)" "$want"

echo "== legacy saved values win over defaults =="
d="$(cfg legacy 'CFG_TITLE_LINES=3
CFG_TABLE_ROWS=0
CFG_TITLE_W=80
CFG_AUTHOR_FILTER=alice')"
want='TABLE_ROWS=0(saved)|ACTIVITY_LINES=6(default)|TITLE_W=80(saved)|TITLE_LINES=3(saved)|AUTHOR_FILTER=alice(saved)|SKIP_RE=in-progress -->(default)|NOTES='
eq "saved provenance" "$("$T/run.sh" "$d" | paste -sd'|' -)" "$want"

echo "== env wins over saved — explicit 0 preserved =="
d="$(cfg env0 'CFG_TITLE_LINES=3')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=0(env)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES='
eq "env zero wins" "$(PR_AGENT_TITLE_LINES=0 "$T/run.sh" "$d" | paste -sd'|' -)" "$want"

echo "== empty env falls through to saved =="
d="$(cfg emptyenv 'CFG_AUTHOR_FILTER=bob')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=bob(saved)|SKIP_RE=in-progress -->(default)|NOTES='
eq "empty env = unset" "$(PR_AGENT_AUTHOR_FILTER='' "$T/run.sh" "$d" | paste -sd'|' -)" "$want"

echo "== invalid env numeric falls to saved, noted, file untouched =="
d="$(cfg badenv 'CFG_TABLE_ROWS=10')"
sum="$(shasum "$d/config" | cut -d' ' -f1)"
want='TABLE_ROWS=10(saved)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES= TABLE_ROWS:env'
eq "invalid env noted" "$(PR_AGENT_TABLE_ROWS=lots "$T/run.sh" "$d" | paste -sd'|' -)" "$want"
eq "config untouched" "$(shasum "$d/config" | cut -d' ' -f1)" "$sum"

echo "== invalid saved numeric falls to default, noted =="
d="$(cfg badcfg 'CFG_TITLE_LINES=wide
CFG_TABLE_ROWS=abc')"
sum="$(shasum "$d/config" | cut -d' ' -f1)"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES= TABLE_ROWS:saved TITLE_LINES:saved'
eq "invalid saved noted" "$("$T/run.sh" "$d" | paste -sd'|' -)" "$want"
eq "config untouched" "$(shasum "$d/config" | cut -d' ' -f1)" "$sum"

echo "== non-numeric string keys pass through untouched =="
d="$(cfg strkeys 'CFG_SKIP_RE=wip
CFG_AUTHOR_FILTER=carol')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=carol(saved)|SKIP_RE=wip(saved)|NOTES='
eq "string keys" "$("$T/run.sh" "$d" | paste -sd'|' -)" "$want"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
