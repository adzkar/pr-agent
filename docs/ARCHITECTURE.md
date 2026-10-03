# Architecture

`pr-agent` is a single bash script (~1600 lines). It polls GitHub for new PR
feedback and hands each round to a **persistent Devin CLI session per PR**
running inside that PR's dedicated git worktree — so the agent keeps context
across review rounds and never touches your checkout.

Source of truth for usage: the header comment at the top of the script (what
`pr-agent help` prints) and `README.md`.

## Code map

Sections are delimited by `# --- name ---` banners, in file order:

| Section | Approx. lines | Contents |
| --- | --- | --- |
| header + bootstrap | 1–114 | Usage doc comment, `set -euo pipefail`, `STATE_ROOT` (`~/.local/state/pr-agent/repos/<owner>__<repo>`), repo-slug resolution, legacy-state migration |
| settings | 115–159 | `CFG_*` saved config → `PR_AGENT_*` env → default precedence; `save_config`, `log`, `notify` (osascript) |
| repo context | 160–182 | `repo`/`repo_dir`/`me` accessors, `detect_repo` (writes repo, repo_dir, me, base into state) |
| map | 183–210 | `map.json` accessors (`map_get/set/del/rm/num`) behind `with_map_lock` (mkdir lock, ~10 s stale break) |
| PR list | 212–249 | `refresh_prs` — one `gh pr list` call → `prs.jsonl` cache (number, title, state, draft, review, updated, branch, head, base, mergeable, ci, ci_failed, body, cross); `pr_info`, `targets` |
| feedback collection | 251–322 | `fetch_feedback` (3 `gh api` endpoints + `synthetic_feedback`), `seed_seen`, `filter_feedback` (seen/author/bot/skip rules), `pending_feedback` |
| failed review runs | 324–442 | `handle_review_failure` + helpers — pings the review bot (`RETRY_MSG`) on `Review failed:` notices, `RETRY_MAX` cap, `retry_cutoff` keeps pre-existing failures manual-only |
| formatting | 444–456 | `format_feedback` — jsonl → markdown prompt sections |
| worktree | 458–520 | `ensure_worktree` (`<repo>-pr-<N>` next to the main checkout), `setup_worktree` (copies `.env*`/`config.local.json`, reuses `node_modules` when manifests match else `bun install --frozen-lockfile`, husky prepare), `sync_worktree` |
| main-sync | 522–760 | Post-merge catch-up: `sync_scan` → `check_sync` merges base into PR branch **via the PR's agent session**, then `verify_synced` + `apply_unblock` (dep-gated draft unbanner/ready, `sync_unblock` state machine) |
| agent | 762–858 | `build_prompt`, `devin_flags`, `session_ids`/`new_session_id` (diff `devin list` before/after), `run_agent` (resume `devin -r` else start new) |
| per-PR check | 860–927 | `check_pr` — the per-PR round; `skip_reason` |
| watcher | 929–1018 | `watch_loop`, `is_running`, `pr_sig`, launchd plist install |
| manual commands | 1071–1236 | `run`, `tell`/`_tell`, `attach`, `retry`, `peek`, `mark-seen`, `gc`, `sync`, `config`, `logs` |
| status rendering | 1238–1593 | `fmt_*`, `draw_*`, `status_prs`, `review_cell`/`state_cell` (side effects: `H_*` hint buckets), `recent_events`, `render_hint`, `render_status` (row-budgeted table), `cmd_status` (alt-screen watch loop + fallback clip) |
| dispatch | 1596–end | `usage`, `case "$1"` router; `_loop` is the internal watcher entry |

## On-disk state

`$PR_AGENT_STATE_DIR` (default `~/.local/state/pr-agent`):

```
<root>/
  current                      # repo slug last `on`ed (used outside a repo)
  repos/<owner>__<repo>/
    repo repo_dir me base      # written by detect_repo
    targets                    # "all" or explicit PR numbers
    config                     # CFG_* saved by `pr-agent on`
    pid                        # watcher pid
    map.json                   # PR → session/worktree/counters (see below)
    map.lock                   # mkdir lock dir for map writes
    watch.log                  # event log (drives "recent activity")
    prs.jsonl                  # PR list cache (one object per PR)
    gh_error                   # exists ⇔ last refresh_prs failed
    cycle_active / last_cycle  # poll-in-progress marker / last poll epoch
    status_pending             # "pr count" lines, unprocessed feedback per open PR
    retry_cutoff               # ISO ts; bot failures older than this stay manual
    locks/<pr>                 # mkdir lock: a check_pr round is in flight
    running/<pr>               # "pid epoch new|resume" while an agent runs
    seen/<pr>                  # handled feedback keys, one per line
    feedback/<pr>.jsonl        # items of the last round (for --force reruns)
    logs/<pr>/<ts>.log         # agent transcripts; latest.log symlink; last 20 kept
```

`map.json` → `{prs: {<pr>: {session_id, worktree, branch, rounds, fail_count,
gave_up, sig, last_seen_ts, last_head_sha, last_run_at, paused, skip_logged,
sync_*, retry_*}}}` — all values strings; `map_num` coerces empty → 0.

