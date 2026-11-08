#!/usr/bin/env bash
# Fixtures for the sessions-index adapter behind status_model_lookup (#42).
# Drives _gather against a scratch state dir + stubbed gh with a real sqlite
# sessions index and asserts: exact session-id + worktree matching, selected
# model/router truthfulness ('adaptive' stays 'adaptive'), model-switch and
# session-reset refresh, canonicalized worktree dirs, the repo-dir fallback,
# cross-repo isolation, safe unknowns for missing/corrupt/old-schema sources,
# and that acquisition is read-only.
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

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "status_model: no sqlite3 — skipping (the adapter reports unknown without it)"
  exit 0
fi

PR_AGENT_STATE_DIR="$(mktemp -d /tmp/pr-agent-mdl-state.XXXXXX)"; export PR_AGENT_STATE_DIR
export PR_AGENT_REPO=test/mdl PR_AGENT_UPDATE_CHECK=0
G="$(mktemp -d /tmp/pr-agent-mdl-gh.XXXXXX)"
R="$(mktemp -d /tmp/pr-agent-mdl-repo.XXXXXX)"
WT_A="$(mktemp -d /tmp/pr-agent-mdl-wtA.XXXXXX)"
WT_B="$(mktemp -d /tmp/pr-agent-mdl-wtB.XXXXXX)"
WT_C="$(mktemp -d /tmp/pr-agent-mdl-wtC.XXXXXX)"
WT_LREAL="$(mktemp -d /tmp/pr-agent-mdl-wtLR.XXXXXX)"
trap 'rm -rf "$PR_AGENT_STATE_DIR" "$G" "$R" "$WT_A" "$WT_B" "$WT_C" "$WT_LREAL"' EXIT

# stub gh — `pr list` prints $GH_STUB_LIST; everything else stays quiet
cat >"$G/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in pr) [ "$2" = list ] && printf '%s\n' "${GH_STUB_LIST:-}" ;; esac
exit 0
STUB
chmod +x "$G/gh"
export PATH="$G:$PATH"
unset PR_AGENT_MODEL_LOOKUP   # these fixtures exercise the real adapter, not the probe seam

# WT_LINK exercises the pwd -P rescue: the map holds the symlinked spelling
# while the sessions index records the canonical dir
WT_LINK="$G/wt-link"; ln -s "$WT_LREAL" "$WT_LINK"
WT_LCANON="$(cd "$WT_LREAL" && pwd -P)"

git -C "$R" init -q
R="$(cd "$R" && pwd -P)"

D="$PR_AGENT_STATE_DIR/repos/test__mdl"
mkdir -p "$D"
echo "test/mdl" >"$D/repo"
echo "alice"    >"$D/me"
echo "all"      >"$D/targets"
echo "$R"       >"$D/repo_dir"

cat >"$D/map.json" <<EOF
{"prs":{"1":{},
        "2":{"session_id":"sess-fixed","worktree":"$WT_A"},
        "3":{"session_id":"sess-adaptive","worktree":"$WT_B"},
        "4":{"session_id":"sess-foreign","worktree":"$WT_A"},
        "5":{"session_id":"sess-empty","worktree":"$WT_B"},
        "6":{"session_id":"sess-link","worktree":"$WT_LINK"},
        "7":{"session_id":"sess-repo"},
        "8":{"session_id":"sess-switch","worktree":"$WT_C"},
        "9":{"session_id":"sess-long","worktree":"$WT_C"}}}
EOF

# the sessions index — same table shape the CLI ships (model is initial-schema)
DB="$G/sessions.db"; export PR_AGENT_SESSIONS_DB="$DB"
sqlite3 "$DB" <<EOF
CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL,
  backend_type TEXT NOT NULL, model TEXT NOT NULL, agent_mode TEXT NOT NULL,
  created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL);
