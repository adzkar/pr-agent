#!/usr/bin/env bash
# Fixtures for the status gather -> snapshot -> layout split. Drives the internal
# `_gather`/`_layout` dispatch entries against a scratch state dir + stubbed gh,
# and asserts: snapshot contents (ordering, state inputs, pending counts), no
# seen-marker writes, atomic cache publishing, pure/repeatable layout, and
# incomplete-snapshot rejection. No real GitHub, no watcher.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # name want got -> report
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1 — want '$2' got '$3'"; fail=1; fi
}
check_in() { # name needle haystack -> substring present
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1 — '$3' not in: $2"; fail=1 ;; esac
}
check_not_in() { # name needle haystack -> substring absent
  case "$2" in *"$3"*) echo "  FAIL $1 — '$3' found in: $2"; fail=1 ;; *) echo "  ok   $1" ;; esac
}

PR_AGENT_STATE_DIR="$(mktemp -d /tmp/pr-agent-snap-state.XXXXXX)"; export PR_AGENT_STATE_DIR
export PR_AGENT_REPO=test/snap PR_AGENT_UPDATE_CHECK=0
R="$(mktemp -d /tmp/pr-agent-snap-repo.XXXXXX)"
G="$(mktemp -d /tmp/pr-agent-snap-gh.XXXXXX)"
trap 'rm -rf "$PR_AGENT_STATE_DIR" "$R" "$G"' EXIT