Feedback items are jsonl `{key, ts, kind, author, body, url, …}` with
`kind ∈ review|line|comment|ci|conflict`. `key` embeds id + body-length or
`updated_at`, so edited items re-trigger. `seen/<pr>` holds handled keys.

## Flows

### `pr-agent on [--launchd] [all|N…]`

`detect_repo` → write `targets` → `save_config` → spawn `pr-agent _loop`:
`nohup … &` normally, or a `~/Library/LaunchAgents/dev.pr-agent.<slug>.plist`
bootstrapped with `KeepAlive` when `--launchd`. `_loop` = `watch_loop` in the
same script.

### Poll cycle (`watch_loop`, every `INTERVAL`s)

```
refresh_prs 0                      # one gh pr list; failure → gh_error + warn once
for pr in $(targets):              # all open non-draft PRs, or explicit list
    skip_reason → paused / round limit / approved / merged|closed
    pr_sig unchanged && cycle % 10 != 0 → skip   # cheap dedupe vs full fetch
    while jobs -rp >= CONCURRENCY: sleep 2       # cap parallel rounds
    ( check_pr pr sig ) &
MAIN_SYNC=1 → sync_scan watch      # catch branches fallen behind base
sleep INTERVAL
```

A full feedback fetch is forced every `FULL_CHECK_EVERY` (10) cycles even when
the signature looks unchanged.

### Round (`check_pr`)

```
mkdir locks/<pr>                   # bail if a round is in flight
fetch_feedback → seed_seen → retry_reset_if_reviewed
filter_feedback → new items (oldest first)
handle_review_failure              # bot-failure pings run even with no feedback
build_prompt → run_agent
  rc 0 → keys → seen/<pr>, rounds++, last_run_at, last_head_sha, notify
  rc 1 → fail_count++; at MAX_FAILS: keys → seen (stop retrying), gave_up=1,
         escalates with a PR comment + notification
  rc 2/3 → session busy / stopped by user: feedback stays pending
```

### Agent run (`run_agent`)

```
ensure_worktree (or fail) → map_set worktree/branch → sync_worktree (ff-only if clean)
session_id set → devin -r <session> -p <prompt>   # resume keeps round context
  - "already open in another process" → rc 2 (retry next poll)
  - dies < 30s in → fall through to a fresh session
else → devin -p <prompt>             # new session
  → new_session_id: devin list diff (new since start, not already mapped)
  → map_set session_id
```

The prompt (`build_prompt`) tells the agent: fetch first, address every
finding, run project verification, reply to each line-comment thread, post a
summary comment asking for re-review.

### Feedback filtering (`filter_feedback`)

An item is actionable when: not in `seen/<pr>` AND not matching `SKIP_RE`
(default: HTML "in-progress" markers) AND not a bot failure notice (handled by
the retry path) AND one of:

- synthetic CI/conflict item (opt-in), or
- authored by you and starting with `TRIGGER` (`/agent`), or
- authored by someone else where `AUTHOR_FILTER` includes them — empty filter
  means anyone except `[bot]` logins not listed in `BOTS`.

### Status screen (`render_status [ttl] [term-rows]`)

Header (watcher state, targets, settings, poll countdown) → PR table:
`status_prs` = watch targets ∪ PRs with map history, **open first then
merged/closed dimmed**. `state_cell` renders the AGENT STATE column and fills
the `H_*` buckets that pick the one-line `render_hint`. Then a blank line,
`recent activity` (last 6 deduped `watch.log` events), and the hint.

`-w` mode repaints on the alt screen: `cmd_status` passes `tput lines` so
`render_status` caps table body rows at `rows − 19 − gh_error`, collapsing the
rest into a `… N more` row (open PRs first — merged history drops out first).
If a line wraps and the frame still overflows, a bottom clip shows
`… N more lines` as a last resort. The `19` counts every fixed line: badge,
watching line, blank, 3 rules + header, blank, activity header, 6 event lines,
blank, hint, blank, footer — adjust it if you add or remove any.

### Concurrency & locking

- `map.lock` (mkdir) serializes `map.json` writes; stale locks broken ~10 s.
- `locks/<pr>` (mkdir) serializes rounds per PR.
- `running/<pr>` files list live agent pids — deleted before the pid is
  killed, so `run_agent` reads it as "stopped by user" (rc 3).
- Parallelism is bounded by `jobs -rp < CONCURRENCY` in the poll loop, not a
  queue — rounds are started as background subshells.

### Failure & escalation model

- Agent round fails `MAX_FAILS`× → `gave_up`, feedback marked seen (stops the
  retry loop), escalation comment posted on the PR.
- Review-bot failure notices → script pings the bot directly (`RETRY_MSG`),
  `RETRY_MAX`× per PR before `retry_gave_up`. `retry_reset_if_reviewed` clears
  the state when the bot produces a real review.
- `gh` unreachable → `gh_error` marker, dashboard warns, loop keeps polling.
