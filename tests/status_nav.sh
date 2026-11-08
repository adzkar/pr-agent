#!/usr/bin/env bash
# Fixtures for the status -w navigation internals in ./pr-agent — the key
# decoder (status_key/keybuf_drain), offset math (key_nav), the scroll
# re-anchoring helpers (status_anchor/anchor_update), and _layout's viewport
# geometry (voff/vreg/max_voff/max_hoff). No GitHub, no terminal: decoder
# bytes arrive via pipes, geometry via handcrafted snapshots.
# Run from anywhere: tests/status_nav.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^keybuf_drain()/,/^}/p;/^status_key()/,/^}/p;/^key_nav()/,/^}/p;
        /^status_anchor()/,/^}/p;/^anchor_update()/,/^}/p' \
  "$REPO/pr-agent" >"$T/funcs.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }

# --- key decoder ------------------------------------------------------------
# decode BYTES -> KEY (one call per keypress; KEYBUF carries sequence bytes
# between calls so ESC+q keeps q)
cat >"$T/decode.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
KEYBUF=''; KEY=none; KEY_EOF_S=''; KEY_EOF_N=0; WATCH_RESIZE=0
. "$T/funcs.sh"
status_key < <(printf '%b' "\$1")
printf '%s\n' "\$KEY"
EOF
chmod +x "$T/decode.sh"

deq() { eq "$1" "$("$T/decode.sh" "$2")" "$3"; }
deq 'up arrow'        '\e[A'   up
deq 'down arrow'      '\e[B'   down
deq 'right arrow'     '\e[C'   right
deq 'left arrow'      '\e[D'   left
deq 'SS3 up'          '\eOA'   up
deq 'SS3 down'        '\eOB'   down
deq 'SS3 right'       '\eOC'   right
deq 'SS3 left'        '\eOD'   left
deq 'SS3 home'        '\eOH'   top
deq 'SS3 end'         '\eOF'   bot
deq 'CSI home H'      '\e[H'   top
deq 'CSI end F'       '\e[F'   bot
deq 'CSI home 1~'     '\e[1~'  top
deq 'CSI home 7~'     '\e[7~'  top
deq 'CSI end 4~'      '\e[4~'  bot
deq 'CSI end 8~'      '\e[8~'  bot
deq 'pgup 5~'         '\e[5~'  pgup
deq 'pgdn 6~'         '\e[6~'  pgdn
deq 'ctrl-up 1;5A'    '\e[1;5A' up
deq 'alt-down 1;3B'   '\e[1;3B' down
deq 'k'               'k'      up
deq 'j'               'j'      down
deq 'h'               'h'      left
deq 'l'               'l'      right
deq 'g'               'g'      top
deq 'G'               'G'      bot
deq '0'               '0'      hmin
deq 'dollar key'       '$'      hmax
deq 'q'               'q'      quit
deq 'unknown key'     'x'      none
deq 'lone ESC'        '\e'     none
deq 'unknown CSI ~'   '\e[3~'  none
deq 'shift-tab'       '\e[Z'   none
deq 'partial seq EOF' '\e[5'   none
deq 'bare CSI ltr'    '\e[q'   none

# ESC+q across two calls: q stays queued and quits
OUT="$(/bin/bash -c 'set -uo pipefail
  KEYBUF=""; KEY=none; KEY_EOF_S=""; KEY_EOF_N=0; WATCH_RESIZE=0
  . "'"$T"'/funcs.sh"
  status_key < <(printf "\eq"); printf "%s," "$KEY"
  status_key < /dev/null; printf "%s" "$KEY"')"
eq 'ESC then q still quits' "$OUT" 'none,quit'

# an unrecognized CSI/SS3 final is requeued — it returns none, then dispatches
# as its own key on the next call (ESC[q still quits, ESC[j scrolls)
for spec in '\e[q|none,quit' '\eOq|none,quit' '\e[j|none,down'; do
  bytes="${spec%%|*}"; want="${spec##*|}"
  OUT="$(/bin/bash -c 'set -uo pipefail
    KEYBUF=""; KEY=none; KEY_EOF_S=""; KEY_EOF_N=0; WATCH_RESIZE=0
    . "'"$T"'/funcs.sh"
    status_key < <(printf "'"$bytes"'"); printf "%s," "$KEY"
    status_key < /dev/null; printf "%s" "$KEY"')"
  eq "unknown final $bytes requeues" "$OUT" "$want"
done

# EOF: instantaneous failures burst → eof once the threshold is hit
OUT="$(/bin/bash -c 'set -uo pipefail
  KEYBUF=""; KEY=none; KEY_EOF_S=""; KEY_EOF_N=0; WATCH_RESIZE=0
  . "'"$T"'/funcs.sh"
  for i in 1 2 3 4 5 6 7; do status_key </dev/null; done
  printf "%s" "$KEY"')"
eq 'EOF burst -> eof' "$OUT" 'eof'

