#!/usr/bin/env bash
# Upgrade-survival fixtures (#43): a pre-milestone installation must keep
# working under the new dashboard without being migrated or reconfigured —
# a headerless/markerless legacy config file, old-shaped map/seen/log state,
# a still-running older watcher, and rollback to a real previous release.
# Drives real ./pr-agent commands over scratch state + a stubbed gh — no
# live installs and nothing "upgrades" by deleting user files.
# Run from anywhere: tests/upgrade.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # name want got -> report
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1 — want '$2' got '$3'"; fail=1; fi
}
check_in() { # name haystack needle -> substring present
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1 — '$3' not in: $2"; fail=1 ;; esac
}

PR_AGENT_STATE_DIR="$(mktemp -d /tmp/pr-agent-upg-state.XXXXXX)"; export PR_AGENT_STATE_DIR
export PR_AGENT_REPO=test/upg PR_AGENT_UPDATE_CHECK=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PR_AGENT_SESSIONS_DB="/nonexistent-sessions.db"   # hermetic: no developer sessions.db leaks in
unset PR_AGENT_MODEL_LOOKUP
G="$(mktemp -d /tmp/pr-agent-upg-gh.XXXXXX)"
R="$(mktemp -d /tmp/pr-agent-upg-repo.XXXXXX)"
trap 'rm -rf "$PR_AGENT_STATE_DIR" "$G" "$R"' EXIT

# stub gh — `pr list` prints $GH_STUB_LIST; everything else stays quiet
cat >"$G/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in pr) [ "$2" = list ] && printf '%s\n' "${GH_STUB_LIST:-}" ;; esac
exit 0
STUB
chmod +x "$G/gh"
export PATH="$G:$PATH"

# scratch repo: 'held' checked out at the main checkout (still blocked),
# 'free' exists but is checked out nowhere (the allowed flag-clear case)
git -C "$R" init -q
R="$(cd "$R" && pwd -P)"
git -C "$R" remote add origin "$R"
git -C "$R" commit -qm init --allow-empty
git -C "$R" branch free
git -C "$R" checkout -qb held

D="$PR_AGENT_STATE_DIR/repos/test__upg"
mkdir -p "$D/seen" "$D/feedback" "$D/logs/3" "$D/running" "$D/locks/9"
printf 'test/upg\n' >"$D/repo"
printf 'alice\n'    >"$D/me"
printf 'all\n'      >"$D/targets"
printf '%s\n' "$R"  >"$D/repo_dir"
printf 'main\n'     >"$D/base"

# a pre-milestone map: sparse records missing newer keys, an unknown future
# key (#2), legacy flag/sig keys (#4 held → kept, #5 freed → cleared)
cat >"$D/map.json" <<'EOF'
{"prs":{"2":{"session_id":"sess-two","worktree":"/old/wt/2","rounds":"2",
             "paused":"1","last_seen_ts":"2026-01-02T00:00:00Z","future_field":"kept"},
        "3":{"rounds":"4","gave_up":"1","fail_count":"3","last_seen_ts":"2026-01-01T00:00:00Z"},
        "4":{"worktree_blocked":"1","blocked_logged":"1","sig":"s4","rounds":"1"},
        "5":{"worktree_blocked":"1","blocked_logged":"1","sig":"s5","rounds":"2","session_id":"sess-five"},
        "7":{"session_id":"sess-seven","rounds":"9"}}}
EOF

# watcher-owned files a status gather must never write
printf 'i:9:c\n' >"$D/seen/2"
printf 'w:0\n'   >"$D/seen/7"
printf '{"key":"i:9:c","kind":"issue","user":{"login":"bob"}}\n' >"$D/feedback/2.jsonl"
printf 'old run output\n' >"$D/logs/3/20260101-000000.log"
ln -s "20260101-000000.log" "$D/logs/3/latest.log"
printf '2000000000 1\n' >"$D/running/2" # out-of-range pid — guaranteed dead ("interrupted")
printf '[2026-01-02 00:00:00] PR #3: gave up\n[2026-01-02 00:05:00] PR #4: worktree blocked — skipped\n' >"$D/watch.log"

# the older CLI's PR rows — post-PR_JQ JSONL (branches drive still_blocked's
# held/free verdicts)
GH_STUB_LIST='{"number":2,"state":"OPEN","title":"paused legacy pr","review":"APPROVED","draft":false,"updated":"u","branch":"b2","head":"h","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":3,"state":"OPEN","title":"gave-up legacy pr","review":"APPROVED","draft":false,"updated":"u","branch":"b3","head":"h","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":4,"state":"OPEN","title":"blocked on held branch","review":"APPROVED","draft":false,"updated":"u","branch":"held","head":"h","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":5,"state":"OPEN","title":"blocked flag on a freed branch","review":"APPROVED","draft":false,"updated":"u","branch":"free","head":"h","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":7,"state":"OPEN","title":"watcher-owned record","review":"APPROVED","draft":false,"updated":"u","branch":"b7","head":"h","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}'
export GH_STUB_LIST

