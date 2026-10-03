# pr-agent — agent rules

> Read this before editing. The whole tool is **one file**: `pr-agent`
> (~1600 lines of bash). The canonical docs are `README.md` (usage) and
> `docs/ARCHITECTURE.md` (code map + flows) — read the architecture doc
> before touching anything past line 100.

## Repo layout

| Path | What it is |
| --- | --- |
| `pr-agent` | The entire tool — a self-contained bash script, no build step |
| `README.md` | User docs: install, commands, dashboard, config |
| `docs/ARCHITECTURE.md` | Code structure map, state files, execution flows |
| `AGENTS.md` | This file |

## Deploy model

The script is installed at `/usr/local/bin/pr-agent`. Edit the repo copy, then
install:

```sh
install -m 755 pr-agent /usr/local/bin/pr-agent
```

`/usr/local/bin/pr-agent` is a copy, not a symlink — **never edit it in place**,
or changes diverge silently. If it already drifted, diff before overwriting.

## Verify before committing

There is no test suite. Minimum checks:

```sh
bash -n pr-agent                       # syntax
shellcheck pr-agent 2>/dev/null || true # lint if available
cd /path/to/a/watched/repo             # then run READ-ONLY commands only:
pr-agent status                        #   dashboard (renders table + activity)
pr-agent status -w 1 & sleep 4; kill %1  #   watch-mode frame
pr-agent config                        #   effective settings
pr-agent peek N / pr-agent logs N      #   per-PR inspection
```

Commands with side effects — `on`, `off`, `run`, `tell`, `retry`, `sync --apply`,
`gc` — spawn agent sessions, post PR comments, or delete worktrees. Don't run
them as a smoke test unless that's the intent.

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

- **`state_cell`/`review_cell` have side effects** — they populate the `H_*`
  hint buckets that drive the bottom "what now" line. If you skip drawing a
  table row you must still call them, or the hint lies.
- **`render_status` row budget.** `status -w` passes terminal rows so the table
  caps itself; fixed chrome is `19 + gh_error` lines. If you add/remove any
  non-table line, update the `19` in the `cap=` computation or the frame will
  scroll/clip again.
- **`running/<pr>` marker = "stopped by user".** `run_agent` treats a deleted
  marker as an intentional stop (rc 3), not a crash — remove the marker before
  killing a pid, never after.
- **`seen/<pr>` keys are content-derived** (`id:body-len` / `id:updated_at`) —
  an *edited* review or comment re-triggers. Don't switch to plain ids.
- **Feedback `key` ≠ seen marker ≠ skip state.** Marking a key seen only stops
  *that* item; the PR may still have pending items.
- **The `… N more` table row and the fallback `… N more lines` clip are
  different mechanisms** — the first caps rows inside the table, the second is
  the last-resort bottom clip for wrapped lines. Keep both.

## Commit style

Conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`), one logical
change per commit. When the README's usage table or the usage header comment
at the top of the script changes, keep both in sync — `pr-agent help` prints
the header verbatim.