# --- key_nav offsets ----------------------------------------------------------
cat >"$T/knav.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
ST_VREG=6; ST_MAXVOFF=40; ST_MAXHOFF=20
. "$T/funcs.sh"
voff=\$2; hoff=\$3
key_nav "\$1" && printf '%s %s\n' "\$voff" "\$hoff" || echo none
EOF
chmod +x "$T/knav.sh"

eq 'down +1 vline'        "$("$T/knav.sh" down  5 3)"  '6 3'
eq 'up -1 vline'          "$("$T/knav.sh" up    5 3)"  '4 3'
eq 'right +1 cell'        "$("$T/knav.sh" right 5 3)"  '5 4'
eq 'left -1 cell'         "$("$T/knav.sh" left  5 3)"  '5 2'
eq 'pgdn = vreg-1 lines'  "$("$T/knav.sh" pgdn  5 3)"  '10 3'
eq 'pgup = vreg-1 lines'  "$("$T/knav.sh" pgup  5 3)"  '0 3'
eq 'pgdn below 0 ok'      "$("$T/knav.sh" pgup  2 3)"  '-3 3'
eq 'top keeps hoff'       "$("$T/knav.sh" top   9 7)"  '0 7'
eq 'bot = max_voff'       "$("$T/knav.sh" bot   9 7)"  '40 7'
eq 'hmin = 0'             "$("$T/knav.sh" hmin  9 7)"  '9 0'
eq 'hmax = max_hoff'      "$("$T/knav.sh" hmax  9 7)"  '9 20'
eq 'none passes through'  "$("$T/knav.sh" none  9 7)"  'none'
eq 'quit passes through'  "$("$T/knav.sh" quit  9 7)"  'none'

# --- status_anchor -------------------------------------------------------------
# anch ANCHOR_PR ANCHOR_D OLD_H OLDORDER PREV_VOFF -> resolved voff
# ST_REC_* describe the NEW build: recs 101/102/103 at body lines 0/3/6 with
# record heights 3/2/4
cat >"$T/anch.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
ST_REC_N=(101 102 103); ST_REC_B=(0 3 6); ST_REC_C=(3 2 4)
. "$T/funcs.sh"
status_anchor "\$@"
EOF
chmod +x "$T/anch.sh"

eq 'same record + delta'    "$("$T/anch.sh" 102 1 0 '101 102 103' 4)" '4'   # b=3 + delta1
eq 'same record delta 0'    "$("$T/anch.sh" 102 0 0 '101 102 103' 3)" '3'
eq 'delta past new height'  "$("$T/anch.sh" 102 2 0 '101 102 103' 5)" '4'   # d2 > h-1 -> last line
eq 'first record delta'     "$("$T/anch.sh" 101 2 0 '101 102 103' 2)" '2'
eq 'evicted -> successor'   "$("$T/anch.sh" 99 0 0 '101 99 102' 1)" '3'    # 102 survives -> b=3
eq 'evicted -> predecessor' "$("$T/anch.sh" 104 0 0 '101 102 104' 8)" '3'   # 102 -> b=3
eq 'no survivors -> 1st new' "$("$T/anch.sh" 105 0 0 '200 105 201' 5)" '0'  # -> 101 b=0
eq 'all old -> predecessor' "$("$T/anch.sh" 104 0 0 '101 102 103 104' 9)" '6' # -> 103 b=6
eq 'no old records'         "$("$T/anch.sh" 104 0 0 ''            5)" '0'   # -> first new
eq 'top-following pinned'   "$("$T/anch.sh" 102 1 0 '101 102 103' 0)" '0'
eq 'resize delta scaled'    "$("$T/anch.sh" 102 1 3 '101 102 103' 4)" '3'   # d1 * h2/old3 = 0
eq 'resize same height'     "$("$T/anch.sh" 101 2 3 '101 102 103' 2)" '2'   # h 3->3 verbatim
eq 'resize bigger window'   "$("$T/anch.sh" 101 2 6 '101 102 103' 2)" '1'   # d2 * h3/old6 = 1

# anchor_update -> ANCHOR_N/ANCHOR_D/ANCHOR_C for ST_VOFF in the same build
cat >"$T/anchup.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
ST_REC_N=(101 102 103); ST_REC_B=(0 3 6); ST_REC_C=(3 2 4); ST_VOFF=\$1
. "$T/funcs.sh"
anchor_update
printf '%s %s %s\n' "\$ANCHOR_N" "\$ANCHOR_D" "\$ANCHOR_C"
EOF
chmod +x "$T/anchup.sh"

eq 'anchor@0 is empty'      "$("$T/anchup.sh" 0)"  ' 0 0'
eq 'anchor@4 mid-record'    "$("$T/anchup.sh" 4)"  '102 1 2'
eq 'anchor@6 record start'  "$("$T/anchup.sh" 6)"  '103 0 4'
eq 'anchor@10 past lines'   "$("$T/anchup.sh" 10)" '103 3 4'   # cap row -> last line