# --- A: a pre-versioned config keeps working ----------------------------------
# no '# pr-agent config vN' header, no CFG_SRC_* demotion of real keys; the
# one marker present governs a non-display key and must stay inert
cat >"$D/config" <<'EOF'
# carried over from an older install
CFG_INTERVAL=45
CFG_PERM_MODE=normal
CFG_MAX_ROUNDS=7
CFG_TITLE_LINES=5
CFG_TABLE_ROWS=2
CFG_TITLE_W=40
CFG_NOTIFY=0
CFG_FUTURE=sparkles
CFG_SRC_INTERVAL=default
EOF
cfgsum="$(md5 -q "$D/config")"

echo "upgrade: a headerless legacy config resolves saved, marks nothing, stays bytes-identical"

O="$(./pr-agent config)"
check_in "saved cap honored"        "$O" 'TABLE_ROWS        2 (saved)'
check_in "saved title cap"          "$O" 'TITLE_LINES       5 (saved)'
check_in "saved pinned width"       "$O" 'TITLE_W           40 (saved)'
check_in "saved non-display key"    "$O" 'PERM_MODE         normal (saved)'
check_in "inert marker on non-display key" "$O" 'INTERVAL          45 (saved)'
check_in "usage footer intact"      "$O" "(saved by 'pr-agent on'"
case "$O" in *'ignored invalid input'*) echo "  FAIL unexpected invalid-input note"; fail=1 ;; esac

SNAP="$(mktemp "$G/snap.XXXXXX")"; ./pr-agent _gather 0 >"$SNAP"   # scratch under $G — the trap cleans it
check "snapshot parses"             "1"   "$(jq -e 'type == "object"' "$SNAP" >/dev/null && echo 1 || echo 0)"
check "cap reaches snapshot"        "2"   "$(jq -r '.cfg.table_rows' "$SNAP")"
check "title cap reaches snapshot"  "5"   "$(jq -r '.cfg.title_lines' "$SNAP")"
check "pinned width reaches snapshot" "40" "$(jq -r '.cfg.title_w' "$SNAP")"
check "config byte-identical after status" "$cfgsum" "$(md5 -q "$D/config")"

FRAME="$(./pr-agent _layout "$SNAP" 160)"
check_in "cap row honors saved cap" "$FRAME" '… 3 more (3 open) — TABLE_ROWS=2'

# invalid saved numerics degrade to the default with a note — file untouched;
# a display-key marker still demotes (that's the marker contract, v2 or not).
# Numeric validation is display-keys only — CFG_MAX_ROUNDS=zzz would just be
# a saved string (resolve_str), so both rejects here are display keys.
cat >"$D/config" <<'EOF'
# carried over from an older install
CFG_TABLE_ROWS=banana
CFG_ACTIVITY_LINES=x
CFG_TITLE_W=40
CFG_SRC_TITLE_W=default
EOF
cfgsum="$(md5 -q "$D/config")"
O="$(./pr-agent config)"
check_in "invalid saved caps noted"     "$O" 'ignored invalid input: TABLE_ROWS:saved ACTIVITY_LINES:saved'
check_in "invalid cap falls to default" "$O" 'TABLE_ROWS        0 (default)'
check_in "demote marker still applies"  "$O" 'TITLE_W           0 (default)'
check "config byte-identical after reads" "$cfgsum" "$(md5 -q "$D/config")"
rm "$D/config"

# --- B: old PR/session/worktree state survives the new status -----------------
# gather's only allowed map writes are the blocked-flag trio on a freed PR
mapsum_keep() { jq -S 'del(.prs[].worktree_blocked, .prs[].blocked_logged, .prs[].sig)' "$D/map.json" | md5 -q; }
wlist() { { find "$D/seen" "$D/feedback" "$D/logs" "$D/running" "$D/locks" \( -type f -o -type l \) \
           -exec md5 -r {} + </dev/null | sort; md5 -r "$D/watch.log"; } | sed "s|$D/||"; }
wsum() { wlist | md5 -q; }

before_map="$(mapsum_keep)"; before_w="$(wsum)"

echo "upgrade: old map/seen/log state survives gather + layout untouched"

SNAP="$(mktemp "$G/snap.XXXXXX")"; ./pr-agent _gather 0 >"$SNAP"
check "gather on legacy state"      "1"   "$(jq -e 'type == "object"' "$SNAP" >/dev/null && echo 1 || echo 0)"
check "all five records render"     "5"   "$(jq '[.prs[].n] | length' "$SNAP")"
check "legacy paused field works"   "paused" "$(jq -r '.prs[] | select(.n == 2) | .skip' "$SNAP")"
check "dead run marker interrupts"  "interrupted" "$(jq -r '.prs[] | select(.n == 2) | .agent' "$SNAP")"
check "legacy gave_up works"        "1"   "$(jq -r '.prs[] | select(.n == 3) | .gave_up' "$SNAP")"
check "session id survives"         "sess-five" "$(jq -r '.prs[] | select(.n == 5) | .session_id' "$SNAP")"
check "freed flags cleared (allowed write)" "rounds,session_id" "$(jq -r '.prs["5"] | keys | join(",")' "$D/map.json")"
check "held flags kept"             "blocked_logged,rounds,sig,worktree_blocked" "$(jq -r '.prs["4"] | keys | join(",")' "$D/map.json")"
check "other map keys byte-identical" "$before_map" "$(mapsum_keep)"
check "future key preserved"        "kept" "$(jq -r '.prs["2"].future_field' "$D/map.json")"
check "watcher files byte-identical"  "$before_w" "$(wsum)"

