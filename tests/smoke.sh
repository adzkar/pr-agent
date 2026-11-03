#!/usr/bin/env bash
# Scratch-repo smoke for the worktree-blocked lifecycle — local git only, no gh.
# Builds a temp repo + fake per-repo state, then drives the internal dispatch
# entries (_ensure → ensure_worktree, _blocked → still_blocked) and asserts rcs.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # name want_rc got_rc -> report
  if [ "$2" -eq "$3" ]; then echo "  ok   $1 (rc $3)"
  else echo "  FAIL $1 — want rc $2, got $3"; fail=1; fi
}
try() { local rc=0; ./pr-agent "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

PR_AGENT_STATE_DIR="$(mktemp -d /tmp/pr-agent-smoke-state.XXXXXX)"; export PR_AGENT_STATE_DIR
export PR_AGENT_REPO=test/smoke
R="$(mktemp -d /tmp/pr-agent-smoke-repo.XXXXXX)"
trap 'rm -rf "$PR_AGENT_STATE_DIR" "$R" "$R"-*' EXIT   # "$R"-* = link + worktree dirs created next to it

D="$PR_AGENT_STATE_DIR/repos/test__smoke"
mkdir -p "$D"
echo "test/smoke" >"$D/repo"

git -C "$R" init -q
git -C "$R" remote add origin "$R"          # ensure_worktree fetches origin before worktree add
git -C "$R" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
git -C "$R" checkout -qb base
git -C "$R" checkout -qb pr-branch          # now held in the main checkout
R="$(cd "$R" && pwd -P)"                    # worktree paths come back canonical
echo "$R" >"$D/repo_dir"
echo '{"number":7,"branch":"pr-branch","state":"OPEN","title":"t","updated":"2026-01-01"}' >"$D/prs.jsonl"
echo '{"number":9,"branch":"gone-branch","state":"OPEN","title":"t","updated":"2026-01-01"}' >>"$D/prs.jsonl"

echo "smoke: worktree-blocked lifecycle in a scratch repo"

check "ensure: branch held in main checkout → rc 4" 4 "$(try _ensure 7 pr-branch)"
check "probe: held → 0"                              0 "$(try _blocked 7)"

ln -s "$R" "$R-link"                        # symlinked repo_dir still matches the canonical holder
echo "$R-link" >"$D/repo_dir"
check "ensure: symlinked repo_dir → rc 4"    4 "$(try _ensure 7 pr-branch)"
check "probe: symlinked held → 0"            0 "$(try _blocked 7)"
echo "$R" >"$D/repo_dir"; rm -f "$R-link"

git -C "$R" checkout -q base                # free the branch
check "probe: freed → 1"                     1 "$(try _blocked 7)"
rc=0; out="$(./pr-agent _ensure 7 pr-branch 2>/dev/null)" || rc=$?
check "ensure: freed branch → rc 0 worktree" 0 "$rc"
if [ "$out" = "$R-pr-7" ]; then echo "  ok   side worktree at $out"
else echo "  FAIL worktree path — got '$out' (want $R-pr-7)"; fail=1; fi

git -C "$R" branch stale-branch
git -C "$R" worktree add -q "$R-stale" stale-branch 2>/dev/null
rm -rf "$R-stale"                           # leaves a prunable registration behind
check "ensure: prunable registration not a holder → rc 0" 0 "$(try _ensure 8 stale-branch)"

echo "" >"$D/repo_dir"
check "ensure: empty repo_dir → rc 1"        1 "$(try _ensure 7 pr-branch)"
check "probe: empty repo_dir → 2 indeterminate" 2 "$(try _blocked 7)"

echo "$R-moved" >"$D/repo_dir"
check "probe: missing repo → 2 indeterminate" 2 "$(try _blocked 7)"
echo "$R" >"$D/repo_dir"

check "probe: stale branch ref fails open → 1" 1 "$(try _blocked 9)"

echo
if [ "$fail" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: FAILURES"; exit 1; fi