INSERT INTO sessions VALUES
  ('sess-fixed',   '$WT_A',           'w', 'swe-2-max',        'bypass', 1, 10),
  ('sess-adaptive','$WT_B',           'w', 'adaptive',         'bypass', 1, 10),
  ('sess-foreign', '/somewhere/else', 'w', 'claude-opus-5-5',  'bypass', 1, 10),
  ('sess-empty',   '$WT_B',           'w', '',                 'bypass', 1, 10),
  ('sess-link',    '$WT_LCANON',      'w', 'swe-1-6-fast',     'bypass', 1, 10),
  ('sess-repo',    '$R',              'w', 'gpt-6-luna-medium','bypass', 1, 10),
  ('sess-switch',  '$WT_C',           'w', 'swe-2-medium',     'bypass', 1, 10),
  ('sess-long',    '$WT_C',           'w', 'swe-2-ultra-max-experimental-2000', 'bypass', 1, 10);
EOF

mdl() { jq -r --argjson n "$1" '.prs[] | select(.n == $n) | .model' "$SNAP"; }

echo "status_model: verified rows report the session's selected model or router"

dbsum="$(md5 -q "$DB")"
SNAP="$(mktemp)"
./pr-agent _gather 0 >"$SNAP"
check "snapshot parses"           "1"   "$(jq -e 'type == "object"' "$SNAP" >/dev/null && echo 1 || echo 0)"
check "fixed model reported"      "swe-2-max"         "$(mdl 2)"
check "router stays adaptive"     "adaptive"          "$(mdl 3)"
check "foreign dir isolated"      ""                  "$(mdl 4)"
check "empty model -> unknown"    ""                  "$(mdl 5)"
check "canonicalized wt rescued"  "swe-1-6-fast"      "$(mdl 6)"
check "repo-dir fallback"         "gpt-6-luna-medium" "$(mdl 7)"
check "pre-switch model"          "swe-2-medium"      "$(mdl 8)"
check "long id kept whole"        "swe-2-ultra-max-experimental-2000" "$(mdl 9)"
check "cache file: pr line"       "2 swe-2-max"       "$(awk '$1 == 2' "$D/status_models")"
check "index never written"       "$dbsum"            "$(md5 -q "$DB")"

FRAME="$(./pr-agent _layout "$SNAP" 160)"
check_in "no-session shows em dash"  "$FRAME" "—"
check_in "no-evidence shows unknown" "$FRAME" "unknown"
check_in "long model id reachable"   "$FRAME" "swe-2-ultra-max-experimental-2000"

echo "status_model: switches and resets refresh with the source"

sqlite3 "$DB" "UPDATE sessions SET model = 'claude-opus-5-5-max' WHERE id = 'sess-switch'"
SNAP="$(mktemp)"; ./pr-agent _gather 0 >"$SNAP"
check "model switch reflected"    "claude-opus-5-5-max" "$(mdl 8)"

jq '.prs["8"].session_id = "sess-gone"' "$D/map.json" >"$D/map.tmp" && mv "$D/map.tmp" "$D/map.json"
SNAP="$(mktemp)"; ./pr-agent _gather 0 >"$SNAP"
check "session reset drops model" ""                  "$(mdl 8)"

echo "status_model: unusable sources degrade to unknown — never a stall, never a write"

PR_AGENT_SESSIONS_DB="$G/missing.db" ./pr-agent _gather 0 >"$SNAP"
check "missing index -> unknown"  ""                  "$(mdl 2)"

echo "this is not sqlite" >"$G/corrupt.db"
PR_AGENT_SESSIONS_DB="$G/corrupt.db" ./pr-agent _gather 0 >"$SNAP"
check "corrupt index -> unknown"  ""                  "$(mdl 2)"

sqlite3 "$G/old.db" "CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL)"
PR_AGENT_SESSIONS_DB="$G/old.db" ./pr-agent _gather 0 >"$SNAP"
check "old schema -> unknown"     ""                  "$(mdl 2)"

mkdir -p "$G/bad" && printf '#!/usr/bin/env bash\nexit 1\n' >"$G/bad/sqlite3" && chmod +x "$G/bad/sqlite3"
PR_AGENT_SESSIONS_DB="$DB" PATH="$G/bad:$G:$PATH" ./pr-agent _gather 0 >"$SNAP"
check "failing sqlite3 -> unknown" ""                 "$(mdl 2)"

echo
if [ "$fail" -eq 0 ]; then echo "status_model: all checks passed"; else echo "status_model: FAILURES"; exit 1; fi
