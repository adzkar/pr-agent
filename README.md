# pr-agent

Watch GitHub PRs for new review feedback and address it with a persistent
[Devin CLI](https://devin.ai) session per PR.

Unlike a spawn-per-event watcher, each PR gets its own long-lived Devin session
stored in a PR → session/worktree map. New feedback resumes that session
(`devin -r`), so the agent keeps context across review rounds instead of
starting cold.

## Requirements

- macOS (uses BSD `date -j`, `stat -f`, `osascript`, `launchctl`)
- `bash`, `git`, `jq`
- [`gh`](https://cli.github.com) — authenticated
- Devin CLI in `PATH` as `devin` (or point `DEVIN_BIN` at it)

## Install

```sh
install -m 755 pr-agent /usr/local/bin/pr-agent
```

## Quick start

```sh
cd your-repo
pr-agent on            # watch all open non-draft PRs, poll every 2m
pr-agent status -w     # live dashboard, Ctrl-C to exit
```

New feedback on a watched PR — a review, a line comment, or a comment starting
with `/agent` — triggers an agent round in that PR's own worktree. `status`
shows where every PR stands.

## Commands

| Command | What it does |
| --- | --- |
| `pr-agent on [--launchd] [all \| N...]` | Start watching (default: all open non-draft PRs). `--launchd` runs under launchd so the watcher survives reboots/crashes. |
| `pr-agent off [--now]` | Stop the watcher (`--now` also kills running agents) |
| `pr-agent status [-w [SECS]]` | Dashboard (`-w`: live refresh, default 5s) |
| `pr-agent logs [N] [-f]` | Event log, or PR N's latest agent transcript (`-f` follow) |
| `pr-agent add \| rm N...` | Add/remove PR numbers from an explicit watch list |
| `pr-agent run N [--force]` | Process PR N now in the foreground (`--force`: redo last round) |
| `pr-agent tell N "message"` | Send your own instruction to PR N's session (background) |
| `pr-agent attach N` | Open PR N's session interactively in its worktree |
| `pr-agent peek N` | Show unprocessed feedback for PR N (no action) |
| `pr-agent mark-seen N` | Mark current feedback as handled (no action) |
| `pr-agent pause \| resume N` | Stop/restart automatic runs for one PR |
| `pr-agent retry N [--dry-run]` | Ping the review bot if its latest review run failed |
| `pr-agent reset N` | Forget PR N's session — the next round starts a fresh session |
| `pr-agent gc [--yes]` | Clean up worktrees/branches/state of merged & closed PRs |
| `pr-agent sync [--apply [N]]` | Report open PRs whose branch is behind their base; `--apply` merges the base into them via their agent sessions. Optional N: only PRs whose "do not review" banner depends on merged PR N. |
| `pr-agent config` | Show effective settings |
| `pr-agent map` | Show the raw PR → session/worktree map (JSON) |

## The dashboard

`pr-agent status` prints the state of everything being watched; `-w` repaints
it live on the terminal's alt screen.

```
pr-agent  ● watching (pid 10391)   owner/repo
watching all open PRs · every 2m · mode dangerous · conflicts · 2 parallel · max 10 rounds · reacts to humans + review-bot[bot] · next poll in 34s

┌───────┬────────────┬────────────────┬────────────────────────┬────────┬──────────┐
│ PR    │ TITLE      │ REVIEW         │ AGENT STATE            │ ROUNDS │ LAST RUN │
├───────┼────────────┼────────────────┼────────────────────────┼────────┼──────────┤
│ #266  │ payment c… │ ✗ changes req. │ ↻ agent working 2m30s  │ 9      │ just now │
│ #252  │ activate/… │ ✓ approved     │ merged — done          │ 2      │ 6d ago   │
│       │ … 56 more  │                │                        │        │          │
└───────┴────────────┴────────────────┴────────────────────────┴────────┴──────────┘

recent activity  (full log: pr-agent logs · agent transcript: pr-agent logs N)
  18:51         #329   linked to session pumped-leaf
  19:04         #330   round 1 finished ✓

↻ agent is addressing feedback on #266. Follow along: pr-agent logs 266 -f
```

- **Open PRs come first**, then merged/closed history (dimmed).
- **AGENT STATE** is the live verdict per PR: working, new items pending,
  failed/retrying, paused, hit the round limit, gave up, waiting for review,
  all feedback handled, or done.
- When the table is taller than the terminal, rows are dropped from the bottom
  (merged/closed history first) and collapsed into a `… N more` row, so the
  recent-activity and hint sections always stay visible. `PR_AGENT_TABLE_ROWS`
  caps the row count regardless of terminal size — the stricter bound wins.
- **recent activity** tails the deduplicated event log; the last line is a
  contextual "what now" hint with the command to run.
- A `SESSION` column (Devin session id per PR) appears when the terminal is
  ≥ 125 columns wide.

## What counts as feedback

- Submitted reviews and line-level review comments
- Issue comments on the PR — including review-bot notices
- **Your own comments starting with `/agent`** (configurable via `PR_AGENT_TRIGGER`)
- Bot logins listed in `PR_AGENT_BOTS` (empty by default — set it to your review
  bot's login, e.g. `PR_AGENT_BOTS=review-bot[bot]`); other bots are ignored
  unless listed in `PR_AGENT_AUTHOR`
- Optionally: failing CI checks (`PR_AGENT_CI=1`) and merge conflicts
  (`PR_AGENT_CONFLICTS=1`)
- Review-bot failure notices (`Review failed: …`) are handled by the script
  itself — it pings the bot on the PR, no agent session needed (`pr-agent retry`)

## Configuration

Env vars always win over the per-repo config saved by `pr-agent on`
(`pr-agent config` shows the effective values):

| Var | Default | Meaning |
| --- | --- | --- |
| `PR_AGENT_INTERVAL` | `120` | Poll seconds |
| `PR_AGENT_MODE` | `dangerous` | `devin --permission-mode` |
| `PR_AGENT_SANDBOX` | `0` | Pass `--sandbox` to devin |
| `PR_AGENT_AUTHOR` | anyone but you | Comma list; only react to these logins |
| `PR_AGENT_BOTS` | — | Comma list of `[bot]` logins to react to (e.g. your review bot) |
| `PR_AGENT_TRIGGER` | `/agent` | Prefix that turns your own comment into feedback |
| `PR_AGENT_MAX_FAILS` | `3` | Consecutive failed runs before giving up |
| `PR_AGENT_MAX_ROUNDS` | `10` | Stop auto-runs after this many rounds (`0` = off) |
| `PR_AGENT_STOP_ON_APPROVE` | `1` | Stop auto-runs once the PR is approved |
| `PR_AGENT_CONCURRENCY` | `2` | Parallel agent runs across PRs |
| `PR_AGENT_CI` | `0` | Treat failing CI checks as feedback |
| `PR_AGENT_CONFLICTS` | `0` | Treat merge conflicts as feedback |
| `PR_AGENT_NOTIFY` | `1` | macOS notifications |
| `PR_AGENT_RETRY` | `1` | Ping the review bot on failed review runs |
| `PR_AGENT_RETRY_MAX` | `3` | Retry pings per PR before giving up |
| `PR_AGENT_RETRY_RE` | `^Review failed:` | jq regex on bot bodies marking a failed run |
| `PR_AGENT_RETRY_MSG` | — | Ping comment template; `{reviewer}` → the bot's handle |
| `PR_AGENT_SKIP_RE` | in-progress markers | Regex; matching feedback bodies are ignored |
| `PR_AGENT_SETUP` | — | Command run inside a new worktree instead of the built-in env-file + `node_modules`/bun setup |
| `PR_AGENT_MAIN_SYNC` | `0` | Each poll also auto-syncs open PRs behind the default base |
| `PR_AGENT_TABLE_ROWS` | `0` | Max rows in the status table (`0` = fill the screen; the terminal still wins when it's shorter) |
| `PR_AGENT_REPO` | — | `owner/name` to act on when not inside the repo |
| `PR_AGENT_STATE_DIR` | `~/.local/state/pr-agent` | State root |
| `DEVIN_BIN` | `devin` | Devin CLI binary |

## State & how it works

- State lives under `~/.local/state/pr-agent/repos/<owner>__<repo>`: the
  PR → session/worktree map (`map.json`), event log (`watch.log`), PID,
  feedback caches, agent transcripts.
- Each agent round runs in a dedicated worktree for the PR's branch, so your
  own checkout is never touched.
- Commands run inside a repo act on that repo; elsewhere they act on the repo
  last started with `pr-agent on` (or `PR_AGENT_REPO`).
- `pr-agent gc` removes worktrees, branches, and state for merged/closed PRs —
  run it periodically to reclaim disk.

## Hacking on pr-agent

The whole tool is one bash script — see [AGENTS.md](AGENTS.md) for
edit/verify/install rules and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for
the code map and execution flows.