FRAME="$(./pr-agent _layout "$SNAP" 160)"
check_in "layout renders legacy state" "$FRAME" '#7'
check "layout wrote nothing"        "$before_w" "$(wsum)"
check "map still clean after layout" "$before_map" "$(mapsum_keep)"

# --- C: an older watcher keeps maintaining state alongside the new status ------
echo "upgrade: a still-running older watcher's writes survive the new status"

( for i in $(seq 30); do
    jq --arg v "$i" '.prs["7"].wbeat = $v' "$D/map.json" >"$D/map.wtmp" && mv "$D/map.wtmp" "$D/map.json"
    printf 'w:%s\n' "$i" >>"$D/seen/7"
    printf '[2026-01-02 00:10:%02d] PR #7: poll %s\n' "$i" "$i" >>"$D/watch.log"
    sleep 0.05
  done ) &
WPID=$!

i=0
while [ "$i" -lt 5 ]; do
  S="$(mktemp "$G/snap.XXXXXX")"; ./pr-agent _gather 0 >"$S"
  check "snapshot parses under churn (run $i)" "1" "$(jq -e 'type == "object"' "$S" >/dev/null && echo 1 || echo 0)"
  i=$((i+1))
done
wait "$WPID"

check "watcher's map write survives"  "30"  "$(jq -r '.prs["7"].wbeat // ""' "$D/map.json")"
check "watcher's session survives"    "sess-seven" "$(jq -r '.prs["7"].session_id' "$D/map.json")"
check "seen tail is the watcher's"    "w:30" "$(tail -1 "$D/seen/7")"
check "seen line count is watcher's"  "31"  "$(wc -l <"$D/seen/7" | tr -d ' ')"
check "watch.log only gains watcher lines" "30" "$(grep -c 'PR #7: poll' "$D/watch.log")"
check "no seen markers invented"      "2"   "$(ls "$D/seen" | wc -l | tr -d ' ')"
check "no churn tempfiles leak"       ""    "$(ls "$D" | grep 'map\.wtmp' || true)"
check "allowed caches still published" "1"  "$( { [ -f "$D/status_pending" ] && [ -f "$D/status_models" ]; } && echo 1 || echo 0 )"

# --- D: rollback — the previous release still runs on post-upgrade state -------
echo "upgrade: a rolled-back release finds its state intact"

OLD="$G/old-pr-agent"
# rollback coverage needs the v0.3.0 tag — a shallow/CI checkout may not
# have it, so fetch (prompt-bound — never stalls on interactive auth)
# before degrading to a (loud) skip, not an invisible one
git rev-parse -q --verify refs/tags/v0.3.0 >/dev/null 2>&1 || \
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
  git fetch --tags -q >/dev/null 2>&1 || true
git show v0.3.0:pr-agent >"$OLD" 2>/dev/null || true
if [ -s "$OLD" ]; then
  after_c_map="$(mapsum_keep)"; after_c_list="$(wlist)"
  chmod +x "$OLD"
  check "old binary reports its version" "pr-agent 0.3.0" "$("$OLD" version 2>/dev/null || true)"
  OC="$("$OLD" config 2>/dev/null || true)"
  check_in "old binary reads the state" "$OC" 'repo:'
  "$OLD" status >/dev/null 2>&1 || true   # older renderer may differ; only state must survive
  check "map keys still clean after rollback" "$after_c_map" "$(mapsum_keep)"
  # the old binary keeps its own semantics — its status gather seeds empty
  # seen/ markers (the behavior this milestone removed). On rollback that's
  # allowed: what must hold is no pre-existing watcher file lost or rewritten
  w_lost=0
  while read -r h f; do
    [ -e "$D/$f" ] && [ "$(md5 -q "$D/$f")" = "$h" ] || w_lost=1
  done <<<"$after_c_list"
  check "pre-existing watcher files survive" "0" "$w_lost"
  SNAP="$(mktemp "$G/snap.XXXXXX")"; ./pr-agent _gather 0 >"$SNAP"
  check "new status still gathers post-rollback" "5" "$(jq '[.prs[].n] | length' "$SNAP")"
else
  echo "  WARN: v0.3.0 tag unavailable — rollback coverage skipped (git fetch --tags to enable)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "upgrade: all checks passed"; else echo "upgrade: FAILURES"; exit 1; fi
