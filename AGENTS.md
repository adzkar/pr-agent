# pr-agent — agent rules

> Read this before editing. The whole tool is **one file**: `pr-agent`
> (~3300 lines of bash). The canonical docs are `README.md` (usage) and
> `docs/ARCHITECTURE.md` (code map + flows) — read the architecture doc
> before touching anything past line 100.

## Repo layout

| Path | What it is |
| --- | --- |
| `pr-agent` | The entire tool — a self-contained bash script, no build step |
| `README.md` | User docs: install, commands, dashboard, config |
| `docs/ARCHITECTURE.md` | Code structure map, state files, execution flows |
| `docs/RELEASING.md` | Step-by-step release guide for maintainers |
| `release` | Maintainer script — cuts versioned GitHub releases (`./release [patch|minor|major|X.Y.Z]`) |
| `tests/` | `release.sh` — scratch-repo + stubbed-`gh` harness for `release` and `update` (incl. failed/truncated downloads, failed stage cleanup, stale staged files, and rollback); `update-check.sh` — extracted-function harness for `maybe_update_check`/`pending_update_version` |
| `tests/smoke.sh` | Scratch-repo smoke for the worktree-blocked lifecycle (local git only) |
| `tests/review_verdict.sh` | Fixture checks for the `PR_JQ` `.review` verdict derivation (jq only) |
| `tests/author_match.sh` | Extracted-function fixtures for case-insensitive author/login matching (jq only) |
| `tests/title_wrap.sh` | Extracted-function fixtures for `wrap` — the status TITLE column's multi-line cell wrap (bash only) |
| `tests/display-settings.sh` | Extracted-function fixtures for the settings resolver — precedence, `SRC_*` provenance, invalid-input notes (bash only) |
| `tests/status_snapshot.sh` | Scratch-state + stubbed-`gh` fixtures for the status gather/snapshot/layout split — record data, ordering, pending counts without `seen` writes, layout purity, incomplete-snapshot rejection, concurrent gathers |
| `tests/status_grid.sh` | Handcrafted-snapshot fixtures driving `_layout` — logical-grid geometry (measured columns, TITLE allocation, optional LAST RUN/SESSION, pinned `TITLE_W`), bounded projection + `hoff`, blank-cell continuations, unicode/ANSI cells, compact tiny-terminal state |
| `tests/status_nav.sh` | Extracted-function fixtures for the `-w` machinery — the `status_key` byte→key decoder (CSI/SS3, partial sequences, unknown-final requeue), `key_nav` clamps, `status_anchor` re-anchoring across rebuilds/evictions/resizes, `status_meta` geometry + record anchors |
| `tests/status_model.sh` | Scratch-state + real-sqlite fixtures for the session-model adapter — exact sid+worktree match, selected-model/router truthfulness (`adaptive` stays `adaptive`), switch/reset refresh, canonicalized dirs, repo-dir fallback, cross-repo isolation, missing/corrupt/old-schema/`sqlite3`-less sources degrade to `unknown`, read-only acquisition |
| `tests/status_pty.sh` + `tests/status_pty.py` | Real-PTY end-to-end for `status -w` — seeded scratch state (ten wrap-length records, one CJK) + stubbed `gh`/`mktemp`; two-axis navigation and bounds, frame physically bounded at every size, compact safe state, alt-screen/cursor/termios restoration on `q`, SIGINT, SIGTERM, and input EOF, `NO_COLOR`, garbage input, garbage `-w` intervals, `TERM=dumb` capability loss, legacy saved caps honored under `-w`, redirected-stdio single-snapshot checks, quit during persistent gather failure, mid-gather-SIGINT tempfile cleanup, worker bound-out keeps the stale snapshot, sustained key bursts can't postpone the refresh deadline, a hung model probe can't stall records, tempfile-leak asserts, and the "navigation never gathers" bound |
| `tests/upgrade.sh` | Upgrade-survival fixtures — a headerless pre-v2 config resolves saved/inert-marked values and stays byte-identical through `config`/`status`, old map/seen/log/session state survives gather + layout, a simulated older watcher's writes coexist (only the allowed blocked-flag maintenance differs), and a real `v0.3.0` binary rolled back onto post-upgrade state keeps working |
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
artifacts `pr-agent update` downloads. Notes are grouped from the PRs
merged since the previous tag (`feat:`/`fix:` sections, the rest under
Other); a range with no merged PRs falls back to `--generate-notes`.
Interrupted runs resume — the tag is (re)anchored at `HEAD` and assets
(re)uploaded — and `./release X.Y.Z` mints the checked-in `VERSION` if it
was never released.

