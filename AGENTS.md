# pr-agent — agent rules

> Read this before editing. The whole tool is **one file**: `pr-agent`
> (~1900 lines of bash). The canonical docs are `README.md` (usage) and
> `docs/ARCHITECTURE.md` (code map + flows) — read the architecture doc
> before touching anything past line 100.

## Repo layout

| Path | What it is |
| --- | --- |
| `pr-agent` | The entire tool — a self-contained bash script, no build step |
| `README.md` | User docs: install, commands, dashboard, config |
| `docs/ARCHITECTURE.md` | Code structure map, state files, execution flows |
| `release` | Maintainer script — cuts versioned GitHub releases (`./release [patch|minor|major|X.Y.Z]`) |
| `tests/` | `release.sh` — scratch-repo + stubbed-`gh` harness for `release` and `update`; `update-check.sh` — extracted-function harness for `maybe_update_check`/`pending_update_version` |
| `tests/smoke.sh` | Scratch-repo smoke for the worktree-blocked lifecycle (local git only) |
| `tests/review_verdict.sh` | Fixture checks for the `PR_JQ` `.review` verdict derivation (jq only) |
| `tests/author_match.sh` | Extracted-function fixtures for case-insensitive author/login matching (jq only) |
| `AGENTS.md` | This file |

## Deploy model

The script is installed at `/usr/local/bin/pr-agent`. Edit the repo copy, then
install:

```sh
install -m 755 pr-agent /usr/local/bin/pr-agent
```

`/usr/local/bin/pr-agent` is a copy, not a symlink — **never edit it in place**,
or changes diverge silently. If it already drifted, diff before overwriting.

Releases are cut with `./release [patch|minor|major|X.Y.Z]` from a clean
`main`: it bumps the `VERSION=` line, commits, tags `vX.Y.Z`, pushes, and
publishes a GitHub release with `pr-agent` + `pr-agent.sha256` assets — the
artifacts `pr-agent update` downloads. Interrupted runs resume — the tag
is (re)anchored at `HEAD` and assets (re)uploaded — and `./release X.Y.Z`
mints the checked-in `VERSION` if it was never released.

## Verify before committing

Five scratch-repo harnesses cover what CI doesn't: `tests/smoke.sh`
exercises the worktree-blocked lifecycle on local git alone;
`tests/review_verdict.sh` runs the `PR_JQ` verdict derivation over fixture
payloads; `tests/author_match.sh` lifts the author-matching jq out of
`pr-agent` and checks configured-vs-API login casing; `tests/release.sh`
drives the `release` state machine and `cmd_update` end-to-end with a
stubbed `gh`; `tests/update-check.sh` extracts the update-check functions
from `pr-agent` and exercises the stamp/throttle edge cases. Minimum checks:

```sh
bash -n pr-agent                       # syntax
bash -n release                        # syntax
shellcheck pr-agent release 2>/dev/null || true # lint if available
tests/smoke.sh                         # worktree-blocked lifecycle in a scratch repo (no gh)
tests/review_verdict.sh                # .review verdict derivation fixtures (no gh)
tests/author_match.sh                  # author/login matching fixtures (no gh)
./tests/release.sh                     # release + update scenarios (run when `release` or `cmd_update` changes)
./tests/update-check.sh                # update-check edge cases (run when the check changes)
cd /path/to/a/watched/repo             # then run READ-ONLY commands only:
pr-agent status                        #   dashboard (renders table + activity)
pr-agent status -w 1 & sleep 4; kill %1  #   watch-mode frame
pr-agent config                        #   effective settings
pr-agent peek N / pr-agent logs N      #   per-PR inspection
```

Commands with side effects — `on`, `off`, `run`, `tell`, `retry`, `sync --apply`,
`gc`, `update` — spawn agent sessions, post PR comments, delete worktrees, or
overwrite the installed script. Don't run them as a smoke test unless that's
the intent.

## Conventions (match what's there)

- **Bash 3.2 / BSD only.** macOS `/bin/bash` compatibility: no `declare -A`,
  `mapfile`, `&>`, `${var^^}`, namerefs. Arrays via `local -a` are fine.
  Userland is BSD: `date -j -f`, `stat -f`, `sed -E` — do not "port" to GNU.
- `set -euo pipefail` is on. Every `$( )` substitution must be failure-safe —
  append `|| true` / `|| echo` where a nonzero exit is survivable.
- Functions are small and carry a one-line `# args -> result` contract comment.
  Section banners look like `# --- name --------`; keep new code inside the
  right banner (see the code map in `docs/ARCHITECTURE.md`).
