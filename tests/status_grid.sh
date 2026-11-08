#!/usr/bin/env bash
# Fixture checks for the status grid's logical-table geometry and its bounded
# horizontal projection. Drives `pr-agent _layout` on handcrafted snapshots —
# layout is pure, so no scratch state, no gh stub.
#   logical table:  PR | TITLE | REVIEW | AGENT STATE | ROUNDS | MODEL (+opt)
#   projected mode: _layout SNAP COLS ROWS EVERY [META_OUT [HOFF [VOFF [LIVE]]]]
#                   clips the table to COLS cells behind a frozen PR gutter at
#                   HOFF/VOFF; LIVE names the watch's refresh state for the footer
set -euo pipefail
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NO_COLOR=1

sed -n '/^cell_ops()/,/^}/p' "$REPO/pr-agent" >"$T/funcs.sh"
. "$T/funcs.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }

contains() { grep -qF "$2" "$1" && ok "$3" || bad "$3" "'$2' not in $1"; }
lacks()    { ! grep -qF "$2" "$1" && ok "$3" || bad "$3" "'$2' unexpectedly in $1"; }

# maxw FILE -> widest line in display cells
maxw() { cell_ops len <"$1" | sort -n | tail -1; }
# nlines FILE -> line count
nlines() { wc -l <"$1" | tr -d ' '; }
# table FILE -> just the ┌..└ grid block
table() { sed -n '/┌/,/└/p' "$1"; }
# meta FIELD FILE -> a scalar field out of the geometry line
mval() { sed -n 's/.*"'"$1"'":\([0-9]*\).*/\1/p' "$2" | head -1; }

