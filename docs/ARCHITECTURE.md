# Architecture

`pr-agent` is a single bash script (~2420 lines). It polls GitHub for new PR
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
| per-repo state | 118–157 | `slug_of`, `git_repo_name`, `migrate_legacy_state` (pre-per-repo flat layout → `repos/<slug>`), `resolve_repo_slug` → `REPO_SLUG`, `STATE_DIR` + state paths (`PID_FILE`, `MAP_FILE`, `LOG_FILE`, `PRS_CACHE`, `PRS_EXTRA`, `PRS_LOCK`) |
| settings | 158–280 | `SETTINGS`/`DISPLAY_SETTINGS` key lists, `resolve_str`/`resolve_num`/`load_settings` — env → saved `CFG_*` → default resolution with `SRC_<name>` provenance (a `CFG_SRC_<name>=default` file marker demotes a saved value to `default`, but `cfg_src` gates the consult to `DISPLAY_SETTINGS` keys — foreign markers are inert; `invalid` inputs rejected into `SETTING_NOTES`, files untouched); the documented `PR_AGENT_*` env name is passed explicitly (six differ from `PR_AGENT_<setting>` — `MODE`→`PERM_MODE` etc.); `setting_src`, `apply_status_defaults`, `save_config` (v2 header; persists only env|saved-provenance keys — defaults stay unpinned; `CFG_SRC_*` lines are managed, foreign lines preserved), `log`, `notify` (osascript) |
| repo context | 281–303 | `repo`/`repo_dir`/`me` accessors, `need_repo`, `detect_repo` (writes repo, repo_dir, me, base into state) |
| map | 304–336 | `map.json` accessors (`map_get/set/del/rm/num`) behind `with_map_lock`; `with_lock` is the generic mkdir lock (~10 s stale break) |
| PR list | 337–444 | `refresh_prs` — one `gh pr list` call → `prs.jsonl` cache, published tmp+`mv` (number, title, state, draft, review, updated, branch, head, base, mergeable, ci, ci_failed, body, cross, author — `review` is `reviewDecision`, derived from non-author `reviews` (latest opinionated per reviewer) when empty); `backfill_prs` — one `gh pr view` per tracked PR missing from both caches → `prs_extra.jsonl` (once each ever; `prs_extra_merge` appends under `prs.lock` + tmp/`mv` so concurrent dashboards never see a partial file); `pr_info` (list first, extras fallback), `targets` ("all" mode scoped by `PR_AUTHOR_FILTER` via `PR_AUTHOR_JQ`), `scope_label` (that scope as display text) |
| feedback collection | 445–523 | `fetch_feedback` (3 `gh api` endpoints + `synthetic_feedback`), `seed_seen`, `filter_feedback` (seen/author/bot/skip rules; optional seen-file arg so status can count without touching watcher markers), `pending_feedback` |
| failed review runs | 524–645 | `handle_review_failure` + helpers (`retry_cutoff`, `review_failure_plan`, `retry_reset_if_reviewed`) — pings the review bot (`RETRY_MSG`) on `Review failed:` notices, `RETRY_MAX` cap, `retry_cutoff` keeps pre-existing failures manual-only |
| formatting | 646–662 | `format_feedback` — jsonl → markdown prompt sections |
| worktree | 663–753 | `ensure_worktree` (`<repo>-pr-<N>` next to the main checkout), `worktree_holding`/`still_blocked` (local-only `git worktree list` probes — `still_blocked` rc: 0 blocked / 1 confirmed free / 2 indeterminate), `setup_worktree` (copies `.env*`/`config.local.json`, reuses `node_modules` when manifests match else `bun install --frozen-lockfile`, husky prepare), `sync_worktree` |
| main-sync | 754–1010 | Post-merge catch-up: `sync_scan` → `check_sync` merges base into PR branch **via the PR's agent session**, then `verify_synced` + `apply_unblock` (dep-gated draft unbanner/ready, `sync_unblock` state machine); rc 4 defers like a busy session — no `sync_fails`; `sync_scan watch` skips `worktree_blocked` PRs outright |
| agent | 1011–1112 | `build_prompt`, `devin_flags`, `session_ids`/`new_session_id` (diff `devin list` before/after), `run_agent` (resume `devin -r` else start new; `ensure_worktree` rc 4 → `worktree_blocked`) |
| per-PR check | 1113–1188 | `check_pr` — the per-PR round; `skip_reason` |
| watcher | 1189–1351 | `watch_loop` (re-cd's to `repo_dir` each cycle; re-probes `worktree_blocked` PRs via `still_blocked`), `pid_is_watcher`/`is_running`, `pr_sig`, `install_launchd` (launchd plist), `cmd_on`, `kill_agents`, `cmd_off` |
| manual commands | 1352–1568 | `need_pr`/`need_real_pr`/`gh_err_not_pr` (every command acting on a user-supplied N — `on`/`add` targets included — resolves it through `need_real_pr`'s `gh pr view` first, `sync --apply` excepted (own resolution); `gh_err_not_pr` reads the stderr — only "Could not resolve to a PullRequest" marks a non-PR), `run`, `tell`/`_tell`, `attach`, `retry`, `peek`, `mark-seen`, `forget_pr`, `gc`, `sync`, `config`, `logs` (`version` is a dispatch one-liner) |
| self-update | 1569–1690 | `ver_gt`, `latest_release_tag`, `cmd_update` — downloads release assets from `UPDATE_REPO`, verifies sha256, atomic-installs over the (symlink-resolved) install; `maybe_update_check`/`pending_update_version` — throttled background release check (OMZ-style), both gated on `UPDATE_CHECK` |
| status rendering | 1693–2553 | `fmt_*`, `cell_ops` — one `LC_ALL=C` awk engine for display-cell ops (UTF-8 decode → wcwidth-style classes; ANSI escapes transparent): `len`/`max`/`ws`/`cut`/`trunc`/`proj`/`clip`/`pos` — backing `trunc`/`pad`/`vis_len`/`phys_lines`/`wrap` so `${#var}` is never used as a display width — `draw_*`, `status_prs`, `status_pending_count`/`refresh_status_pending` (pending counts without `seed_seen` — an absent marker gets `last_seen_ts` applied in memory), `refresh_blocked_flags` (lazy `still_blocked` re-probe — clears a freed flag even with the watcher off), `recent_event_groups`/`recent_events`, `status_gather` — emits the versioned JSON snapshot and is the *only* side-effecting stage (cache refresh + lock-protected blocked-flag maintenance); `review_cell`/`state_cell` (pure: read the record's snapshot fields; only side effect is the `H_*` hint buckets), `render_hint`, `status_layout` — pure paint: builds the logical grid, then prints it whole (plain) or horizontally projects it into the viewport behind a frozen PR gutter (`watch-every`/`hoff`) + optional per-record `meta-out` anchors, `render_status` (gather → temp file → layout), `cmd_status` (alt-screen watch loop + `cell_ops clip` frame clip), `usage` |
| dispatch | 2554–end | `case "$1"` router (`usage` sits just above the banner) — inline cases: `add`/`rm`, `pause`/`resume`, `reset`, `reset-rounds`, `map`, `version`, `help`; `_loop`/`_check`/`_tell`/`_ensure`/`_blocked`/`_gather`/`_layout` are internal entries (`_gather` prints the status snapshot, `_layout` renders one — `tests/status_snapshot.sh` and `tests/status_grid.sh` drive both). `maybe_update_check` runs just before dispatch; the notice is skipped for internal/machine-readable commands (`_loop` logs it) |

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
    prs.jsonl                  # PR list cache (one object per PR; newest ~100; published tmp+mv)
    prs_extra.jsonl            # same objects for tracked PRs that aged out of the list window
    prs.lock                   # mkdir lock dir serializing prs_extra merges
    gh_error                   # exists ⇔ last refresh_prs failed
    cycle_active / last_cycle  # poll-in-progress marker / last poll epoch
    status_pending             # "pr count" lines — counted without seeding seen markers
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

### Status screen (`status_gather` → snapshot → `status_layout`)

`render_status [ttl] [term-rows] [watch-every]` orchestrates two stages through
a temp file so the data/paint boundary is explicit rather than a set of
command-substitution globals:

- **`status_gather <ttl>`** — the only side-effecting stage; prints a versioned
  JSON snapshot on stdout (exportable across subshell/worker boundaries —
  `_gather` dispatches to it). Side effects, all enumerated: `refresh_prs` /
  `backfill_prs` → `prs.jsonl`/`prs_extra.jsonl`/`gh_error`,
  `refresh_status_pending` → `status_pending` (counts via
  `status_pending_count`, never `seed_seen` — an absent marker gets
  `last_seen_ts` applied in memory), `refresh_blocked_flags` (lock-protected
  `map_del`s), `map_init`. Everything else is a read: markers, `map.json`,
  `targets`, `watch.log`, pid/cycle files. The snapshot carries the clock
  (`now`), watcher/poll state, resolved display `cfg`, `watch`/`update`/
  `gh_error`, an ordered `prs` array (`status_prs` order — identity, state,
  review/draft, raw title, pending, rounds/fail counts, skip, blocked/sync
  flags, agent marker, session id, last-run epoch, model evidence), and the
  collapsed `activity` groups.
- **`status_layout <snap> <cols> [term-rows] [watch-every] [meta-out] [hoff]`** —
  pure paint: validates the snapshot is complete (`v` + required blocks —
  incomplete input is rejected), freezes the clock to `snapshot.now` so
  repeated paints are byte-identical, and touches no `gh`/Devin calls, no
  worktree probes, no config/map/seen writes — repaints and resizes repeat it
  freely. `meta-out` optionally receives a geometry line (cols, title_w,
  gutter, logical_w, hoff, projected, spans/caps) plus per-record frame-line
  anchors (jsonl) for scroll/resize consumers.

Layout composes the frame: header (watcher state, targets, settings, poll
countdown) → PR table → activity → hint (→ `-w` footer). `status_prs` = watch
targets ∪ PRs with map history, **most recent activity first** (max of
`updated`, `last_seen_ts`, `last_run_at`), then **open first, merged/closed
dimmed** via the two render passes over the snapshot records. One pre-pass
walks the records in that draw order: `review_cell`/`state_cell` render the
REVIEW and AGENT STATE cells once each (cached in the `o*` arrays for the
draw loop) and fill the `H_*` buckets that pick the one-line `render_hint` —
the hint text is therefore known before the table is drawn, and covers
records beyond any `TABLE_ROWS` cap.

The table is a **logical grid** built at its own width, then emitted whole
(plain `status` — the complete grid prints; a narrow terminal may soft-wrap
that noninteractive output so nothing is unreachable) or **projected** into
the bounded `-w` viewport. Cells reserve one space on both sides
(`␣content␣│`); core columns are `PR | TITLE | REVIEW | AGENT STATE | ROUNDS |
MODEL` (`MODEL` shows `—` until session-model data lands), every metadata
column measured at its real heading/content width via `cell_ops max` — long
agent states and model ids scroll off-screen rather than being truncated.
`TITLE` gets the largest useful width beside the frozen PR gutter:
`min(widest title cell, cols − gutter)` — content- and viewport-bounded, no
fixed minimum and no old 100-char ceiling; a positive `TITLE_W` pins the
logical width verbatim, even when oversized. `LAST RUN` and `SESSION` are
optional and join only when they fully fit the width left after the core
columns. Each TITLE cell wraps over up to `TITLE_LINES` lines (`1` =
truncate, `0` = no cap) at that one logical width via `wrap` — word-boundary
greedy in display cells (CJK 2, combining/ANSI 0), over-wide words hard-split,
over-cap remainder folded into a `…`-ended last line — while the other cells
render on the row's first line and continuation lines keep blank metadata
cells (the `… N more` cap row stays one line via `draw_span`'s merged
TITLE..last cell). `TITLE_LINES` resolves env → saved → mode default:
`apply_status_defaults` gives interactive (`-w`) `0` and plain `status` `3`
when neither env nor a saved value exists (provenance `mode-default`), and
the cap is **never** shrunk to fit the screen — a saved legacy
`CFG_TITLE_LINES=3` stays authoritative in both modes.

`TABLE_ROWS` counts **records**, not screen lines: `0` (default) renders every
record in draw order and `N` keeps the first `N`, collapsing the rest into the
`… N more — TABLE_ROWS=N` row (`N` counts PRs; records are never dropped for
terminal height). In `-w` mode the table lines pass through `cell_ops proj`:
the `[0,gutter)` PR prefix stays frozen and the window emits logical cells
`[gutter+hoff, cols)` — wrap points and record heights never change under
horizontal movement, lines never soft-wrap, and each line is `C_RESET`-
terminated so clipped styles can't bleed. `term-rows` shrinks optional chrome
first — the activity section emits at most the count that leaves the body
intact (header + hint + footer are the last to go) — and `cmd_status` then
clips the composed frame: `cell_ops clip` counts physical height (ANSI-stripped,
soft-wrap at `cols`), keeps the prefix that fits `rows − 1`, and returns a
sentinel so `cmd_status` can append `… N more lines` (naming `TABLE_ROWS`
when a cap is set). Very small terminals (`cols < 30` or `rows < 8`) get a
compact safe state instead of a clipped grid. Keyboard scrolling is future
work — `hoff` is the seam it plugs into.

### Concurrency & locking

- `map.lock` (mkdir) serializes `map.json` writes; stale locks broken ~10 s.
- `prs.lock` (mkdir) serializes `prs_extra.jsonl` merges; every shared cache
  (`prs.jsonl`, `prs_extra.jsonl`, `status_pending`) is published tmp+`mv`, so
  concurrent dashboards/watchers never read a partial file.
- `seen/<pr>` markers belong to the watcher/check_pr path — status counting
  never creates or rewrites them (absent markers get `last_seen_ts` applied
  in memory), which keeps older watchers' semantics intact.
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