## Verify before committing

The scratch-repo harnesses cover what CI doesn't: `tests/smoke.sh`
exercises the worktree-blocked lifecycle on local git alone;
`tests/review_verdict.sh` runs the `PR_JQ` verdict derivation over fixture
payloads; `tests/author_match.sh` lifts the author-matching jq out of
`pr-agent` and checks configured-vs-API login casing; `tests/release.sh`
drives the `release` state machine and `cmd_update` end-to-end with a
stubbed `gh`; `tests/update-check.sh` extracts the update-check functions
from `pr-agent` and exercises the stamp/throttle edge cases; `display-settings.sh`
extracts the settings resolver and checks precedence/provenance/invalid inputs;
`tests/status_snapshot.sh` drives `_gather`/`_layout` over a scratch state dir
and checks the snapshot contract + layout purity; `tests/status_grid.sh` drives
`_layout` over handcrafted snapshots and checks grid geometry + projection;
`tests/status_model.sh` drives `_gather` over a real sqlite sessions index and
checks the model adapter's matching, truthfulness, and failure fallbacks;
`tests/upgrade.sh` runs a pre-milestone install's config + state + a rolled-back
release through the new status. Minimum checks:

```sh
bash -n pr-agent                       # syntax
bash -n release                        # syntax
shellcheck pr-agent release 2>/dev/null || true # lint if available
tests/smoke.sh                         # worktree-blocked lifecycle in a scratch repo (no gh)
tests/review_verdict.sh                # .review verdict derivation fixtures (no gh)
tests/author_match.sh                  # author/login matching fixtures (no gh)
tests/title_wrap.sh                    # TITLE-cell wrap fixtures (no gh)
tests/display-settings.sh              # settings precedence/provenance fixtures (no gh)
tests/status_snapshot.sh               # gather/snapshot/layout fixtures (stubbed gh)
tests/status_grid.sh                   # grid geometry + projection fixtures (handcrafted snapshots)
tests/status_nav.sh                    # -w decoder/nav-clamp/anchor fixtures (extracted functions)
tests/status_model.sh                  # sessions-index model adapter fixtures (real sqlite3)
tests/status_pty.sh                    # real-PTY interactive run: nav, bounds, lifecycle, NO_COLOR
tests/upgrade.sh                       # legacy config/state/watcher/rollback survival (stubbed gh)
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
- **`state_cell`/`review_cell` still have a side effect** — they populate the
  `H_*` hint buckets that drive the bottom "what now" line. `state_cell` is
  otherwise pure: it reads the record's `S_*` snapshot fields (agent marker,
  blocked/sync flags, skip, fail/round counters — `status_layout`'s pre-pass
  sets them per record) and must never probe markers, `map.json`, `seen/`, or
  `pr_info` — those reads belong to `status_gather`. The pre-pass calls both
  cells once per record (open pass, then done pass) and caches the cells in
  the `o*` arrays for the draw loop — so the hint sees every tracked PR, not
  just the ones the screen shows.
- **Status is gather → snapshot → pure layout.** `status_gather` is the only
  side-effecting stage (enumerated in its comment: prs/pending/blocked-flag
  cache refreshes + `map_init`); `status_layout` renders the frame from the
  snapshot file alone — no `gh`/Devin calls, no worktree probes, no
  config/map/seen writes — so `-w` repaints and resizes may repeat it freely.
  Snapshot fields cross stages as `\x1f`-joined TSV rows (`IFS=$'\x1f'`,
  non-whitespace — tab IFS would collapse empty fields); the layout clock is
  frozen to `snapshot.now` via `SNOW` so repeat paints are byte-identical;
  and empty `lines`/`meta_rec` arrays need a `${#a[@]} -gt 0` guard before
  `"${a[@]}"` under bash 3.2 `set -u`.
- **`state_cell` precedence is deliberate** — working/interrupted →
  merged/closed → `worktree_blocked` → `sync_blocked`/`sync_pending` →
  `skip_reason` (paused/round-limit/approved) → pending items → idle. The
  sync cells must stay above `skip_reason`: `sync_blocked` is a sticky
  "needs you" state for approved/paused PRs the watcher itself skips.
- **`save_config` v2 preserves foreign lines and records display-key
  provenance.** The rewrite drops only managed lines (`CFG_<each SETTINGS
  key>` + every `CFG_SRC_*` — the marker namespace is tool-owned) and the
  tool's own `# pr-agent config v<N>` header — the strip is anchored
  (`^# pr-agent config v?[0-9]* *$`) so a foreign `# pr-agent config …`
  comment survives, as do other comments and unknown `CFG_*` keys. For
  `DISPLAY_SETTINGS` keys it appends `CFG_SRC_<k>=default` when the resolved
  provenance is `default`, and the resolvers demote such values back to
  `default` on load — so a `pr-agent on` run can't fossilize an inherited
  default into a saved choice. Markers govern `DISPLAY_SETTINGS` keys only
  (`cfg_src` gates the consult): a foreign `CFG_SRC_INTERVAL=default` can't
  shadow `CFG_INTERVAL` — inert on load, dropped on resave. Env/saved
  provenance writes no marker and stays authoritative. `status`/`config`/
  `update` never call `save_config`; fixtures check byte-identical configs.
- **The status table draws every selected record — no fit-budget.**
  `TABLE_ROWS` counts *records* (`0` = all render; `N` = first `N`, rest
  collapse into the `… N more — TABLE_ROWS=N` row), and `TITLE_LINES` is a
  resolved user cap that's **never** shrunk for screen fit — env → saved →
  mode default via `apply_status_defaults` (interactive `0`, plain `3`, only
  when provenance is `default`; a saved legacy `3` stays authoritative in
  `-w`). Vertical overflow belongs to the `-w` frame clip in `cmd_status`
  (`cell_ops clip` counts *physical* lines — ANSI-stripped soft-wrap — keeps
  the prefix fitting `rows − 1`, sentinel line reports the drop).
- **The grid is logical, the viewport a projection.** `status_layout` builds
  the table at its own width — core `PR | TITLE | REVIEW | AGENT STATE |
  ROUNDS | MODEL` at *measured* cell widths (`cell_ops max` per column over
  heading + every cell; never squeezed or dropped), TITLE at
  `min(widest title, cols − gutter)` when `TITLE_W=0`, the pin verbatim
  otherwise (floored at the heading's 5 cells) — then `-w` projects each line
  into `cols` cells behind a frozen
  `[0,gutter)` PR prefix at horizontal offset `hoff` (`cell_ops proj`;
  `_layout`'s 6th arg) while plain `status` prints it whole. Vertically the
  `-w` body scrolls a `[voff, voff+ST_VREG)` window of the full logical table
  between pinned top/bottom rules — every body line is reachable. `LAST RUN` and
  `SESSION` join only when they fully fit leftover viewport width; cells are
  `␣content␣│` — one space both sides, so rule/row/span formulas move
  together (`Σ COL_W + 3n + 1`). TITLE wraps at *one* logical width via
  `wrap` (result in `WRAP_LINES`, widths in `WRAP_W`) — continuations are
  regular rows with blank metadata cells; only the `… N more` cap row merges
  TITLE..last via `draw_span`. `term-rows` shrinks the activity section
  before the frame clip can starve the body; `cols < 30` or `rows < 8` gets
  a compact safe state. All of this is layout-side: `status_layout` reads
  resolved values from the snapshot's `cfg` block, never the process env.
- **`${#var}` is a char count, not a display width.** Everything that
  measures, pads, cuts, or projects display text goes through `cell_ops` —
  one `LC_ALL=C` awk program (UTF-8 decode → wcwidth-style classes: CJK/emoji
  2 cells, combining/format/ANSI escapes 0, ASCII 1). awk quirks that have
  already bitten: **BSD awk doesn't parse `0xNNN` literals** (they evaluate
  to 0 — use decimal) and doesn't allow bare newlines mid-statement.
  `wrap`'s per-char widths come from one `ws` pass per title, the grid's
  column widths from one `max` pass per frame — don't reintroduce per-cell
  subprocess calls into the draw loop. But char count *follows the ambient
  locale*: under `LC_ALL=C`, `${#var}` counts bytes and `${var:i:j}`
  byte-slices (splitting UTF-8 mid-codepoint) while `wcs[]` stays
  per-codepoint — `wrap` pins `local LC_ALL=en_US.UTF-8` so its own
  index/length math always matches `wcs[]`. Any function that mixes bash
  string ops with cell_ops codepoint indexing needs the same pin.
- **`save_config` pins only `env`/`saved`-provenance keys.** `pr-agent on`
  snapshots `CFG_*` for the detached watcher, but a key still at its resolver
  `default` (or `mode-default`) stays unwritten — writing it would pin the
  plain-mode `3` at `on` time and make `apply_status_defaults`'s `-w` `0`
  unreachable for every watched repo. Keep the `case` guard on provenance,
  never on the key name: it also keeps generated fallbacks (e.g. `RETRY_MSG`'s
  template) from being frozen as `saved`.
- **`status -w` owns the terminal until it hands it back.** `status_watch`
  saves `stty -g`, enters the alternate screen + hides the cursor, sets
  `-icanon -echo` (ISIG kept — ^C stays a signal), and installs an `EXIT`
  trap that restores everything — never return from the loop without going
  through it. Signals are **deferred**: `INT`/`TERM`/`HUP` only set
  `WATCH_SIG`, `WINCH` sets `WATCH_RESIZE`, and the input loop drains the
  flags through the ordinary quit/repaint paths — doing kills + termios
  restores inside a trap handler SIGSEGV'd bash mid-`read` (the trap fires
  while the shell is inside `wait`/builtin machinery). `set -m` job-control
  is worse: non-interactive monitor mode hands each spawned command its own
  pgrp without the foreground handoff, so `stty`/`tput` in the exit path
  catch SIGTTOU and stop forever — don't reintroduce it. The gather is a
  **background worker**: the parent loop only reads `$(date +%s)` deadlines,
  `$snap.done`, and `status_key` bytes — it never calls `status_gather`
  itself, so nav/resize/repaint can't block on GitHub. The worker writes
  `$snap.new` then `$snap.done` (tmp+`mv`); the parent adopts only a
  `snapshot_valid` doc — a killed/failed gather leaves the last snapshot
  marked `⚠ refresh failed`. `next_gather` is advanced **at spawn**, not at
  completion — setting it to 0 or forgetting the `[ -z "$w_pid" ]` guard
  made the deadline fire every pass and fork-spun the loop at ~100% CPU.
  `worker_kill` sweeps the worker's descendant tree via `pgrep -P` *while
  still parented* (once the worker dies the kids reparent to launchd and
  become invisible); `run_bounded`'s `wait` is `|| rc=$?`-guarded because a
  TERM'd bounded command returns >128 and `set -e` would otherwise kill the
  caller at every bound-out — the same class as the missing-cache crash:
  `sed -n "s/^$num //p" "$STATUS_MODELS"` inside `$( )` exits 2 on a missing
  file, `| head -1` doesn't shield it under `pipefail`, and the substitution
  aborts the whole gather. **Every `$(...|head)` in the gather path needs
  `|| true`.** Input is
  `read -rsn1 -t 1` (the 1s poll tick): **bash 3.2 returns rc 1 for both
  timeout and EOF**, so a dead stdin is detected by several instant failures
  inside one wall second, and `read -n` under `stty min 0` retries forever —
  don't reintroduce VMIN=0 polling. `status_view` runs inside `$()`, so its
  `ST_HOFF`/`ST_VOFF` clamps die in the subshell — `status_watch` re-clamps
  its locals and republishes them (anchor math reads `ST_VOFF`). Offsets live
  in the watch locals, never in `status_key`'s decoder (`status_key` only
  maps bytes → `KEY`; `key_nav` mutates — an unrecognized CSI/SS3 final is
  requeued into KEYBUF so it dispatches as its own key next call, not
  swallowed). And `tput cols`/`lines` honor
  exported `$COLUMNS`/`$LINES` — stale values poison resized terminals —
  so `term_cols`/`term_lines` read `stty size` (live TIOCGWINSZ) first.
  Every `tput` capability probe in the watch path is optional by contract:
  `TERM=dumb tput civis` exits nonzero, so each `tput` call needs a
  `|| true`/fallback guard — an unguarded one kills the whole watch under
  `set -e` before the first paint. `stty` mode-sets aren't probes — they
  mutate the fd `stty -g` already verified — `2>/dev/null` is all they get.
  The `mktemp` snapshot lives in `WATCH_SNAP` and a private `mktemp -d`
  dir is exported as `TMPDIR` in `WATCH_TMPD` — globals, because the
  EXIT trap can't see `status_watch`'s locals — so signal exits `rm -rf`
  the whole dir: the snapshot, an in-flight `.new`, and every
  gather-internal tempfile (recs/act, refresh_* tmps) even when a signal
  lands mid-`status_gather`; the
  `-w` interval is digit-validated and `10#`-normalized before arithmetic
  (`status -w abc` is an unbound crash, `008` a bad-octal one, `''`/`.5`
  a hot re-gather); and the pre-first-snapshot gather retry polls
  `status_key` instead of `sleep` — q/EOF must work before the first
  paint exists. `status_tty_restore` emits its sequences to `/dev/tty`,
  never stdout: a signal caught mid `status_gather >"$snap.new"` makes
  the EXIT trap inherit the interrupted redirect, and stdout-bound
  cnorm/rmcup would land in the snapshot file instead of the terminal.