- `local` every variable inside functions. Globals are `UPPER_SNAKE`, locals
  `lower_snake`.
- Colors only via the `C_*` vars from `setup_colors`; log via `log()`, fatal
  via `die`, PR state via `map_set`/`map_get`/`map_del` (lock-protected —
  never write `map.json` directly).
- `pr_info` reads the `prs.jsonl` cache — call `refresh_prs <ttl>` first;
  `0` forces a live fetch (a `gh` call — keep it out of hot loops).

## Traps that have bitten before

- **`watch_loop` re-`cd`s every cycle, on purpose.** The `cd "$(repo_dir)"`
  at loop entry covers a deleted *launch* dir; repeating it at the top of
  `while` covers `repo_dir` itself being deleted mid-run — forked jobs in
  an unreachable cwd spam getcwd errors. Don't hoist the in-loop `cd`.
- **`state_cell`/`review_cell` have side effects** — they populate the `H_*`
  hint buckets that drive the bottom "what now" line. If you skip drawing a
  table row you must still call them, or the hint lies.
- **`state_cell` precedence is deliberate** — working/interrupted →
  merged/closed → `worktree_blocked` → `sync_blocked`/`sync_pending` →
  `skip_reason` (paused/round-limit/approved) → pending items → idle. The
  sync cells must stay above `skip_reason`: `sync_blocked` is a sticky
  "needs you" state for approved/paused PRs the watcher itself skips.
- **`render_status` row budget.** `status -w` passes terminal rows so the table
  caps itself; fixed chrome is `11 + the activity block` (`ACTIVITY_LINES>0`
  adds header + N + blank, i.e. N+2) `+ gh_error` lines. If you add/remove any
  non-table, non-activity line, update the `11` in `chrome` or the frame will
  scroll/clip again. `TABLE_ROWS` overrides the budget — rows beyond it fall
  to the bottom clip, not this cap.
- **`running/<pr>` marker = "stopped by user".** `run_agent` treats a deleted
  marker as an intentional stop (rc 3), not a crash — remove the marker before
  killing a pid, never after.
- **`prs_extra.jsonl` is display-only.** It holds last-known PR objects for
  tracked PRs that aged out of `prs.jsonl`'s `--limit 100` window (backfilled
  once each by `backfill_prs`, pruned by `gc --yes`). `pr_info` falls back to
  it so the status table keeps title/state, but `targets`/`pr_sig` must keep
  reading `prs.jsonl` alone — a stale OPEN entry would make a dead PR
  watchable forever, and a frozen `updated` would mask real changes.
- **`reviewDecision` is empty without branch protection** — GitHub only
  computes it relative to required reviewers, so an APPROVED PR on an
  unprotected base still returns `""`. That's why `.review` falls back to
  each non-author reviewer's latest *opinionated* `reviews` entry — only
  `APPROVED`/`CHANGES_REQUESTED` count (a `COMMENTED` review can't erase a
  standing verdict, a dismissed review reads `DISMISSED` so it drops out);
  CHANGES_REQUESTED wins, else APPROVED counts. Never read `reviewDecision`
  raw when the verdict matters.
- **Feedback `.author` is nullable** — it's `.user.login` from the GitHub API,
  which is `null` for deleted/ghost accounts. jq string builtins (`endswith`,
  `startswith`, `test` on the value itself) abort the whole `filter_feedback`
  run on null input, silently stalling the PR's feedback. Guard with
  `($a // "")` before any string builtin on `.author` (see the `status_re`
  clause in `filter_feedback`).
- **Author comparisons are case-insensitive and fail-closed** — GitHub logins
  are case-insensitive, so every `.author`-vs-configured-login compare
  normalizes via `ascii_downcase` (configured lists are lowercased once at
  build; the item side binds `((.author // "") | ascii_downcase) as $a`).
  `($a != "")` must stay in the `$me` checks: a missing `.author` lowers to
  `""`, which would otherwise equal an unresolved empty `me` and leak a ghost
  comment into the owner-trigger path. Configured lists also drop empty
  entries (`select(length > 0)`) so a blank `BOTS` can't yield `[""]` and
  match a ghost author. `@me`/`@all` tokens normalize too — keep
  `scope_label`'s `@all` check in step or the label disagrees with the
  filter. Fixtures: `tests/author_match.sh`.
- **`seen/<pr>` keys are content-derived** (`id:body-len` / `id:updated_at`) —
  an *edited* review or comment re-triggers. Don't switch to plain ids.