# --- _layout viewport geometry ------------------------------------------------
SNAP_TALL="$T/tall.json"
python3 - "$SNAP_TALL" <<'PY'
import json, sys
prs = [{"n": 300+i, "state":"OPEN",
        "title": "fix: pr number %d with a title that wraps across several body lines" % i,
        "review":"APPROVED","draft":False,"updated":"u","pending":0,"rounds":0,
        "fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"",
        "sync_blocked":"","sync_pending":"","skip":"","agent":"","agent_started":0,
        "session_id":"","last_run":0,"model":""} for i in range(10)]
s = {"v":1,"now":1794000000,"repo":"test/nav","update":"","gh_error":False,
     "watcher":{"running":False,"pid":"","launchd":False,"cycle_active":False,
                "last_cycle":0,"interval":120},
     "watch":"open PRs by @me",
     "cfg":{"perm_mode":"dangerous","extras":"","concurrency":2,"max_rounds":10,
            "max_fails":3,"retry_max":3,"reacts":"humans","table_rows":0,
            "activity_lines":0,"title_w":0,"title_lines":3},
     "prs":prs,"activity":[]}
json.dump(s, open(sys.argv[1],"w"))
PY

lay() { "$REPO/pr-agent" _layout "$@"; }
contains() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3" "'$2' not in $1"; }

# meta geometry: rows=12 -> 3-line body region over a 30-line logical body
lay "$SNAP_TALL" 60 12 30 "$T/meta.jsonl" >"$T/m0.out"
G="$(head -1 "$T/meta.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["vreg"],g["body_lines"],g["max_voff"],g["max_hoff"],g["gutter"],g["voff"],g["projected"])')"
eq 'geometry vreg/body/maxv/maxh/gut/voff/proj' "$G" '1 20 19 56 8 0 1'

# voff inside range selects a different window; pinned box rows stay put
lay "$SNAP_TALL" 60 12 30 "$T/meta3.jsonl" 0 3 >"$T/m3.out"
V="$(head -1 "$T/meta3.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["voff"])')"
eq 'meta reports applied voff' "$V" '3'
W="$(head -1 "$T/meta3.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["voff"],g["vreg"],g["max_voff"])')"
eq 'geom stays same after scroll' "$W" '3 1 19'
cmp -s "$T/m0.out" "$T/m3.out" && bad 'scrolled paint differs' 'identical' || ok 'scrolled paint differs'

# voff beyond max clamps inside the view (meta geometry + applied both clamped?)
lay "$SNAP_TALL" 60 12 30 "$T/meta99.jsonl" 0 99 >"$T/m99.out"
V="$(head -1 "$T/meta99.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["voff"])')"
eq 'voff clamps to max_voff' "$V" '19'
# the deepest record's identity line is reachable at its own anchor bline
BL="$(tail -1 "$T/meta99.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g.get("bline",""))')"
lay "$SNAP_TALL" 60 12 30 "$T/mlast.jsonl" 0 "$BL" >"$T/mlast.out"
contains "$T/mlast.out" '#309' 'last record reachable at its bline'

# hoff beyond max_hoff clamps the same way
lay "$SNAP_TALL" 60 12 30 "$T/metah.jsonl" 999 0 >"$T/mh.out"
V="$(head -1 "$T/metah.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["hoff"])')"
eq 'hoff clamps to max_hoff' "$V" '56'

# TABLE_ROWS cap: last record row remains reachable via scroll (cap row is the
# only row below it and is included in body scroll)
SNAP_CAP="$T/cap.json"
jq '.cfg.table_rows = 2' "$SNAP_TALL" >"$SNAP_CAP"
lay "$SNAP_CAP" 60 40 30 "$T/metac.jsonl" >"$T/mc.out"
contains "$T/mc.out" 'more' 'cap row mentions more'
contains "$T/mc.out" 'TABLE_ROWS' 'cap row names the setting'

# single oversized title: TITLE_LINES=0, one record wrapping ~20 lines at cols 50
SNAP_HUGE="$T/huge.json"
jq '.cfg.title_lines = 0 | .prs = [.prs[0]] | .prs[0].title = "feat: " + ("verylongword " * 40)' \
  "$SNAP_TALL" >"$SNAP_HUGE"
lay "$SNAP_HUGE" 50 14 30 "$T/metahj.jsonl" >"$T/mhuge.out"
G="$(head -1 "$T/metahj.jsonl" | python3 -c 'import json,sys; g=json.load(sys.stdin); print(g["body_lines"],g["max_voff"])')"
eq 'huge title body/max_voff' "$G" '14 12'
lay "$SNAP_HUGE" 50 14 30 "$T/metahj2.jsonl" 0 13 >"$T/mhuge2.out"
contains "$T/mhuge2.out" 'verylongword' 'huge title tail reachable at max_voff'
[ "$(wc -l <"$T/mhuge2.out" | tr -d ' ')" -le 14 ] && ok 'rows bound' || bad 'rows bound' "$(wc -l <"$T/mhuge2.out") lines"

# compact tiny-terminal state: no box, safe one-liner
lay "$SNAP_TALL" 24 8 30 "$T/metat.jsonl" >"$T/mt.out"
contains "$T/mt.out" 'terminal too small' 'compact state at 24x8'

echo "--- status_nav: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