- **`running/<pr>` marker = "stopped by user".** `run_agent` treats a deleted
  marker as an intentional stop (rc 3), not a crash — remove the marker before
  killing a pid, never after.
- **`prs_extra.jsonl` is display-only.** It holds last-known PR objects for
  tracked PRs that aged out of `prs.jsonl`'s `--limit 100` window (backfilled
  once each by `backfill_prs` — merges serialized under `prs.lock` and
  published tmp+`mv`, pruned by `gc --yes`). `pr_info` falls back to
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
  an *edited* review or comment re-triggers. Don't switch to plain ids. The
  files are watcher-owned: `check_pr`/`mark-seen` write them via `seed_seen`;
  status counting must use `status_pending_count` (an absent marker gets the
  `last_seen_ts` cutoff applied in memory) — never `pending_feedback`, which
  seeds on sight and would mask real news from the watcher.
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
  to avoid. `status_gather` also re-probes flagged PRs
  (`refresh_blocked_flags`) so the flag un-stales when the watcher is off, and
  `sync_scan watch` skips flagged PRs since a blocked `check_sync` only
  defers anyway.
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
  state). `on`/`add` took them into `targets` instead — same dead row plus
  a `fetch_feedback` 404 every poll, and `gc` can't collect a targets entry
  (only `rm` can) — so both validate each argument through `need_real_pr`
  too. `gc` now forgets keys with no cached object whose `gh pr view`
  fails with "Could not resolve to a PullRequest" — `refresh_prs 0` +
  `backfill_prs` already ran by then, so that verdict means "not a PR", not
  "uncached". Only that exact stderr verdict is proof (`gh_err_not_pr` is
  the shared check): rate limits, 5xxs, and repo-level "Could not resolve
  to a Repository" failures mean "couldn't verify" — keep the key, never
  let a transient failure delete state. A stale `locks/<n>` can't shield a
  phantom either — no live run can hold a lock on a non-PR number, so
  `gc --yes` drops the orphaned dir. `need_pr` alone stays only where a
  command does its own resolution (`sync --apply`).
