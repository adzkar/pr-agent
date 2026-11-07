#!/usr/bin/env bash
# Fixtures for the settings resolver in ./pr-agent: env > saved > mode/default
# precedence, SRC_* provenance, invalid-input handling, and the config report.
# Extracted functions, fake STATE_DIR — no GitHub, no terminal, no file
# mutation. Run from anywhere.
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^cfg_src()/,/^}/p;/^resolve_str()/,/^}/p;/^resolve_num()/,/^}/p;/^setting_src()/,/^}/p;/^apply_status_defaults()/,/^}/p;/^load_settings()/,/^}/p;/^cmd_config()/,/^}/p;/^save_config()/,/^}/p' \
  "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh STATE_DIR KEY... -> source funcs, load_settings, report each named
# setting as KEY=value(src) plus the rejection notes. SETTING_NOTES/RES must
# exist before sourcing.
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"; shift
SETTING_NOTES='' RES='' RES_SRC=''
DISPLAY_SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
. "$T/funcs.sh"
load_settings
for k in "\$@"; do printf '%s=%s(%s)\n' "\$k" "\${!k:-∅}" "\$(setting_src "\$k")"; done
printf 'NOTES=%s\n' "\$SETTING_NOTES"
EOF

# mode.sh STATE_DIR MODE -> load_settings + apply_status_defaults, report cap
cat >"$T/mode.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
DISPLAY_SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
. "$T/funcs.sh"
load_settings
apply_status_defaults "\$2"
printf 'TITLE_LINES=%s(%s)\n' "\$TITLE_LINES" "\$(setting_src TITLE_LINES)"
EOF

# cfg.sh STATE_DIR -> load_settings + cmd_config report over display keys only
cat >"$T/cfg.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
DISPLAY_SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
repo() { echo owner/repo; }
. "$T/funcs.sh"
load_settings
cmd_config
EOF

# save.sh STATE_DIR [MODE] -> load_settings (+ apply_status_defaults MODE) +
# save_config, then print the config it wrote
cat >"$T/save.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
SETTINGS='INTERVAL TABLE_ROWS TITLE_LINES'
DISPLAY_SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
. "$T/funcs.sh"
load_settings
if [ -n "\${2:-}" ]; then apply_status_defaults "\$2"; fi
save_config
cat "\$STATE_DIR/config"
EOF

# mark.sh STATE_DIR -> load_settings, report INTERVAL+TITLE_LINES provenance —
# pins which keys a CFG_SRC_*=default marker may demote (display keys only)
cat >"$T/mark.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
DISPLAY_SETTINGS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES'
. "$T/funcs.sh"
load_settings
printf 'INTERVAL=%s(%s)\n' "\$INTERVAL" "\$(setting_src INTERVAL)"
printf 'TITLE_LINES=%s(%s)\n' "\$TITLE_LINES" "\$(setting_src TITLE_LINES)"
EOF
chmod +x "$T/run.sh" "$T/mode.sh" "$T/cfg.sh" "$T/save.sh" "$T/mark.sh"

KEYS='TABLE_ROWS ACTIVITY_LINES TITLE_W TITLE_LINES AUTHOR_FILTER SKIP_RE'

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want '$3' in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unwanted '$3' in: $2" ;; *) ok "$1" ;; esac; }
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

echo "== mode defaults: fresh view =="
d="$(cfg modew '')"; rm "$d/config"
eq "watch default uncapped" "$("$T/mode.sh" "$d" watch)"  'TITLE_LINES=0(mode-default)'
eq "plain default three"   "$("$T/mode.sh" "$d" plain)"  'TITLE_LINES=3(mode-default)'

