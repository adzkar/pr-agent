#!/usr/bin/env bash
# Fixtures for the settings resolver in ./pr-agent: env > saved > mode/default
# precedence, SRC_* provenance, invalid-input handling, and the config report.
# Extracted functions, fake STATE_DIR — no GitHub, no terminal, no file
# mutation. Run from anywhere.
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^resolve_str()/,/^}/p;/^resolve_num()/,/^}/p;/^setting_src()/,/^}/p;/^apply_status_defaults()/,/^}/p;/^load_settings()/,/^}/p;/^cmd_config()/,/^}/p;/^save_config()/,/^}/p' \
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

# mode.sh STATE_DIR MODE -> load_settings + apply_status_defaults, report cap
cat >"$T/mode.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
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
repo() { echo owner/repo; }
. "$T/funcs.sh"
load_settings
cmd_config
EOF

# save.sh STATE_DIR SPECVARS -> set values+SRC_* from \$2 (eval'd), save_config,
# print the resulting file. Simulates `on`-time provenance without a watcher.
cat >"$T/save.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="\$1"
SETTING_NOTES='' RES='' RES_SRC=''
SETTINGS='INTERVAL TABLE_ROWS TITLE_LINES'
DISPLAY_SETTINGS='TABLE_ROWS TITLE_LINES'
INTERVAL=120 TABLE_ROWS=0 TITLE_LINES=3
SRC_INTERVAL=default SRC_TABLE_ROWS=default SRC_TITLE_LINES=default
if [ -n "\${2:-}" ]; then eval "\$2"; fi
. "$T/funcs.sh"
save_config
cat "\$STATE_DIR/config"
EOF
chmod +x "$T/run.sh" "$T/mode.sh" "$T/cfg.sh" "$T/save.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want '$3' in: $2" ;; esac; }
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
d="$(cfg cfgopen '')"; rm "$d/config"
O="$("$T/cfg.sh" "$d")"
has "mode default explained"  "$O" 'truncate after 3 line(s) for plain status, uncapped in status -w'
has "all records shown"       "$O" 'all PR records'
d="$(cfg cfgnotes 'CFG_TABLE_ROWS=xyz')"
O="$(PR_AGENT_TITLE_LINES=0 "$T/cfg.sh" "$d")"
has "env provenance shown"    "$O" '(env)'
has "invalid input reported"  "$O" 'ignored invalid input: TABLE_ROWS:saved'
has "fallback value shown"    "$O" 'titles uncapped'

echo "== save_config v2 =="
echo "-- default-sourced display key gets a CFG_SRC marker --"
d="$(cfg savedef '')"; rm "$d/config"
O="$("$T/save.sh" "$d" 'SRC_TITLE_LINES=default SRC_TABLE_ROWS=default')"
has "v2 header"            "$O" '# pr-agent config v2'
has "title marker"         "$O" 'CFG_SRC_TITLE_LINES=default'
has "rows marker"          "$O" 'CFG_SRC_TABLE_ROWS=default'
eq "marker demotes to mode default (watch)" \
   "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=0(mode-default)'
eq "marker demotes to mode default (plain)" \
   "$("$T/mode.sh" "$d" plain)" 'TITLE_LINES=3(mode-default)'

echo "-- env/saved-sourced display keys stay authoritative --"
d="$(cfg saveexp '')"; rm "$d/config"
O="$("$T/save.sh" "$d" 'TITLE_LINES=1 SRC_TITLE_LINES=saved TABLE_ROWS=10 SRC_TABLE_ROWS=env')"
has "saved value written"     "$O" 'CFG_TITLE_LINES=1'
has "no title marker"         "$([ "$O" != "${O/CFG_SRC_TITLE_LINES/}" ] && echo marker || echo none)" none
has "rows value written"      "$O" 'CFG_TABLE_ROWS=10'
eq "explicit cap survives reload (watch)" \
   "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=1(saved)'
eq "explicit rows survive reload" \
   "$("$T/run.sh" "$d" | grep '^TABLE_ROWS=')" 'TABLE_ROWS=10(saved)'

echo "-- legacy v1 file (no markers): saved cap stays authoritative --"
d="$(cfg v1 'CFG_TITLE_LINES=3')"
eq "legacy 3 wins (watch)" "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=3(saved)'
O="$("$T/save.sh" "$d" 'TITLE_LINES=3 SRC_TITLE_LINES=saved')"
has "resave upgrades to v2"    "$O" '# pr-agent config v2'
has "no marker for saved key"  "$([ "$O" != "${O/CFG_SRC_TITLE_LINES/}" ] && echo marker || echo none)" none
eq "cap survives v1→v2 resave" "$("$T/mode.sh" "$d" watch)" 'TITLE_LINES=3(saved)'

echo "-- foreign lines survive a resave --"
d="$(cfg foreign '# hand-added note
CFG_FUTURE=sparkles
CFG_SRC_TITLE_LINES=default
CFG_TITLE_LINES=9')"
O="$("$T/save.sh" "$d" 'TITLE_LINES=3 SRC_TITLE_LINES=default')"
has "comment kept"          "$O" '# hand-added note'
has "unknown key kept"      "$O" 'CFG_FUTURE=sparkles'
has "stale marker replaced" "$O" 'CFG_SRC_TITLE_LINES=default'
has "managed value resaved" "$O" 'CFG_TITLE_LINES=3'
has "old value gone"        "$([ "$O" != "${O/CFG_TITLE_LINES=9/}" ] && echo stale || echo clean)" clean

echo "-- resave is idempotent --"
d="$(cfg idem '')"; rm "$d/config"
"$T/save.sh" "$d" '' >/dev/null
first="$(shasum "$d/config" | cut -d' ' -f1)"
"$T/save.sh" "$d" '' >/dev/null
eq "same file twice" "$(shasum "$d/config" | cut -d' ' -f1)" "$first"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