- **Every `v*` file the `tests/release.sh` stub writes must join the
  `release/list` exclusion.** The stub keeps sidecars next to the release
  markers (`<tag>.assets`, `<tag>.files`, `<tag>.notes`) and its
  `release/list` is `ls -t | grep '^v' | grep -vE '\.(assets|files|notes)$'`
  — an unfiltered suffix passes the grep and, being newer than the
  `touch`ed marker, surfaces as the "latest release" to `cmd_update`.
  When the stub learns a new sidecar, extend the regex.
- **Setting env names are a public interface — never derive them.** Six
  documented `PR_AGENT_*` vars differ from `PR_AGENT_<setting>`:
  `PR_AGENT_MODE`→`PERM_MODE`, `PR_AGENT_AUTHOR`→`AUTHOR_FILTER`,
  `PR_AGENT_PR_AUTHOR`→`PR_AUTHOR_FILTER`, `PR_AGENT_CI`→`CI_TRIGGER`,
  `PR_AGENT_CONFLICTS`→`CONFLICT_TRIGGER`, `PR_AGENT_SETUP`→`SETUP_CMD`.
  `resolve_str`/`resolve_num` take the full env name as an explicit arg at
  each `load_settings` call site (kept greppable on purpose); only the
  `CFG_*` saved names derive from the setting. Deriving `PR_AGENT_$n`
  silently renamed all six — including `PR_AGENT_MODE` reverting to
  `dangerous`, a silent security downgrade — while fixtures passed because
  they only exercised names that coincidentally matched. Fixtures:
  `tests/display-settings.sh`.

## Commit style

Conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`), one logical
change per commit. When the README's usage table or the usage header comment
at the top of the script changes, keep both in sync — `pr-agent help` prints
the header verbatim. Same for other docs that mirror behavior: the README
dashboard example must match real `status` output, and the ARCHITECTURE.md
code map must place a command in the section that implements it —
dispatch-inline commands belong in the `dispatch` row, not `manual commands`.