echo "== mode defaults: saved cap stays authoritative =="
d="$(cfg modesaved 'CFG_TITLE_LINES=3')"
eq "saved 3 wins in watch" "$("$T/mode.sh" "$d" watch)"  'TITLE_LINES=3(saved)'
d="$(cfg modesaved1 'CFG_TITLE_LINES=1')"
eq "saved 1 wins in watch" "$("$T/mode.sh" "$d" watch)"  'TITLE_LINES=1(saved)'
d="$(cfg modesaved0 'CFG_TITLE_LINES=0')"
eq "saved 0 wins in plain" "$("$T/mode.sh" "$d" plain)"  'TITLE_LINES=0(saved)'

echo "== mode defaults: env beats mode default too =="
d="$(cfg modeenv '')"; rm "$d/config"
eq "env cap in watch"      "$(PR_AGENT_TITLE_LINES=1 "$T/mode.sh" "$d" watch)" 'TITLE_LINES=1(env)'
eq "env zero in watch"     "$(PR_AGENT_TITLE_LINES=0 "$T/mode.sh" "$d" watch)" 'TITLE_LINES=0(env)'

echo "== config report =="
d="$(cfg cfgreport 'CFG_TITLE_LINES=3
CFG_TABLE_ROWS=10')"
O="$("$T/cfg.sh" "$d")"
has "saved provenance shown"  "$O" '(saved)'
has "default provenance"      "$O" '(default)'
has "truncation discoverable" "$O" 'titles truncate after 3 line(s)'
has "record cap shown"        "$O" 'first 10 PR records'
lacks "no every-record claim" "$O" 'keeps every record'
has "clip still explained"    "$O" 'frame clip'
d="$(cfg cfgopen '')"; rm "$d/config"
O="$("$T/cfg.sh" "$d")"
has "mode default explained"  "$O" 'truncate after 3 line(s) for plain status, uncapped in status -w'
has "all records shown"       "$O" 'all PR records'
has "every-record claim kept" "$O" 'keeps every record'
d="$(cfg cfgnotes 'CFG_TABLE_ROWS=xyz')"
O="$(PR_AGENT_TITLE_LINES=0 "$T/cfg.sh" "$d")"
has "env provenance shown"    "$O" '(env)'
has "invalid input reported"  "$O" 'ignored invalid input: TABLE_ROWS:saved'
has "fallback value shown"    "$O" 'titles uncapped'

echo "== save: only env/saved provenance is pinned =="
d="$(cfg savefresh '')"; rm "$d/config"
O="$("$T/save.sh" "$d")"
has "v2 header"                "$O" '# pr-agent config v2'
eq  "defaults stay unpinned"   "$(printf '%s\n' "$O" | grep -c '^CFG_' || true)" '0'
eq  "mode-default unpinned"    "$("$T/save.sh" "$d" watch | grep -c '^CFG_' || true)" '0'
eq  "env pinned"               "$(PR_AGENT_TITLE_LINES=7 "$T/save.sh" "$d" | grep '^CFG_')" 'CFG_TITLE_LINES=7'
d="$(cfg savelc '')"; rm "$d/config"
"$T/save.sh" "$d" >/dev/null   # a fresh `on` writes no display keys…
eq "watch cap after fresh on"  "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=0(mode-default)'   # …so -w still gets its mode default
d="$(cfg savesaved 'CFG_TITLE_LINES=3')"
eq "saved kept"                "$("$T/save.sh" "$d" | grep '^CFG_')" 'CFG_TITLE_LINES=3'
d="$(cfg savemix 'CFG_TABLE_ROWS=10')"
eq "only saved key written"    "$("$T/save.sh" "$d" | grep '^CFG_')" 'CFG_TABLE_ROWS=10'

echo "== save_config v2 =="
echo "-- CFG_SRC markers demote on read, drop on resave --"
d="$(cfg marked 'CFG_TITLE_LINES=3
CFG_SRC_TITLE_LINES=default')"
eq "marker demotes to mode default (watch)" \
   "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=0(mode-default)'
eq "marker demotes to mode default (plain)" \
   "$("$T/mode.sh" "$d" plain)" 'TITLE_LINES=3(mode-default)'
