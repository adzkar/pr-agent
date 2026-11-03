# Releasing pr-agent

How to cut a release with `./release`. The script does the whole dance —
version bump, commit, tag, push, GitHub release, asset upload — and is safe
to re-run when interrupted.

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

## Resuming an interrupted run

Just re-run `./release` (same or no argument). It re-anchors the tag at
`HEAD`, creates the release if missing, and re-uploads assets with
`--clobber`. A partial release (e.g. asset upload died) is repaired the
same way — the script refuses to leapfrog a version whose release is
unfinished and tells you how to finish it.

## Gotchas

- "local main differs from origin/main" → `git pull --ff-only` first.
- "working tree not clean" → commit or stash; the release commit must be
  the only local change.
- "vX.Y.Z is committed but its release is unfinished" → finish it with
  `./release X.Y.Z` before bumping past.
- An existing tag is never moved by a fresh run — `--atomic` push + tag
  fails if the remote tag points elsewhere (re-runs only re-anchor a tag
  that was left stale by an interrupted run).
