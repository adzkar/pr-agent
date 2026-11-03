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
G="$(mktemp -d /tmp/pr-agent-smoke-gh.XXXXXX)"
trap 'rm -rf "$PR_AGENT_STATE_DIR" "$R" "$R"-* "$G"' EXIT   # "$R"-* = link + worktree dirs created next to it

# stub gh — hermetic: `pr view N` resolves iff N is in $GH_STUB_PRS (N in $GH_STUB_500 fails
# transiently instead of "not a PR"), `pr list` prints $GH_STUB_LIST
cat >"$G/gh" <<'STUB'
#!/usr/bin/env bash
case "$1/$2" in
  pr/view) case " ${GH_STUB_500:-} " in
             *" $3 "*) echo "gh: HTTP 500 Internal Server Error" >&2; exit 1 ;;
           esac
           case " ${GH_STUB_PRS:-} " in
             *" $3 "*) echo "{\"number\":$3,\"state\":\"OPEN\",\"title\":\"t\",\"updated\":\"2026-01-01\"}" ;;
             *) echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1 ;;
           esac ;;
  pr/list) [ -n "${GH_STUB_LIST:-}" ] && printf '%s\n' "$GH_STUB_LIST" ;;
esac
exit 0
STUB
chmod +x "$G/gh"
export PATH="$G:$PATH" GH_STUB_PRS="42"

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

echo "smoke: numbers that aren't PRs rejected; gc forgets stale keys"

check "pause: non-PR number dies"              1 "$(try pause 6)"
out="$(./pr-agent pause 6 2>&1 || true)"
case "$out" in *"not a pull request"*) echo "  ok   die says why" ;; *) echo "  FAIL message: $out"; fail=1 ;; esac
check "tell: non-PR number dies"               1 "$(try tell 6 hi)"
check "run: non-PR number dies"                1 "$(try run 6)"
check "reset: non-PR number dies"              1 "$(try reset 6)"
check "pause: real PR accepted"                0 "$(try pause 42)"
if jq -e '.prs["6"]' "$D/map.json" >/dev/null 2>&1; then echo "  FAIL stale map key written"; fail=1
else echo "  ok   no map key for a non-PR number"; fi
if [ -e "$D/feedback/6.tell.md" ]; then echo "  FAIL tell prompt file left"; fail=1
else echo "  ok   no tell prompt file"; fi

echo hi >"$D/prompt.md"   # mint a phantom key the way the pre-fix _tell did — gc should forget it
check "setup: legacy _tell mints key"          0 "$(try _tell 6 "$D/prompt.md")"
rc=0; out="$(./pr-agent gc 2>&1)" || rc=$?
check "gc dry-run rc"                          0 "$rc"
case "$out" in *"not a pull request"*) echo "  ok   dry-run names the phantom" ;; *) echo "  FAIL gc output: $out"; fail=1 ;; esac
if jq -e '.prs["6"]' "$D/map.json" >/dev/null 2>&1; then echo "  ok   dry-run keeps the key"
else echo "  FAIL dry-run deleted early"; fail=1; fi
check "gc --yes rc"                            0 "$(try gc --yes)"
if jq -e '.prs["6"]' "$D/map.json" >/dev/null 2>&1; then echo "  FAIL phantom key survived gc --yes"; fail=1
else echo "  ok   gc --yes forgot the phantom"; fi
if jq -e '.prs["42"].paused' "$D/map.json" >/dev/null 2>&1; then echo "  ok   real PR key kept"
else echo "  FAIL real PR key dropped"; fail=1; fi

export GH_STUB_500=55                       # 55's gh pr view fails transiently — not "not a PR"
check "setup: legacy _tell mints key"   0 "$(try _tell 55 "$D/prompt.md")"
rc=0; out="$(./pr-agent gc --yes 2>&1)" || rc=$?
check "gc --yes rc with unverifiable key" 0 "$rc"
case "$out" in *"couldn't verify — skipping"*) echo "  ok   gc names the unverifiable key" ;; *) echo "  FAIL gc output: $out"; fail=1 ;; esac
if jq -e '.prs["55"]' "$D/map.json" >/dev/null 2>&1; then echo "  ok   unverifiable key kept"
else echo "  FAIL gc forgot a key it couldn't verify"; fail=1; fi

check "setup: legacy _tell mints key"   0 "$(try _tell 66 "$D/prompt.md")"
mkdir "$D/locks/66"                            # stale lock left by a crashed pre-upgrade run
rc=0; out="$(./pr-agent gc --yes 2>&1)" || rc=$?
check "gc --yes rc with locked phantom" 0 "$rc"
if jq -e '.prs["66"]' "$D/map.json" >/dev/null 2>&1; then echo "  FAIL locked phantom survived gc --yes"; fail=1
else echo "  ok   stale lock didn't shield the phantom"; fi
[ -d "$D/locks/66" ] && { echo "  FAIL stale lock dir left behind"; fail=1; } || echo "  ok   stale lock dir dropped"

echo
if [ "$fail" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: FAILURES"; exit 1; fi
