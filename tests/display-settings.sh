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

# run.sh STATE_DIR KEY... -> source funcs, load_settings, report each named
# setting as KEY=value(src) plus the rejection notes. SETTING_NOTES/RES must
# exist before sourcing.
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"; shift
SETTING_NOTES='' RES='' RES_SRC=''
. "$T/funcs.sh"
load_settings
for k in "\$@"; do printf '%s=%s(%s)\n' "\$k" "\${!k:-∅}" "\$(setting_src "\$k")"; done
printf 'NOTES=%s\n' "\$SETTING_NOTES"
EOF
chmod +x "$T/run.sh"

KEYS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES AUTHOR_FILTER SKIP_RE'

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
cfg() { mkdir -p "$T/$1"; printf '%s\n' "$2" >"$T/$1/config"; echo "$T/$1"; }

echo "== defaults: no config =="
d="$(cfg fresh '')"; rm "$d/config"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES='
eq "all defaults" "$("$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"

echo "== legacy saved values win over defaults =="
d="$(cfg legacy 'CFG_TITLE_LINES=3
CFG_TABLE_ROWS=0
CFG_TITLE_W=80
CFG_AUTHOR_FILTER=alice')"
want='TABLE_ROWS=0(saved)|ACTIVITY_LINES=6(default)|TITLE_W=80(saved)|TITLE_LINES=3(saved)|AUTHOR_FILTER=alice(saved)|SKIP_RE=in-progress -->(default)|NOTES='
eq "saved provenance" "$("$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"

echo "== env wins over saved — explicit 0 preserved =="
d="$(cfg env0 'CFG_TITLE_LINES=3')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=0(env)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES='
eq "env zero wins" "$(PR_AGENT_TITLE_LINES=0 "$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"

echo "== empty env falls through to saved =="
d="$(cfg emptyenv 'CFG_AUTHOR_FILTER=bob')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=bob(saved)|SKIP_RE=in-progress -->(default)|NOTES='
eq "empty env = unset" "$(PR_AGENT_AUTHOR='' "$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"

echo "== documented env names that differ from PR_AGENT_<SETTING> resolve =="
d="$(cfg envnames '')"; rm "$d/config"
want='PERM_MODE=safe(env)|AUTHOR_FILTER=alice(env)|PR_AUTHOR_FILTER=@all(env)|CI_TRIGGER=1(env)|CONFLICT_TRIGGER=1(env)|SETUP_CMD=make setup(env)|NOTES='
eq "renamed env vars" "$(env PR_AGENT_MODE=safe PR_AGENT_AUTHOR=alice PR_AGENT_PR_AUTHOR=@all PR_AGENT_CI=1 PR_AGENT_CONFLICTS=1 PR_AGENT_SETUP='make setup' "$T/run.sh" "$d" PERM_MODE AUTHOR_FILTER PR_AUTHOR_FILTER CI_TRIGGER CONFLICT_TRIGGER SETUP_CMD | paste -sd'|' -)" "$want"

echo "== derived PR_AGENT_<SETTING> names are NOT read — documented names only =="
d="$(cfg derived '')"; rm "$d/config"
want='PERM_MODE=dangerous(default)|AUTHOR_FILTER=∅(default)|PR_AUTHOR_FILTER=@me(default)|CI_TRIGGER=0(default)|CONFLICT_TRIGGER=0(default)|SETUP_CMD=∅(default)|NOTES='
eq "derived names ignored" "$(env PR_AGENT_PERM_MODE=safe PR_AGENT_AUTHOR_FILTER=alice PR_AGENT_PR_AUTHOR_FILTER=@all PR_AGENT_CI_TRIGGER=1 PR_AGENT_CONFLICT_TRIGGER=1 PR_AGENT_SETUP_CMD='make setup' "$T/run.sh" "$d" PERM_MODE AUTHOR_FILTER PR_AUTHOR_FILTER CI_TRIGGER CONFLICT_TRIGGER SETUP_CMD | paste -sd'|' -)" "$want"

echo "== invalid env numeric falls to saved, noted, file untouched =="
d="$(cfg badenv 'CFG_TABLE_ROWS=10')"
sum="$(shasum "$d/config" | cut -d' ' -f1)"
want='TABLE_ROWS=10(saved)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES= TABLE_ROWS:env'
eq "invalid env noted" "$(PR_AGENT_TABLE_ROWS=lots "$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"
eq "config untouched" "$(shasum "$d/config" | cut -d' ' -f1)" "$sum"

echo "== invalid saved numeric falls to default, noted =="
d="$(cfg badcfg 'CFG_TITLE_LINES=wide
CFG_TABLE_ROWS=abc')"
sum="$(shasum "$d/config" | cut -d' ' -f1)"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=∅(default)|SKIP_RE=in-progress -->(default)|NOTES= TABLE_ROWS:saved TITLE_LINES:saved'
eq "invalid saved noted" "$("$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"
eq "config untouched" "$(shasum "$d/config" | cut -d' ' -f1)" "$sum"

echo "== non-numeric string keys pass through untouched =="
d="$(cfg strkeys 'CFG_SKIP_RE=wip
CFG_AUTHOR_FILTER=carol')"
want='TABLE_ROWS=0(default)|ACTIVITY_LINES=6(default)|TITLE_W=0(default)|TITLE_LINES=3(default)|AUTHOR_FILTER=carol(saved)|SKIP_RE=wip(saved)|NOTES='
eq "string keys" "$("$T/run.sh" "$d" $KEYS | paste -sd'|' -)" "$want"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