# --- fixture snapshots ------------------------------------------------------
# main: #266 long title (95 cells), #252 CJK title + model, #300 short title.
# last_run/session present so optional columns have content to measure.
SNAP="$T/snap.json"
cat >"$SNAP" <<'EOF'
{"v":1,"now":1794000000,"repo":"test/grid","update":"","gh_error":false,
 "watcher":{"running":true,"pid":"4242","launchd":false,"cycle_active":false,"last_cycle":1793999880,"interval":120},
 "watch":"open PRs by @me",
 "cfg":{"perm_mode":"dangerous","extras":"","concurrency":2,"max_rounds":10,"max_fails":3,"retry_max":3,"reacts":"humans","table_rows":0,"activity_lines":0,"title_w":0,"title_lines":3},
 "prs":[{"n":266,"state":"OPEN","title":"feat: payment changes for the currency refactor — handling JPY rounding in invoices and credit notes","review":"CHANGES_REQUESTED","draft":false,"updated":"u","pending":2,"rounds":9,"fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"","sync_blocked":"","sync_pending":"","skip":"","agent":"working","agent_started":1793999700,"session_id":"pumped-leaf","last_run":1793999700,"model":""},
        {"n":252,"state":"MERGED","title":"feat: activate the watcher — テストタイトルがとても長い場合","review":"APPROVED","draft":false,"updated":"u","pending":0,"rounds":2,"fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"","sync_blocked":"","sync_pending":"","skip":"","agent":"","agent_started":0,"session_id":"calm-river","last_run":1793900000,"model":"swe-2-max"},
        {"n":300,"state":"OPEN","title":"fix: tiny","review":"","draft":false,"updated":"u","pending":0,"rounds":0,"fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"","sync_blocked":"","sync_pending":"","skip":"","agent":"","agent_started":0,"session_id":"","last_run":0,"model":""}],
 "activity":[]}
EOF

# short: every title short — core columns + slack for optional ones
SNAP_SHORT="$T/short.json"
cat >"$SNAP_SHORT" <<'EOF'
{"v":1,"now":1794000000,"repo":"test/grid","update":"","gh_error":false,
 "watcher":{"running":true,"pid":"4242","launchd":false,"cycle_active":false,"last_cycle":1793999880,"interval":120},
 "watch":"x",
 "cfg":{"perm_mode":"dangerous","extras":"","concurrency":2,"max_rounds":10,"max_fails":3,"retry_max":3,"reacts":"humans","table_rows":0,"activity_lines":0,"title_w":0,"title_lines":3},
 "prs":[{"n":7,"state":"OPEN","title":"fix: it","review":"APPROVED","draft":false,"updated":"u","pending":0,"rounds":3,"fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"","sync_blocked":"","sync_pending":"","skip":"","agent":"","agent_started":0,"session_id":"calm-river","last_run":1793900000,"model":"swe-2-max"}],
 "activity":[]}
EOF

with_cfg() { # SNAP_IN SNAP_OUT title_w table_rows -> copy with cfg overrides
  jq '.cfg.title_w = '"$3"' | .cfg.table_rows = '"$4" "$1" >"$2"
}

lay() { # SNAP ARGS -> _layout
  "$REPO/pr-agent" _layout "$@"
}

echo "== logical table: core columns always present, plain paint is complete =="
lay "$SNAP" 80 >"$T/plain80.out"
contains "$T/plain80.out" "ROUNDS" "ROUNDS header present at 80 (plain)"
contains "$T/plain80.out" "MODEL"  "MODEL header present at 80 (plain)"
contains "$T/plain80.out" "#266"   "record #266 in plain table"
contains "$T/plain80.out" "swe-2-max" "real model value renders"
contains "$T/plain80.out" "—"      "empty model falls back to —"
contains "$T/plain80.out" "9"      "existing round count renders"

echo "== core metadata measured, not truncated =="
lay "$SNAP" 200 >"$T/plain200.out"
contains "$T/plain200.out" "↻ agent working 5m0s" "full agent state text reachable"
contains "$T/plain200.out" "✗ changes req." "full review text reachable"
contains "$T/plain200.out" "AGENT STATE" "agent state heading"

echo "== projection: watch frame is bounded, gutter frozen =="
for c in 80 100 125 200; do
  lay "$SNAP" "$c" 24 5 >"$T/w$c.out"
  w="$(table "$T/w$c.out" | cell_ops len | sort -n | tail -1)"
  [ "$w" -le "$c" ] && ok "table bounded at cols=$c (max $w cells)" \
                    || bad "table bounded at cols=$c" "widest table line $w cells"
  contains "$T/w$c.out" "#266" "PR identity visible at cols=$c"
done
contains "$T/w80.out" "TITLE" "title column visible at 80"

echo "== plain paint keeps every logical cell reachable =="
lay "$SNAP" 80 >"$T/p80.out"
contains "$T/p80.out" "MODEL" "MODEL reachable in plain paint at 80"
contains "$T/p80.out" "swe-2-max" "model value reachable in plain paint at 80"

echo "== horizontal offset: window slides, body height stable, gutter stays =="
lay "$SNAP" 80 24 5 "$T/m0.jsonl" 0  >"$T/off0.out"
lay "$SNAP" 80 24 5 "$T/mX.jsonl" 60 >"$T/off60.out"
contains "$T/off60.out" "#266"  "PR identity stays when scrolled"
contains "$T/off60.out" "MODEL" "far-right column reachable via offset"
lacks    "$T/off60.out" "payment changes" "left of window clipped away"
h0="$(table "$T/off0.out" | wc -l | tr -d ' ')"
hX="$(table "$T/off60.out" | wc -l | tr -d ' ')"
[ "$h0" = "$hX" ] && ok "body height invariant under offset" \
                  || bad "body height invariant under offset" "$h0 vs $hX"
w="$(table "$T/off60.out" | cell_ops len | sort -n | tail -1)"
[ "$w" -le 80 ] && ok "offset frame still bounded" || bad "offset frame bounded" "$w cells"

echo "== meta anchors: same record lines at any offset =="
a0="$(grep -v geometry "$T/m0.jsonl" | tr -d ' ')"
aX="$(grep -v geometry "$T/mX.jsonl" | tr -d ' ')"
[ "$a0" = "$aX" ] && ok "record anchors stable under offset" || bad "anchors under offset" "$a0 vs $aX"
[ "$(mval hoff "$T/mX.jsonl")" = "60" ] && ok "hoff echoed in geometry" || bad "hoff geometry" "$(mval hoff "$T/mX.jsonl")"
[ "$(mval projected "$T/mX.jsonl")" = "1" ] && ok "projected flag in geometry" || bad "projected flag" "$(mval projected "$T/mX.jsonl")"

echo "== auto title width: grows with room and content, no ceiling =="
lay "$SNAP" 80  "" "" "$T/g80.jsonl"  >/dev/null
lay "$SNAP" 140 "" "" "$T/g140.jsonl" >/dev/null
lay "$SNAP" 220 "" "" "$T/g220.jsonl" >/dev/null
w80="$(mval title_w "$T/g80.jsonl")"; w140="$(mval title_w "$T/g140.jsonl")"; w220="$(mval title_w "$T/g220.jsonl")"
[ "$w140" -gt "$w80" ] && ok "auto title grows with viewport ($w80<$w140)" \
                     || bad "auto title grows with viewport" "$w80 vs $w140"
[ "$w220" -ge "$w140" ] && ok "auto title bounded by content ($w140 up to $w220)" \
                      || bad "auto title bounded by content" "$w220"
jq '.prs += [{"n":999,"state":"OPEN","title":"feat: a really quite extraordinarily long pull request title that keeps going and going well past one hundred display cells on any reasonable terminal","review":"","draft":false,"updated":"u","pending":0,"rounds":0,"fail_count":0,"gave_up":"","retry_gave_up":"","worktree_blocked":"","sync_blocked":"","sync_pending":"","skip":"","agent":"","agent_started":0,"session_id":"","last_run":0,"model":""}]' \
  "$SNAP" >"$T/long.json"
lay "$T/long.json" 220 "" "" "$T/long.jsonl" >/dev/null
wlong="$(mval title_w "$T/long.jsonl")"
[ "$wlong" -gt 100 ] && ok "no 100-char ceiling (title_w $wlong)" \
                     || bad "no 100-char ceiling" "$wlong"

echo "== optional columns fill genuine slack, never steal title width =="
lay "$SNAP_SHORT" 100 "" "" "$T/s100.jsonl" >"$T/s100.out"
lay "$SNAP_SHORT" 140 "" "" "$T/s140.jsonl" >"$T/s140.out"
contains "$T/s100.out" "LAST RUN" "LAST RUN joins when it fully fits"
contains "$T/s140.out" "SESSION"  "SESSION joins at wider slack"
lay "$SNAP_SHORT" 78 "" "" "$T/s78.jsonl" >"$T/s78.out"
lacks "$T/s78.out" "LAST RUN" "LAST RUN absent without full spare width"
[ "$(mval title_w "$T/s100.jsonl")" = "$(mval title_w "$T/s78.jsonl")" ] \
  && ok "optional columns don't steal preferred title width" \
  || bad "optional columns steal title width" "$(mval title_w "$T/s100.jsonl") vs $(mval title_w "$T/s78.jsonl")"

echo "== pinned TITLE_W: small, equal, oversized all project safely =="
for tw in 30 60 150; do
  with_cfg "$SNAP" "$T/pin$tw.json" "$tw" 0
  lay "$T/pin$tw.json" 100 "" "" "$T/pin$tw.jsonl" >/dev/null
  [ "$(mval title_w "$T/pin$tw.jsonl")" = "$tw" ] && ok "pin $tw kept as logical width" \
    || bad "pin $tw kept" "$(mval title_w "$T/pin$tw.jsonl")"
  lay "$T/pin$tw.json" 100 24 5 >"$T/pinw$tw.out"
  w="$(table "$T/pinw$tw.out" | cell_ops len | sort -n | tail -1)"
  [ "$w" -le 100 ] && ok "pin $tw projects bounded" || bad "pin $tw bounded" "$w cells"
done
contains "$T/pinw150.out" "#266" "oversized pin keeps PR identity"

with_cfg "$SNAP" "$T/pin3.json" 3 0
lay "$T/pin3.json" 80 "" "" "$T/pin3.jsonl" >"$T/pin3.out"
[ "$(mval title_w "$T/pin3.jsonl")" = "5" ] && ok "pin below heading floors at TITLE (5)" \
  || bad "pin below heading floors" "$(mval title_w "$T/pin3.jsonl")"
w="$(table "$T/pin3.out" | cell_ops len | sort -u | wc -l | tr -d ' ')"
[ "$w" -eq 1 ] && ok "pin floor keeps rows one logical width" \
               || bad "pin floor keeps rows one width" "$w distinct widths"

echo "== wrapping: one logical width, blank-cell continuations, aligned dividers =="
lay "$SNAP" 80 >"$T/wrap.out"
ln1="$(table "$T/wrap.out" | sed -n '4p')"   # first record line
ln2="$(table "$T/wrap.out" | sed -n '5p')"   # its continuation line
contains <(printf '%s' "$ln1") "│ #266 │" "padded PR cell both sides"
p1="$(printf '%s' "$ln1" | cell_ops pos -v needle='│')"
p2="$(printf '%s' "$ln2" | cell_ops pos -v needle='│')"
[ "$p1" = "$p2" ] && ok "continuation dividers aligned ($p1)" \
                  || bad "continuation dividers aligned" "$p1 vs $p2"
rest="$(printf '%s' "$ln2" | awk -F'│' '{for(f=4;f<NF;f++) printf "%s", $f}')"
[ "$(printf '%s' "$rest" | tr -d ' ')" = "" ] && ok "continuation metadata cells blank" \
  || bad "continuation metadata cells blank" "'$rest'"

echo "== TABLE_ROWS cap row stays a regular-width row =="
with_cfg "$SNAP" "$T/cap.json" 0 2
lay "$T/cap.json" 100 >"$T/cap.out"
contains "$T/cap.out" "… 1 more — TABLE_ROWS=2" "cap row text"
w="$(table "$T/cap.out" | cell_ops len | sort -u | wc -l | tr -d ' ')"
[ "$w" -eq 1 ] && ok "cap row same logical width as grid" || bad "cap row width" "$w distinct widths"

echo "== unicode + ANSI fixtures project bounded =="
jq '.prs[0].title = "feat: \u001b[31mred ansi\u001b[0m title inside a cell and more words"' "$SNAP" >"$T/ansi.json"
lay "$T/ansi.json" 80 24 5 >"$T/ansi.out"
w="$(table "$T/ansi.out" | cell_ops len | sort -n | tail -1)"
[ "$w" -le 80 ] && ok "ANSI title bounded" || bad "ANSI title bounded" "$w cells"
w="$(table "$T/off0.out" | cell_ops len | sort -n | tail -1)"
[ "$w" -le 80 ] && ok "CJK title bounded" || bad "CJK title bounded" "$w cells"

echo "== boundary states =="
lay "$SNAP" 20 >"$T/tiny.out"
contains "$T/tiny.out" "terminal too small" "compact state at cols=20"
[ "$(nlines "$T/tiny.out")" -le 4 ] && ok "compact frame is small" || bad "compact frame small" "$(nlines "$T/tiny.out")"
lay "$SNAP" 100 5 5 >"$T/tinyr.out"
contains "$T/tinyr.out" "terminal too small" "compact state at rows<8"
cat >"$T/empty.json" <<'EOF'
{"v":1,"now":1,"repo":"t/r","update":"","gh_error":false,"watcher":{"running":false,"pid":"","launchd":false,"cycle_active":false,"last_cycle":0,"interval":120},"watch":"x","cfg":{"perm_mode":"dangerous","extras":"","concurrency":2,"max_rounds":10,"max_fails":3,"retry_max":3,"reacts":"humans","table_rows":0,"activity_lines":0,"title_w":0,"title_lines":3},"prs":[],"activity":[]}
EOF
lay "$T/empty.json" 80 >"$T/zero.out"
contains "$T/zero.out" "no PRs to show" "zero records renders message"

echo "== frame clip: soft-wrap-aware bottom clip (cell_ops clip contract) =="
{ printf 'a\nb\nc\nd\n'; } | cell_ops clip -v cols=10 -v rows=3 >"$T/clip.out"
[ "$(nlines "$T/clip.out")" -eq 3 ] && [ "$(tail -1 "$T/clip.out" | od -An -tx1 | tr -d ' \n')" = "02320a" ] \
  && ok "clip keeps prefix + sentinel" || bad "clip sentinel" "$(cat -v "$T/clip.out" | tail -1)"
printf 'a\nb\nc\n' | cell_ops clip -v cols=10 -v rows=1 >"$T/clip1.out"
[ "$(od -An -tx1 <"$T/clip1.out" | tr -d ' \n')" = "02330a" ] \
  && ok "bare sentinel when nothing fits (rows=1)" || bad "bare sentinel" "$(cat -v "$T/clip1.out")"

echo "== row budget: activity shrink accounts for its trailing blank =="
jq '.cfg.activity_lines = 8 | .activity = ["1\t[2026-11-07 08:00:00] watcher started (interval=120s)",
     "1\t[2026-11-07 08:01:00] PR #266: 2 new feedback item(s) since last check",
     "1\t[2026-11-07 08:02:00] PR #266: starting new session in wt",
     "1\t[2026-11-07 09:00:00] PR #266: round done at 09:00",
     "1\t[2026-11-07 09:01:00] PR #252: mapped to session calm-river",
     "1\t[2026-11-07 09:02:00] PR #300: skipped — session busy",
     "1\t[2026-11-07 09:03:00] PR #266: resuming session pumped-leaf",
     "1\t[2026-11-07 09:04:00] PR #266: 1 new comment",
     "1\t[2026-11-07 09:05:00] watcher poll complete",
     "1\t[2026-11-07 09:06:00] PR #266: handled feedback"]' "$SNAP" >"$T/act.json"
for r in 21 22 23 24 25 26; do   # saturation range: act_n clamps inside 1..ACTIVITY_LINES
  lay "$T/act.json" 80 "$r" 5 >"$T/act$r.out"
  ph="$(cell_ops len <"$T/act$r.out" | awk -v c=80 '{t+=($1>0?int(($1+c-1)/c):1)} END{print t}')"
  contains "$T/act$r.out" "recent activity" "activity section emitted at rows=$r"
  [ "$ph" -le $(( r - 1 )) ] && ok "budgeted frame fits rows=$r (phys $ph)" \
                             || bad "budgeted frame fits rows=$r" "phys $ph > $((r-1))"
done

echo "== -w footer: the controls are the fixed half; state/cache notes trail =="
# base + controls fits at 80 in every live state, so trunc drops a trailing
# note, never the help (annotated bases stay short on purpose)
for st in live refreshing stale loading retry; do
  lay "$SNAP" 80 24 5 "" 0 0 "$st" >"$T/foot-$st.out"
  contains "$T/foot-$st.out" "q quit" "footer controls survive at 80 (live=$st)"
done
contains "$T/foot-live.out"       "updated"          "live footer carries the data clock"
contains "$T/foot-refreshing.out" "↻ refreshing"     "refreshing note still shows at 80"
contains "$T/foot-stale.out"      "⚠ refresh failed" "stale footer names the state"
contains "$T/foot-stale.out"      "old"              "stale footer carries the data age"
contains "$T/foot-loading.out"    "gathering status" "loading footer"
contains "$T/foot-retry.out"      "retrying"         "retry footer"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
