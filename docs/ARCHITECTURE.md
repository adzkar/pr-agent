# Architecture

`pr-agent` is a single bash script (~2225 lines). It polls GitHub for new PR
feedback and hands each round to a **persistent Devin CLI session per PR**
running inside that PR's dedicated git worktree — so the agent keeps context
across review rounds and never touches your checkout.

Source of truth for usage: the header comment at the top of the script (what
`pr-agent help` prints) and `README.md`.

## Code map

Sections are delimited by `# --- name ---` banners, in file order:

| Section | Approx. lines | Contents |
| --- | --- | --- |
| header + bootstrap | 1–117 | Usage doc comment, `set -euo pipefail`, `VERSION`/`UPDATE_REPO`/`STATE_ROOT`/`DEVIN_BIN`/`SELF`, `die` |
| per-repo state | 118–156 | `slug_of`, `git_repo_name`, `migrate_legacy_state` (pre-per-repo flat layout → `repos/<slug>`), `resolve_repo_slug` → `REPO_SLUG`, `STATE_DIR` + state paths (`PID_FILE`, `MAP_FILE`, `LOG_FILE`, `PRS_CACHE`, `PRS_EXTRA`) |
| settings | 157–273 | `resolve_str`/`resolve_num`/`load_settings` — env → saved `CFG_*` → default resolution with `SRC_<name>` provenance (a `CFG_SRC_<name>=default` file marker demotes a saved value to `default`; `invalid` inputs rejected into `SETTING_NOTES`, files untouched); the documented `PR_AGENT_*` env name is passed explicitly (six differ from `PR_AGENT_<setting>` — `MODE`→`PERM_MODE` etc.); `setting_src`, `apply_status_defaults`, `save_config` (v2 header; persists only env|saved-provenance keys — defaults stay unpinned; `CFG_SRC_*` lines are managed, foreign lines preserved), `log`, `notify` (osascript) |
| repo context | 274–296 | `repo`/`repo_dir`/`me` accessors, `need_repo`, `detect_repo` (writes repo, repo_dir, me, base into state) |
| map | 297–325 | `map.json` accessors (`map_get/set/del/rm/num`) behind `with_map_lock` (mkdir lock, ~10 s stale break) |
| PR list | 326–423 | `refresh_prs` — one `gh pr list` call → `prs.jsonl` cache (number, title, state, draft, review, updated, branch, head, base, mergeable, ci, ci_failed, body, cross, author — `review` is `reviewDecision`, derived from non-author `reviews` (latest opinionated per reviewer) when empty); `backfill_prs` — one `gh pr view` per tracked PR missing from both caches → `prs_extra.jsonl` (once each ever); `pr_info` (list first, extras fallback), `targets` ("all" mode scoped by `PR_AUTHOR_FILTER` via `PR_AUTHOR_JQ`), `scope_label` (that scope as display text) |
| feedback collection | 424–501 | `fetch_feedback` (3 `gh api` endpoints + `synthetic_feedback`), `seed_seen`, `filter_feedback` (seen/author/bot/skip rules), `pending_feedback` |
| failed review runs | 502–623 | `handle_review_failure` + helpers (`retry_cutoff`, `review_failure_plan`, `retry_reset_if_reviewed`) — pings the review bot (`RETRY_MSG`) on `Review failed:` notices, `RETRY_MAX` cap, `retry_cutoff` keeps pre-existing failures manual-only |
| formatting | 624–640 | `format_feedback` — jsonl → markdown prompt sections |
| worktree | 641–731 | `ensure_worktree` (`<repo>-pr-<N>` next to the main checkout), `worktree_holding`/`still_blocked` (local-only `git worktree list` probes — `still_blocked` rc: 0 blocked / 1 confirmed free / 2 indeterminate), `setup_worktree` (copies `.env*`/`config.local.json`, reuses `node_modules` when manifests match else `bun install --frozen-lockfile`, husky prepare), `sync_worktree` |
| main-sync | 732–988 | Post-merge catch-up: `sync_scan` → `check_sync` merges base into PR branch **via the PR's agent session**, then `verify_synced` + `apply_unblock` (dep-gated draft unbanner/ready, `sync_unblock` state machine); rc 4 defers like a busy session — no `sync_fails`; `sync_scan watch` skips `worktree_blocked` PRs outright |
| agent | 989–1090 | `build_prompt`, `devin_flags`, `session_ids`/`new_session_id` (diff `devin list` before/after), `run_agent` (resume `devin -r` else start new; `ensure_worktree` rc 4 → `worktree_blocked`) |
| per-PR check | 1091–1166 | `check_pr` — the per-PR round; `skip_reason` |
| watcher | 1167–1329 | `watch_loop` (re-cd's to `repo_dir` each cycle; re-probes `worktree_blocked` PRs via `still_blocked`), `pid_is_watcher`/`is_running`, `pr_sig`, `install_launchd` (launchd plist), `cmd_on`, `kill_agents`, `cmd_off` |
| manual commands | 1330–1546 | `need_pr`/`need_real_pr`/`gh_err_not_pr` (every command acting on a user-supplied N — `on`/`add` targets included — resolves it through `need_real_pr`'s `gh pr view` first, `sync --apply` excepted (own resolution); `gh_err_not_pr` reads the stderr — only "Could not resolve to a PullRequest" marks a non-PR), `run`, `tell`/`_tell`, `attach`, `retry`, `peek`, `mark-seen`, `forget_pr`, `gc`, `sync`, `config`, `logs` (`version` is a dispatch one-liner) |
| self-update | 1547–1668 | `ver_gt`, `latest_release_tag`, `cmd_update` — downloads release assets from `UPDATE_REPO`, verifies sha256, atomic-installs over the (symlink-resolved) install; `maybe_update_check`/`pending_update_version` — throttled background release check (OMZ-style), both gated on `UPDATE_CHECK` |
| status rendering | 1669–2162 | `fmt_*`, `trunc`/`pad`/`wrap` (TITLE cells wrap to `TITLE_LINES` lines), `vis_len`/`phys_lines` (ANSI-stripped soft-wrap count), `draw_*`, `status_prs`, `refresh_status_pending`, `refresh_blocked_flags` (lazy `still_blocked` re-probe — clears a freed flag even with the watcher off), `review_cell`/`state_cell` (side effects: `H_*` hint buckets), `recent_events`, `render_hint`, `render_status` (TABLE_ROWS-capped table), `cmd_status` (alt-screen watch loop + fallback clip), `usage` |
| dispatch | 2163–end | `case "$1"` router (`usage` sits just above the banner) — inline cases: `add`/`rm`, `pause`/`resume`, `reset`, `reset-rounds`, `map`, `version`, `help`; `_loop`/`_check`/`_tell`/`_ensure`/`_blocked` are internal entries. `maybe_update_check` runs just before dispatch; the notice is skipped for internal/machine-readable commands (`_loop` logs it) |

## On-disk state

`$PR_AGENT_STATE_DIR` (default `~/.local/state/pr-agent`):

```
<root>/
  current                      # repo slug last `on`ed (used outside a repo)
  update_check.ts              # epoch of the last release check (throttle)
  latest_release               # newest upstream tag seen by the update check
  repos/<owner>__<repo>/
    repo repo_dir me base      # written by detect_repo
    targets                    # "all" or explicit PR numbers
    config                     # CFG_* env/saved settings pinned by `pr-agent on` (v2 header; defaults stay unpinned, foreign lines preserved)
    pid                        # watcher pid
    map.json                   # PR → session/worktree/counters (see below)
    map.lock                   # mkdir lock dir for map writes
    watch.log                  # event log (drives "recent activity")
    prs.jsonl                  # PR list cache (one object per PR; newest ~100)
    prs_extra.jsonl            # same objects for tracked PRs that aged out of the list window
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
worktree_blocked, blocked_logged, sync_*, retry_*}}}` — all values strings;
`map_num` coerces empty → 0.

Feedback items are jsonl `{key, ts, kind, author, body, url, …}` with
`kind ∈ review|line|comment|ci|conflict`. `key` embeds id + body-length or
`updated_at`, so edited items re-trigger. `seen/<pr>` holds handled keys.

## Flows

### `pr-agent on [--launchd] [all|N…]`

`detect_repo` → `need_real_pr` per explicit N → write `targets` → `save_config` → spawn `pr-agent _loop`:
`nohup … &` normally, or a `~/Library/LaunchAgents/dev.pr-agent.<slug>.plist`
bootstrapped with `KeepAlive` when `--launchd`. `_loop` = `watch_loop` in the
same script.

### Poll cycle (`watch_loop`, every `INTERVAL`s)

```
refresh_prs 0                      # one gh pr list; failure → gh_error + warn once
for pr in $(targets):              # all open non-draft PRs (PR_AUTHOR_FILTER scope), or explicit list
    worktree_blocked → still_blocked (local `git worktree list` probe, no gh
        calls): blocked or indeterminate (repo unreadable) → skip, flag kept;
        confirmed free → clear flag + sig → fall through
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
  rc 4 → worktree blocked (PR branch checked out in the main checkout):
         not an agent failure — no fail_count/escalation; status shows
         "worktree blocked" and notifies once per block. Freeing the branch
         is local — invisible to pr_sig — so the watcher re-probes each poll
         and runs the round the poll it frees. run_agent clears the flag on
         any non-4 prep outcome; check_sync defers rc 4 like a busy session
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
the retry path) AND not bot status narration — `[bot]`/`BOTS` comment items
matching `BOT_STATUS_RE` are filtered (reviews and line comments always pass,
so findings can't be status-filtered) so placeholder chatter can't spawn
rounds — AND
one of:

- synthetic CI/conflict item (opt-in), or
- authored by you and starting with `TRIGGER` (`/agent`), or
- authored by someone else where `AUTHOR_FILTER` includes them — empty filter
  means anyone except `[bot]` logins not listed in `BOTS`.

### Status screen (`render_status [ttl] [term-rows] [watch-every]`)

Header (watcher state, targets, settings, poll countdown) → PR table:
`status_prs` = watch targets ∪ PRs with map history, **most recent activity
first** (max of `updated`, `last_seen_ts`, `last_run_at`), then **open first,
merged/closed dimmed** via the two render passes. One pre-pass walks the PRs
in that draw order: `review_cell`/`state_cell` render the REVIEW and AGENT
STATE cells once each (cached in the `o*` arrays for the draw loop) and fill
the `H_*` buckets that pick the one-line `render_hint` — the hint text is
therefore known before the table is drawn. Then a blank line,
`recent activity` (last `ACTIVITY_LINES` deduped `watch.log` events — the
whole section is hidden when `ACTIVITY_LINES=0`), the hint, and in `-w` mode
the `live · refresh` footer.

Cells pad to `width+2` (`␣content│`). The TITLE column auto-fits the space the
fixed columns leave (`cols − fixed − 2n − 1`, ≤100); when that would fall
below 25, `LAST RUN` then `ROUNDS` are dropped to claw width back (`TITLE_W`
pins the width and skips this — the saved value is a logical width, never
rewritten to the screen). Each TITLE cell wraps over up to `TITLE_LINES`
physical lines (`1` = truncate, `0` = no cap) via `wrap` — word-boundary
greedy, longer words hard-split, over-cap remainder folded into a `…`-ended
last line — while the other cells render on the row's first line. The first
wrapped line is capped at `title_w`; continuation lines wrap at a
*merged-cell* width (`draw_span` draws one cell over TITLE..last column) so
a title typically completes in 2 lines. `TITLE_LINES` resolves env → saved →
mode default: `apply_status_defaults` gives interactive (`-w`) `0` and plain
`status` `3` when neither env nor a saved value exists (provenance
`mode-default`), and the cap is **never** shrunk to fit the screen — a saved
legacy `CFG_TITLE_LINES=3` stays authoritative in both modes.

`TABLE_ROWS` counts **records**, not screen lines: `0` (default) renders every
record in draw order and `N` keeps the first `N`, collapsing the rest into the
`… N more — TABLE_ROWS=N` row (`N` counts PRs; records are never dropped for
terminal height). In `-w` mode `cmd_status` repaints on the alt screen: it
passes `tput lines` to `render_status` (reserved for viewport use) and clips
the composed frame itself — `phys_lines` measures each logical frame line
(ANSI-stripped, soft-wrap counted at `cols`), keeps the prefix that fits
`rows − 1`, and appends `… N more lines` (the clip line names `TABLE_ROWS`
when a cap is set). A wrapped title, a soft-wrapped header, or a pinned-wide
`TITLE_W` table all overflow into the clip rather than scrolling — a real
scroll viewport is future work; until then the clip message is the hint.

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