O="$("$T/save.sh" "$d")"
lacks "stale marker dropped"    "$O" 'CFG_SRC_TITLE_LINES'
lacks "demoted value unpinned"  "$O" 'CFG_TITLE_LINES='

echo "-- env/saved-sourced display keys stay authoritative --"
d="$(cfg saveexp 'CFG_TITLE_LINES=1
CFG_TABLE_ROWS=10')"
O="$("$T/save.sh" "$d")"
has "saved value written"      "$O" 'CFG_TITLE_LINES=1'
has "rows value written"       "$O" 'CFG_TABLE_ROWS=10'
eq "explicit cap survives reload (watch)" \
   "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=1(saved)'
eq "explicit rows survive reload" \
   "$("$T/run.sh" "$d" TABLE_ROWS | grep '^TABLE_ROWS=')" 'TABLE_ROWS=10(saved)'

echo "-- legacy v1 file (no markers): saved cap stays authoritative --"
d="$(cfg v1 'CFG_TITLE_LINES=3')"
eq "legacy 3 wins (watch)" "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=3(saved)'
O="$("$T/save.sh" "$d")"
has "resave upgrades to v2"    "$O" '# pr-agent config v2'
lacks "no marker for saved key" "$O" 'CFG_SRC_TITLE_LINES'
eq "cap survives v1→v2 resave" "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=3(saved)'

echo "-- foreign lines survive a resave --"
d="$(cfg foreign '# hand-added note
CFG_FUTURE=sparkles
CFG_SRC_TITLE_LINES=default
CFG_TITLE_LINES=9')"
O="$("$T/save.sh" "$d")"
has "comment kept"           "$O" '# hand-added note'
has "unknown key kept"       "$O" 'CFG_FUTURE=sparkles'
lacks "stale marker dropped" "$O" 'CFG_SRC_TITLE_LINES'
lacks "demoted value gone"   "$O" 'CFG_TITLE_LINES='

echo "-- CFG_SRC markers govern display keys only --"
d="$(cfg fsrc 'CFG_INTERVAL=45
CFG_SRC_INTERVAL=default
CFG_SRC_FOO2=default
CFG_TITLE_LINES=9
CFG_SRC_TITLE_LINES=default')"
eq "foreign marker inert, display marker demotes" \
   "$("$T/mark.sh" "$d" | paste -sd'|' -)" 'INTERVAL=45(saved)|TITLE_LINES=3(default)'
O="$("$T/save.sh" "$d")"
has "foreign marker cleaned"  "$([ "$O" != "${O/CFG_SRC_INTERVAL/}" ] && echo kept || echo gone)" gone
has "digit marker cleaned"    "$([ "$O" != "${O/CFG_SRC_FOO2/}" ] && echo kept || echo gone)" gone
has "interval value resaved"  "$O" 'CFG_INTERVAL=45'
has "display marker dropped"  "$([ "$O" != "${O/CFG_SRC_TITLE_LINES/}" ] && echo kept || echo gone)" gone
lacks "demoted value unpinned" "$O" 'CFG_TITLE_LINES='
eq "post-resave state pins both" \
   "$("$T/mark.sh" "$d" | paste -sd'|' -)" 'INTERVAL=45(saved)|TITLE_LINES=3(default)'

echo "-- only the tool's own config header is stripped --"
d="$(cfg hdr '# pr-agent config notes
# pr-agent config v9
# pr-agent config')"
O="$("$T/save.sh" "$d")"
has "foreign header comment kept" "$O" '# pr-agent config notes'
eq  "versioned headers managed" \
    "$(printf '%s\n' "$O" | { grep -c '^# pr-agent config v[0-9]' || true; })" 1

echo "-- resave is idempotent --"
d="$(cfg idem '')"; rm "$d/config"
"$T/save.sh" "$d" >/dev/null
first="$(shasum "$d/config" | cut -d' ' -f1)"
"$T/save.sh" "$d" >/dev/null
eq "same file twice" "$(shasum "$d/config" | cut -d' ' -f1)" "$first"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