- **`worktree_blocked` is a last-known flag, refreshed locally.** `run_agent`
  sets it on `ensure_worktree` rc 4 and clears it on *any* other prep outcome
  (success or failure) so a stale flag can't mask real state. Freeing the
  branch is a local act `pr_sig` can't see, so `watch_loop` re-probes blocked
  PRs each poll via `still_blocked` (`git worktree list`, prunable stale
  registrations skipped — keep it gh-free) *before* `skip_reason`, so a
  paused/limited/approved PR's flag can't go stale — and clears `sig` to
  force the round on the poll the probe reports free. `still_blocked` has a
  three-way rc: 0 still blocked, 1 confirmed free, **2 indeterminate** (empty
  `repo_dir`/`branch`, moved/broken repo, `worktree list` failed) — callers
  keep flag + sig and skip on rc 2, because forcing a round on a repo we
  can't read would burn `fail_count`, the exact escalation class rc 4 exists
  to avoid. `render_status` also re-probes flagged PRs (`refresh_blocked_flags`)
  so the flag un-stales when the watcher is off, and `sync_scan watch` skips
  flagged PRs since a blocked `check_sync` only defers anyway.
- **Feedback `key` ≠ seen marker ≠ skip state.** Marking a key seen only stops
  *that* item; the PR may still have pending items.
- **The `… N more` table row and the fallback `… N more lines` clip are
  different mechanisms** — the first caps rows inside the table, the second is
  the last-resort bottom clip for wrapped lines and `TABLE_ROWS` overflow.
  Keep both.
- **Watch-scope text goes through `scope_label`.** Any message that says
  what's being watched (`cmd_on` confirm, the status header, the `add`/`rm`
  dies) must use it — printing raw `PR_AUTHOR_FILTER` leaks the `@all`
  meta-token as a pseudo-author, and a blank filter means everyone.
- **EXIT traps can't see function `local`s under `set -u`** — they fire after
  the call stack unwinds, so cleanup vars a trap touches must be globals
  (`UPDATE_TMP`/`UPDATE_STAGED` in `cmd_update`). Signal traps (INT/TERM)
  fire inside the function and *do* see locals.
- **A feature toggle must gate the read side, not just the writer.**
  `UPDATE_CHECK` originally only stopped `maybe_update_check` from refreshing
  `latest_release`, so a recorded pending update kept nagging forever. Gate
  the reader (`pending_update_version`) instead — every current and future
  consumer is covered in one place. Mind per-repo config vs global state: a
  `SETTINGS`-persisted toggle still reads global `$STATE_ROOT` files, so the
  disable only applies in the repo it's set in.
- **Best-effort preamble must never kill dispatch.** `maybe_update_check`
  runs before every command — an unguarded `echo >"$stamp"` under `set -e`
  aborted *every* invocation once the stamp went unwritable (e.g. root-owned
  after `sudo pr-agent update`). Any spawn/setup work that isn't the primary
  command needs `|| return`/`|| true`, and put `2>/dev/null` *before* the
  failing redirect so the EACCES noise is suppressed too. Detached jobs also
  get `mv -f` (matches `cmd_update`) and `</dev/null` — explicit, so nothing
  ever inherits a tty or prompt-blocks. Reference: `tests/update-check.sh`
  S6/S9.
- **User-supplied numbers go through `need_real_pr`, not `need_pr`.**
  `need_pr` only checks digits; commands that write state or spawn an agent
  must also confirm the number resolves to a pull request — `tell`/`pause`/
  `reset` on an *issue* number used to mint a `.prs` key that rendered as a
  permanent "?" status row (`pr_info` finds nothing; `gc` skipped the `""`
  state). `gc` now forgets keys with no cached object whose `gh pr view`
  fails with "Could not resolve to a PullRequest" — `refresh_prs 0` +
  `backfill_prs` already ran by then, so that verdict means "not a PR", not
  "uncached". Only that exact stderr verdict is proof (`gh_err_not_pr` is
  the shared check): rate limits, 5xxs, and repo-level "Could not resolve
  to a Repository" failures mean "couldn't verify" — keep the key, never
  let a transient failure delete state. A stale `locks/<n>` can't shield a
  phantom either — no live run can hold a lock on a non-PR number, so
  `gc --yes` drops the orphaned dir. `need_pr` alone stays only where a
  command does its own resolution (`sync --apply`).

## Commit style

Conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`), one logical
change per commit. When the README's usage table or the usage header comment
at the top of the script changes, keep both in sync — `pr-agent help` prints
the header verbatim. Same for other docs that mirror behavior: the README
dashboard example must match real `status` output, and the ARCHITECTURE.md
code map must place a command in the section that implements it —
dispatch-inline commands belong in the `dispatch` row, not `manual commands`.