# stub gh — `pr list` prints $GH_STUB_LIST (post-PR_JQ objects); `api` answers the
# three fetch_feedback endpoints from GH_REV_<n>/GH_COM_<n>/GH_ISS_<n> and logs each
# call's URL to $GH_LOG so tests can see which PRs were fetched.
cat >"$G/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api) url="$3"; [ -n "${GH_LOG:-}" ] && echo "$url" >>"$GH_LOG"
       case "$url" in *"$GH_SLOW_URL") sleep "${GH_SLOW_SECS:-0}" ;; esac
       case "$url" in
         */pulls/*/reviews)   v="GH_REV_${url##*/pulls/}";  v="${v%%/*}" ;;
         */pulls/*/comments)  v="GH_COM_${url##*/pulls/}";  v="${v%%/*}" ;;
         */issues/*/comments) v="GH_ISS_${url##*/issues/}"; v="${v%%/*}" ;;
       esac
       printf '%s\n' "${!v:-}" ;;
  pr) case "$2" in
        list) printf '%s\n' "${GH_STUB_LIST:-}" ;;
        view) echo "GraphQL: Could not resolve to a PullRequest." >&2; exit 1 ;;
      esac ;;
esac
exit 0
STUB
chmod +x "$G/gh"

# model-probe stubs for the PR_AGENT_MODEL_LOOKUP seam: one answers instantly,
# one hangs past any bound so refresh_status_models must reuse prior evidence
cat >"$G/model-probe" <<'STUB'
#!/usr/bin/env bash
printf 'probe-model\n'
STUB
cat >"$G/model-probe-hang" <<'STUB'
#!/usr/bin/env bash
exec sleep 60
STUB
chmod +x "$G/model-probe" "$G/model-probe-hang"
export PATH="$G:$PATH"

D="$PR_AGENT_STATE_DIR/repos/test__snap"
mkdir -p "$D"
echo "test/snap" >"$D/repo"
echo "alice"    >"$D/me"
echo "all"      >"$D/targets"

# scratch repo so still_blocked has something real to probe: PR 4's branch is held
git -C "$R" init -q
git -C "$R" remote add origin "$R"
git -C "$R" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
git -C "$R" checkout -qb base
git -C "$R" checkout -qb pr-branch          # held in the main checkout -> PR 4 stays blocked
R="$(cd "$R" && pwd -P)"
echo "$R" >"$D/repo_dir"

cat >"$D/map.json" <<'EOF'
{"prs":{"1":{"rounds":"2","last_seen_ts":"2026-01-02T00:00:00Z"},
        "2":{"paused":"1","last_seen_ts":"2026-01-02T00:00:00Z","session_id":"sess-2"},
        "3":{"gave_up":"1","rounds":"4"},
        "4":{"worktree_blocked":"1","branch":"pr-branch","rounds":"1"}}}
EOF
mkdir -p "$D/seen"
echo 'i:10:x' >"$D/seen/1"     # watcher-owned: item i:10 already handled
echo 'i:30:z' >"$D/seen/3"

# PR list cache objects (post-PR_JQ shape): #2 newest activity, #3 merged+aged, #4 draft
export GH_STUB_LIST='{"number":1,"title":"feat: add the caching layer","state":"OPEN","draft":false,"review":"CHANGES_REQUESTED","updated":"2026-01-05T00:00:00Z","branch":"b1","head":"h1","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":2,"title":"fix: repair the broken thing","state":"OPEN","draft":false,"review":"APPROVED","updated":"2026-01-06T00:00:00Z","branch":"b2","head":"h2","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"alice"}
{"number":3,"title":"chore: tidy up","state":"MERGED","draft":false,"review":"APPROVED","updated":"2026-01-03T00:00:00Z","branch":"b3","head":"h3","base":"main","mergeable":"UNKNOWN","ci":"pass","ci_failed":[],"author":"alice"}
{"number":4,"title":"feat: blocked work","state":"OPEN","draft":true,"review":"","updated":"2026-01-04T00:00:00Z","branch":"pr-branch","head":"h4","base":"main","mergeable":"MERGEABLE","ci":"pass","ci_failed":[],"author":"bob"}'

# feedback per PR: #1 has one seen + one new item; #2 gets the legacy-cutoff pair;
# #4 has none; #3 is merged so nothing is fetched for it at all
export GH_ISS_1='{"key":"i:10:x","ts":"2026-01-01T00:00:00Z","kind":"comment","author":"bob","body":"old","url":"u1"}
{"key":"i:11:y","ts":"2026-01-05T00:00:00Z","kind":"comment","author":"bob","body":"new","url":"u2"}'
export GH_ISS_2='{"key":"i:20:a","ts":"2026-01-01T00:00:00Z","kind":"comment","author":"bob","body":"before cutoff","url":"u3"}
{"key":"i:21:b","ts":"2026-01-03T00:00:00Z","kind":"comment","author":"bob","body":"after cutoff","url":"u4"}'

GH_LOG="$(mktemp)"; export GH_LOG
map_sum="$(md5 -q "$D/map.json")"
seen1_sum="$(md5 -q "$D/seen/1")"

echo "status_snapshot: gather emits a complete, correctly-shaped snapshot"

SNAP="$(mktemp)"
./pr-agent _gather 0 >"$SNAP"
check "snapshot parses as JSON"        "1" "$(jq -e 'type == "object"' "$SNAP" >/dev/null && echo 1 || echo 0)"
check "version tag"                    "1" "$(jq -r '.v' "$SNAP")"
check "prs order: recent activity"     "2 1 4 3" "$(jq -r '[.prs[].n] | join(" ")' "$SNAP")"
check "#1 pending: new item only"      "1" "$(jq -r '.prs[] | select(.n==1) | .pending' "$SNAP")"
check "#1 rounds preserved"            "2" "$(jq -r '.prs[] | select(.n==1) | .rounds' "$SNAP")"
check "#1 review value"                "CHANGES_REQUESTED" "$(jq -r '.prs[] | select(.n==1) | .review' "$SNAP")"
check "#1 state"                       "OPEN" "$(jq -r '.prs[] | select(.n==1) | .state' "$SNAP")"
check "#1 title raw"                   "feat: add the caching layer" "$(jq -r '.prs[] | select(.n==1) | .title' "$SNAP")"
check "#2 legacy cutoff -> 1 pending"  "1" "$(jq -r '.prs[] | select(.n==2) | .pending' "$SNAP")"
check "#2 skip reason"                 "paused" "$(jq -r '.prs[] | select(.n==2) | .skip' "$SNAP")"
check "#3 state"                       "MERGED" "$(jq -r '.prs[] | select(.n==3) | .state' "$SNAP")"
check "#3 merged -> no pending fetch"  "0" "$(jq -r '.prs[] | select(.n==3) | .pending' "$SNAP")"
check "#3 gave_up flag"                "1" "$(jq -r '.prs[] | select(.n==3) | .gave_up' "$SNAP")"
check "#4 draft flag"                  "true" "$(jq -r '.prs[] | select(.n==4) | .draft' "$SNAP")"
check "#4 worktree_blocked kept"       "1" "$(jq -r '.prs[] | select(.n==4) | .worktree_blocked' "$SNAP")"
check "watch label"                    "open PRs by @me" "$(jq -r '.watch' "$SNAP")"
check "watcher not running"            "false" "$(jq -r '.watcher.running' "$SNAP")"
check "gh_error clear"                 "false" "$(jq -r '.gh_error' "$SNAP")"
check "cfg.table_rows"                 "0" "$(jq -r '.cfg.table_rows' "$SNAP")"
check "cfg.title_lines"                "3" "$(jq -r '.cfg.title_lines' "$SNAP")"
check "model evidence slot"            "" "$(jq -r '.prs[] | select(.n==1) | .model' "$SNAP")"
check "pending_ts numeric"             "true" "$(jq -r '.pending_ts | type == "number" and . >= 0' "$SNAP")"
check "models_ts numeric"              "true" "$(jq -r '.models_ts | type == "number" and . >= 0' "$SNAP")"

echo "status_snapshot: gather side effects stay inside the allowed inventory"

check "no seen file created for #2"    "0" "$(ls "$D/seen" | grep -c '^2$' || true)"
check "seen/1 unchanged"               "$seen1_sum" "$(md5 -q "$D/seen/1")"
check "map.json untouched"             "$map_sum" "$(md5 -q "$D/map.json")"
check "status_pending written"         "2 1 1 1 4 0" "$(awk '{print $1, $2}' "$D/status_pending" | tr '\n' ' ' | sed 's/ $//')"
check "merged PR fetched no feedback"  "0" "$(grep -c 'pulls/3/\|issues/3/' "$GH_LOG" || true)"
check "feedback fetched: 3x3 open PRs" "9" "$(wc -l <"$GH_LOG" | tr -d ' ')"

echo "status_snapshot: layout is pure and repeatable"

check "layout rc"                      "0" "$(./pr-agent _layout "$SNAP" 100 >/dev/null 2>&1; echo $?)"
FRAME="$(./pr-agent _layout "$SNAP" 100)"
check_in "header repo"        "$FRAME" "test/snap"
check_in "watch scope"        "$FRAME" "open PRs by @me"
check_in "#2 cell paused"     "$FRAME" "⏸ paused"
check_in "#1 cell pending"    "$FRAME" "● 1 new item"
check_in "#1 review cell"     "$FRAME" "✗ changes req."
check_in "#3 cell merged"     "$FRAME" "merged — done"
check_in "#4 cell blocked"    "$FRAME" "⚠ worktree blocked"
check_in "#4 review draft"    "$FRAME" "draft"
check_in "hint sees pending PRs"    "$FRAME" "watcher is off — new feedback on #1 won't be handled"
check "draw order 2<1<4<3"    "1" "$(printf '%s\n' "$FRAME" | grep -n '#[0-9]' | grep -oE '#[0-9]+' | tr '\n' ' ' | grep -c '#2 #1 #4 #3' || true)"

FRAME2="$(./pr-agent _layout "$SNAP" 100)"
check "repeat paint identical"         "1" "$([ "$FRAME" = "$FRAME2" ] && echo 1 || echo 0)"
FRAME3="$(./pr-agent _layout "$SNAP" 60)"
check "resize paint runs clean"        "0" "$(./pr-agent _layout "$SNAP" 60 >/dev/null 2>&1; echo $?)"

# purity: stub gh+git+devin to record invocation, snapshot the state dir, paint
mkdir -p "$G/pure" && cat >"$G/pure/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"${PURE_LOG:-/dev/null}"; exit 1
STUB
cat >"$G/pure/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >>"${PURE_LOG:-/dev/null}"; exit 1
STUB
cat >"$G/pure/devin" <<'STUB'
#!/usr/bin/env bash
echo "devin $*" >>"${PURE_LOG:-/dev/null}"; exit 1
STUB
chmod +x "$G/pure"/{gh,git,devin}
PURE_LOG="$(mktemp)"; export PURE_LOG
state_sum="$(find "$D" -type f | sort | xargs md5 -q 2>/dev/null | md5 -q)"
PATH="$G/pure:$G:$PATH" ./pr-agent _layout "$SNAP" 100 >/dev/null 2>&1
check "layout made no tool calls"      "0" "$(wc -l <"$PURE_LOG" | tr -d ' ')"
check "layout wrote no state"          "$state_sum" "$(find "$D" -type f | sort | xargs md5 -q 2>/dev/null | md5 -q)"

echo "status_snapshot: snapshot boundary rejects incomplete input"

rc=0; ./pr-agent _layout /dev/null 100 >/dev/null 2>&1 || rc=$?
check "empty file rejected"            "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
BAD="$(mktemp).json"; echo '{"v":1,"now":123}' >"$BAD"
rc=0; ./pr-agent _layout "$BAD" 100 >/dev/null 2>&1 || rc=$?
check "incomplete doc rejected"        "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo "status_snapshot: concurrent gathers never publish partial caches"

SNAP_A="$(mktemp)"; SNAP_B="$(mktemp)"
./pr-agent _gather 0 >"$SNAP_A" & pa=$!
./pr-agent _gather 0 >"$SNAP_B" & pb=$!
wait "$pa" "$pb"
check "concurrent gather A valid"      "4" "$(jq -r '.prs | length' "$SNAP_A" 2>/dev/null || echo 0)"
check "concurrent gather B valid"      "4" "$(jq -r '.prs | length' "$SNAP_B" 2>/dev/null || echo 0)"
check "status_pending still complete"  "2 1 1 1 4 0" "$(awk '{print $1, $2}' "$D/status_pending" | tr '\n' ' ' | sed 's/ $//')"
check "prs.jsonl still complete"       "4" "$(wc -l <"$D/prs.jsonl" | tr -d ' ')"

echo "status_snapshot: TABLE_ROWS cap and meta anchors"

SNAP2="$(mktemp)"
PR_AGENT_TABLE_ROWS=2 ./pr-agent _gather 0 >"$SNAP2"
FRAME4="$(./pr-agent _layout "$SNAP2" 100)"
check_in "record cap row"   "$FRAME4" "… 2 more (1 open) — TABLE_ROWS=2"

# TABLE_ROWS=1 pushes #1 (pending) below the cap — the pre-pass must still see it
SNAP3="$(mktemp)"
PR_AGENT_TABLE_ROWS=1 ./pr-agent _gather 0 >"$SNAP3"
FRAME5="$(./pr-agent _layout "$SNAP3" 100)"
check_in "cap row: 3 hidden, 2 open"   "$FRAME5" "… 3 more (2 open) — TABLE_ROWS=1"
check_in "hint sees pending below cap" "$FRAME5" "watcher is off — new feedback on #1 won't be handled"
META="$(mktemp)"
./pr-agent _layout "$SNAP" 100 "" "" "$META" >/dev/null
check "meta geometry"                  "1" "$(jq -se 'map(select(.type == "geometry" and .cols == 100)) | length == 1' "$META" >/dev/null && echo 1 || echo 0)"
check "meta records"                   "4" "$(grep -c '"n":' "$META" || true)"
check "meta line numbers grow"         "7 10" "$(jq -r 'select(.n) | "\(.line)"' "$META" | tr '\n' ' ' | sed 's/ $//' | awk '{print $1, $4}')"

echo "status_snapshot: the bounded model phase caches what it can, keeps prior evidence when it can't"

touch -t 202001010000 "$D/status_models"      # stale -> the probe phase must run
SNAP_M="$(mktemp)"
PR_AGENT_MODEL_LOOKUP="$G/model-probe" ./pr-agent _gather 0 >"$SNAP_M"
check "probe model lands in record"    "probe-model" "$(jq -r '.prs[] | select(.n==2) | .model' "$SNAP_M")"
check "status_models cache line"       "1" "$(grep -c '^2 probe-model$' "$D/status_models" 2>/dev/null || true)"

# hung probe: bound at 1s keeps the prior cache line — an unbounded phase
# would sit on the probe's 60s sleep, so the split is unambiguous
touch -t 202001010000 "$D/status_models"
SECONDS=0
SNAP_M2="$(mktemp)"
PR_AGENT_MODEL_LOOKUP="$G/model-probe-hang" PR_AGENT_MODEL_TIMEOUT=1 ./pr-agent _gather 0 >"$SNAP_M2"
el=$SECONDS
check "hung model phase bounded"       "1" "$([ "$el" -lt 30 ] && echo 1 || echo 0)"
check "prior model evidence kept"      "probe-model" "$(jq -r '.prs[] | select(.n==2) | .model' "$SNAP_M2")"
check "prior models file kept"         "1" "$(grep -c '^2 probe-model$' "$D/status_models" 2>/dev/null || true)"

echo "status_snapshot: a bound-out PR keeps its prior pending count"

# #2's issue-comments endpoint hangs 60s past PR_AGENT_PENDING_TIMEOUT=1 — the
# per-PR bound keeps the prior count line instead of stalling the whole phase
printf '1 5\n2 7\n4 2\n' >"$D/status_pending"
touch -t 202001010000 "$D/status_pending"     # stale -> refresh must run
SECONDS=0
SNAP_B="$(mktemp)"
GH_SLOW_URL='/issues/2/comments' GH_SLOW_SECS=60 PR_AGENT_PENDING_TIMEOUT=1 \
  ./pr-agent _gather 0 >"$SNAP_B"
el=$SECONDS
check "bound-out pending keeps prior"  "7" "$(jq -r '.prs[] | select(.n==2) | .pending' "$SNAP_B")"
check "prior count in refreshed file"  "2 7" "$(awk '$1 == 2' "$D/status_pending")"
check "bounded pending phase prompt"   "1" "$([ "$el" -lt 30 ] && echo 1 || echo 0)"
check "other PRs still recounted"      "1" "$(jq -r '.prs[] | select(.n==1) | .pending' "$SNAP_B")"
unset GH_SLOW_URL GH_SLOW_SECS PR_AGENT_PENDING_TIMEOUT

echo
if [ "$fail" -eq 0 ]; then echo "status_snapshot: all checks passed"; else echo "status_snapshot: FAILURES"; exit 1; fi
