# Releasing pr-agent

How to cut a release with `./release`. The script does the whole dance —
version bump, commit, tag, push, GitHub release, asset upload — and is safe
to re-run: an interrupted run resumes via `./release X.Y.Z`.

## Prerequisites

- On `main`, clean working tree, synced with `origin/main`
  (`git pull --ff-only`)
- `gh` installed and authenticated (`gh auth status`)
- `bash -n pr-agent` clean

The script checks all of these itself and dies with a clear message when
one fails.

## Steps

### 1. Pick the bump level

```sh
./release [patch|minor|major|X.Y.Z]    # default: patch
```

Look at the PRs merged since the previous tag:

- `fix:`-only range → `patch`
- any `feat:` PR → `minor`
- breaking changes → `major`
- `./release X.Y.Z` — exact version; also mints the checked-in `VERSION`
  when it was never released

### 2. Run it

```sh
./release minor
```

From the repo root, this:

1. bumps `VERSION="…"` in `pr-agent`
2. commits `chore: release vX.Y.Z` and tags `vX.Y.Z` at `HEAD`
3. pushes `main` + tag with `--atomic`
4. creates the GitHub release with notes grouped from the merged PRs
   (`### Features` / `### Fixes` / `### Other`, falls back to
   `--generate-notes` when the range has none)
5. uploads the `pr-agent` + `pr-agent.sha256` assets — what
   `pr-agent update` downloads

### 3. Verify

```sh
gh release view vX.Y.Z   # both assets listed, notes grouped
```

### 4. Update your own install

```sh
pr-agent update          # or: install -m 755 pr-agent /usr/local/bin/pr-agent
```

## What users should know about `pr-agent update`

Worth repeating in release notes for any UI/state-affecting release:

- The install is atomic — download, sha256 verify, stage, `mv` over the
  resolved executable — so interrupted or failed updates leave the previous
  executable in place.
- Per-repo state and config are never touched: upgrades preserve targets,
  session/worktree maps, seen markers, saved settings, and logs. No
  reinstall/`gc`/`reset` is needed for new UI.
- Replacing the binary does not hot-upgrade a running watcher — `update`
  prints a restart note when one is live; restart it with the same `on`
  arguments it was started with (`on N…`, `--launchd`), not a bare `on`
  (that resets an explicit watch list to "all" and drops launchd
  supervision). Open `status -w` panes likewise keep the old renderer
  until reopened.
- `update X.Y.Z` also downgrades — the supported rollback path; older
  binaries keep running on newer state.

## Resuming an interrupted run

Re-run `./release X.Y.Z` — the version it was cutting (the die message
names it). It re-anchors the tag at `HEAD`, creates the release if
missing, and re-uploads assets with `--clobber`. A bare `./release` or a
bump level does *not* resume: once `chore: release vX.Y.Z` is committed,
`VERSION` already equals the target, so a bump computes a different
version and dies on the leapfrog guard. A partial release (e.g. asset
upload died) is repaired the same way — the script refuses to leapfrog a
version whose release is unfinished and tells you how to finish it.

## Gotchas

- "local main differs from origin/main" → sync local main with origin:
  `git pull --ff-only` if behind; if ahead with a non-release commit,
  push it or move it off main. (One unpushed `chore: release` commit is
  tolerated — that's the resume path.)
- "working tree not clean" → commit or stash; the release commit must be
  the only local change.
- "vX.Y.Z is committed but its release is unfinished" → finish it with
  `./release X.Y.Z` before bumping past.
- "vX.Y.Z is tagged but its release is unfinished" → same fix —
  `./release X.Y.Z`. Fires when HEAD isn't the release commit but the
  checked-in version's release is still incomplete, e.g. a run died
  mid-publish and further commits landed on main before the next
  `./release`.
- An existing tag is never moved by a fresh run — `--atomic` push + tag
  fails if the remote tag points elsewhere (re-runs only re-anchor a tag
  that was left stale by an interrupted run).
