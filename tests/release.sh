#!/usr/bin/env bash
# Harness for ./release: scratch git repos + stubbed gh. No GitHub touched.
# Run from anywhere: tests/release.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GH_STUB_STATE="$T/state"
mkdir -p "$T/bin" "$T/state"

cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
state="${GH_STUB_STATE:?}"
[ "${GH_STUB_DOWN:-0}" = "1" ] && exit 1   # simulate gh unreachable
case "$1/$2" in
  auth/status) exit 0 ;;
  release/view)
    [ -f "$state/$3" ] || exit 1
    case "${4:-} ${5:-}" in
      "--json url") echo "https://example.test/$3" ;;
      "--json assets") cat "$state/$3.assets" 2>/dev/null || true ;;
    esac
    exit 0 ;;
  release/list)
    ls -t "$state" 2>/dev/null | grep '^v' | grep -vE '\.(assets|files|notes)$' | head -1
    exit 0 ;;
  release/download)
    tag="$3"; dir=""; prev=""
    for a in "$@"; do [ "$prev" = "--dir" ] && dir="$a"; prev="$a"; done
    [ -n "$dir" ] && [ -d "$state/$tag.files" ] && cp "$state/$tag.files"/* "$dir/"
    exit ;;
  pr/list) cat "$state/prs" 2>/dev/null || true; exit 0 ;;
  release/create)
    [ "${GH_STUB_FAIL_CREATE:-0}" = "1" ] && exit 1
    touch "$state/$3"; prev=""
    for a in "$@"; do
      [ "$prev" = "--notes-file" ] && cp "$a" "$state/$3.notes"
      [ "$a" = "--generate-notes" ] && echo "generated" >"$state/$3.notes"
      prev="$a"
    done
    exit 0 ;;
  release/upload)
    tag="$3"; shift 3; : >"$state/$tag.assets"
    if [ "${GH_STUB_FAIL_UPLOAD:-0}" = "1" ]; then
      basename "$1" >>"$state/$tag.assets"   # first asset lands, rest lost
      exit 1
    fi
    for a in "$@"; do case "$a" in -*) ;; *) basename "$a" >>"$state/$tag.assets" ;; esac; done
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1 — $2"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want '$3' in: $2" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
yes()  { [ -e "$2" ] && ok "$1" || bad "$1" "missing $2"; }
ver()  { sed -nE 's/^VERSION="(.*)".*/\1/p' pr-agent; }

# new_repo NAME VERSION -> repo+remote+gh state, cds into repo
new_repo() {
  mkdir -p "$T/state-$1"; export GH_STUB_STATE="$T/state-$1"
  git init --bare -q "$T/$1.git"
  git init -q "$T/$1"
  ( cd "$T/$1"
    git checkout -qb main
    printf '#!/usr/bin/env bash\nVERSION="%s" # release identity\n' "$2" > pr-agent
    cp "$REPO/release" release; chmod +x release
    git add -A; git commit -qm init
    git remote add origin "$T/$1.git"
    git push -qu origin main )
  cd "$T/$1"
}

# try_release OUTVAR [args...] -> runs ./release, sets $OUTVAR + RC
try_release() {
  local __var="$1"; shift
  if out="$(./release "$@" 2>&1)"; then RC=0; else RC=$?; fi
  printf -v "$__var" '%s' "$out"
}

bump() { sed -i '' -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"$1\"/" pr-agent; }

# --- update scenarios (stub: releases carry downloadable files under <tag>.files/) ---

# seed_update INSTALLED_VER RELEASE_VER -> installed copy at $T/upd, release assets in gh state
seed_update() {
  mkdir -p "$T/upd" "$GH_STUB_STATE/v$2.files"
  sed -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"$1\"/" "$REPO/pr-agent" >"$T/upd/pr-agent"
  chmod 755 "$T/upd/pr-agent"
  sed -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"$2\"/" "$REPO/pr-agent" >"$GH_STUB_STATE/v$2.files/pr-agent"
  ( cd "$GH_STUB_STATE/v$2.files" && shasum -a 256 pr-agent > pr-agent.sha256 )
  touch "$GH_STUB_STATE/v$2"
}

# try_update OUTVAR SELF [args...] -> runs `SELF update`, sets $OUTVAR + RC
try_update() {
  local __var="$1" self="$2"; shift 2
  if out="$(PR_AGENT_STATE_DIR="$T/upstate" "$self" update "$@" 2>&1)"; then RC=0; else RC=$?; fi
  printf -v "$__var" '%s' "$out"
}

uver() { sed -nE 's/^VERSION="(.*)".*/\1/p' "$1"; }   # path -> VERSION value

echo "== S1: fresh release =="
new_repo r1 0.1.0
try_release o
eq "rc 0" "$RC" 0; has "output" "$o" 'released v0.1.1 (was 0.1.0)'
eq "VERSION bumped" "$(ver)" 0.1.1
yes "release created" "$GH_STUB_STATE/v0.1.1"
eq "assets uploaded" "$(cat "$GH_STUB_STATE/v0.1.1.assets" | tr '\n' ' ')" "pr-agent pr-agent.sha256 "
eq "tag pushed" "$(git -C "$T/r1.git" tag)" v0.1.1

echo "== S2: rerun after success =="
try_release o 0.1.1
eq "rc!=0" "$([ $RC -ne 0 ] && echo y)" y; has "msg" "$o" 'already exists'

echo "== S3: next patch after success (release commit at HEAD is fine) =="
try_release o
eq "rc 0" "$RC" 0; has "output" "$o" 'released v0.1.2 (was 0.1.1)'
yes "release created" "$GH_STUB_STATE/v0.1.2"

echo "== S4: downgrades die =="
try_release o 0.1.1; has "0.1.1 < 0.1.2" "$o" 'would downgrade'
try_release o 0.0.9; has "0.0.9 < 0.1.2" "$o" 'would downgrade'

echo "== S5: mint the checked-in VERSION =="
new_repo r5 0.1.0
try_release o 0.1.0
eq "rc 0" "$RC" 0; has "output" "$o" 'released v0.1.0 —'
eq "tag at HEAD" "$(git rev-parse v0.1.0^{commit})" "$(git rev-parse HEAD)"
yes "release created" "$GH_STUB_STATE/v0.1.0"

echo "== S6: resume after failed gh release create =="
new_repo r6 0.1.0
GH_STUB_FAIL_CREATE=1 try_release o
eq "create failed rc" "$([ $RC -ne 0 ] && echo y)" y
eq "tag made" "$(git tag)" v0.1.1
eq "tag pushed" "$(git -C "$T/r6.git" tag)" v0.1.1
eq "VERSION bumped" "$(ver)" 0.1.1
try_release o            # bare rerun -> points at the unfinished release
has "leapfrog guard" "$o" 'committed but its release is unfinished — finish it first: ./release 0.1.1'
GH_STUB_FAIL_CREATE=0 try_release o 0.1.1
eq "resume rc 0" "$RC" 0
has "released msg" "$o" 'released v0.1.1 —'
yes "release created" "$GH_STUB_STATE/v0.1.1"

echo "== S7: resume with unpushed release commit + tag =="
new_repo r7 0.1.0
bump 0.1.9; git add pr-agent; git commit -qm 'chore: release v0.1.9'; git tag v0.1.9
try_release o 0.1.9
eq "rc 0" "$RC" 0
eq "commit pushed" "$(git -C "$T/r7.git" rev-parse main)" "$(git rev-parse HEAD)"
eq "tag pushed" "$(git -C "$T/r7.git" tag)" v0.1.9
yes "release created" "$GH_STUB_STATE/v0.1.9"

echo "== S8: non-release unpushed commit still dies =="
new_repo r8 0.1.0
git commit -q --allow-empty -m wip
try_release o
has "differs" "$o" 'local main differs'

echo "== S9: resume when commit exists but tag does not =="
new_repo r9 0.1.0
bump 0.3.0; git add pr-agent; git commit -qm 'chore: release v0.3.0'
try_release o 0.3.0
eq "rc 0" "$RC" 0
eq "tag created+pushed" "$(git -C "$T/r9.git" tag)" v0.3.0
yes "release created" "$GH_STUB_STATE/v0.3.0"

echo "== S10: foreign tag still dies =="
new_repo r10 0.1.0
git tag v9.9.9; git push -q origin v9.9.9
try_release o 9.9.9
has "tag exists" "$o" 'tag v9.9.9 already exists'

echo "== S11: stale tag re-anchored at HEAD =="
new_repo r11 0.1.0
bump 0.5.0; git add pr-agent; git commit -qm 'chore: release v0.5.0'
git tag v0.5.0 'HEAD~1'   # tag stranded on the pre-bump commit (as after rebase)
try_release o 0.5.0
eq "rc 0" "$RC" 0; has "re-anchored" "$o" 're-anchored stale tag v0.5.0'
eq "local tag at HEAD" "$(git rev-parse v0.5.0^{commit})" "$(git rev-parse HEAD)"
eq "remote tag at HEAD" "$(git -C "$T/r11.git" rev-parse 'v0.5.0^{commit}')" "$(git rev-parse HEAD)"
yes "release created" "$GH_STUB_STATE/v0.5.0"

echo "== S12: unreleased release commit at HEAD blocks leapfrog =="
new_repo r12 0.1.0
bump 0.6.0; git add pr-agent; git commit -qm 'chore: release v0.6.0'
try_release o            # unpushed variant
has "unpushed die" "$o" 'v0.6.0 is committed but its release is unfinished — finish it first: ./release 0.6.0'
git push -q origin main  # pushed variant — same die
try_release o
has "pushed die" "$o" 'v0.6.0 is committed but its release is unfinished — finish it first: ./release 0.6.0'
try_release o 0.6.0      # finishing works
eq "finish rc 0" "$RC" 0
yes "release created" "$GH_STUB_STATE/v0.6.0"

echo "== S13: partial upload repaired on resume =="
new_repo r13 0.1.0
GH_STUB_FAIL_UPLOAD=1 try_release o
eq "upload failed rc" "$([ $RC -ne 0 ] && echo y)" y
yes "release exists" "$GH_STUB_STATE/v0.1.1"
eq "only first asset" "$(tr '\n' ' ' <"$GH_STUB_STATE/v0.1.1.assets")" "pr-agent "
GH_STUB_FAIL_UPLOAD=0 try_release o 0.1.1
eq "repair rc 0" "$RC" 0
eq "assets repaired" "$(tr '\n' ' ' <"$GH_STUB_STATE/v0.1.1.assets")" "pr-agent pr-agent.sha256 "

echo "== S14: zero-padded components =="
new_repo r14 0.1.09
try_release o
eq "patch 09 -> 10" "$(ver)" 0.1.10
new_repo r14b 0.1.0
try_release o 1.09.0
eq "explicit normalized" "$(ver)" 1.9.0
eq "tag normalized" "$(git tag)" v1.9.0

echo "== S15: extra arguments die =="
new_repo r15 0.1.0
try_release o patch junk
has "argc guard" "$o" 'too many arguments'

echo "== S16: partial release blocks a bare bump (the leapfrog hole) =="
new_repo r16 0.1.0
GH_STUB_FAIL_UPLOAD=1 try_release o      # release exists, 1/2 assets
try_release o                            # plain ./release must not leapfrog
has "partial blocks bump" "$o" 'v0.1.1 is committed but its release is unfinished — finish it first: ./release 0.1.1'
GH_STUB_FAIL_UPLOAD=0 try_release o 0.1.1
eq "then repair rc 0" "$RC" 0
eq "assets complete" "$(tr '\n' ' ' <"$GH_STUB_STATE/v0.1.1.assets")" "pr-agent pr-agent.sha256 "

echo "== S17: unfinished tag still blocks when HEAD has moved on =="
new_repo r17 0.1.0
bump 0.7.0; git add pr-agent; git commit -qm 'chore: release v0.7.0'
git tag v0.7.0; git push -q origin main 'refs/tags/v0.7.0:refs/tags/v0.7.0'
touch "$GH_STUB_STATE/v0.7.0"          # partial release: exists, no assets file
git commit -q --allow-empty -m docs; git push -q origin main   # HEAD moved on
try_release o
has "tagged unfinished die" "$o" 'v0.7.0 is tagged but its release is unfinished — finish it first: ./release 0.7.0'

echo "== S18: zero-padded VERSION does not bypass the v\$curn guard =="
new_repo r18 0.02.0
git tag v0.2.0; git push -q origin 'refs/tags/v0.2.0:refs/tags/v0.2.0'
touch "$GH_STUB_STATE/v0.2.0"          # partial release at canonical name
try_release o
has "padded guard fires" "$o" 'v0.2.0 is tagged but its release is unfinished — finish it first: ./release 0.2.0'
try_release o 0.2.0
eq "repair rc 0" "$RC" 0

echo "== S19: foreign remote tag is not silently re-pointed =="
new_repo r19 0.1.0
# a tag on a commit unreachable from main, pushed by another clone — fetch
# won't follow it, so refs/tags/v0.1.1 stays absent and the plain tag
# refspec (no '+') must fail instead of clobbering the remote tag
git init -q "$T/r19b"; ( cd "$T/r19b"
  git remote add origin "$T/r19.git"
  git checkout -qb side
  git commit -qm foreign --allow-empty
  git tag v0.1.1
  git push -q origin 'refs/tags/v0.1.1:refs/tags/v0.1.1' )
try_release o
eq "rc!=0" "$([ $RC -ne 0 ] && echo y)" y
has "push rejected" "$o" 'rejected'
eq "remote tag intact" "$(git -C "$T/r19.git" rev-parse 'v0.1.1^{commit}')" "$(git -C "$T/r19b" rev-parse HEAD)"

echo "== S20: update --check labels + happy-path install =="
new_repo u20 0.1.0
seed_update 0.1.0 9.9.9
try_update o "$T/upd/pr-agent" --check
has "latest label" "$o" 'installed 0.1.0 · latest v9.9.9'
has "latest hint" "$o" "run 'pr-agent update'"
try_update o "$T/upd/pr-agent" --check 9.9.9
has "target label" "$o" 'installed 0.1.0 · target v9.9.9'
has "pinned hint" "$o" "run 'pr-agent update 9.9.9'"
try_update o "$T/upd/pr-agent"
eq "update rc" "$RC" 0
has "updated msg" "$o" 'updated 0.1.0 → 9.9.9'
eq "installed VERSION" "$(uver "$T/upd/pr-agent")" "9.9.9"
eq "no leftovers" "$(ls -A "$T/upd")" "pr-agent"

echo "== S21: bad checksum dies before install =="
new_repo u21 0.1.0
seed_update 0.1.0 9.9.9
echo deadbeef >"$GH_STUB_STATE/v9.9.9.files/pr-agent.sha256"
try_update o "$T/upd/pr-agent"
eq "rc!=0" "$([ $RC -ne 0 ] && echo y)" y
has "checksum msg" "$o" 'checksum verification failed'
eq "untouched VERSION" "$(uver "$T/upd/pr-agent")" "0.1.0"

echo "== S22: watcher note fires for any repo's watcher =="
new_repo u22 0.1.0
seed_update 0.1.0 9.9.9
mkdir -p "$T/upstate/repos/a__b"
bash -c 'exec -a "pr-agent _loop" sleep 30' & wpid=$!
echo "$wpid" >"$T/upstate/repos/a__b/pid"
try_update o "$T/upd/pr-agent"
has "restart note" "$o" 'a watcher still runs 0.1.0'
kill "$wpid" 2>/dev/null || true

echo "== S23: git-worktree copy refused unless --force =="
new_repo u23 0.1.0
cp "$REPO/pr-agent" "$T/u23/pr-agent"; chmod 755 "$T/u23/pr-agent"
seed_update 0.1.0 9.9.9
try_update o "$T/u23/pr-agent"
has "refusal" "$o" 'inside a git worktree — refusing'
eq "copy untouched" "$(uver "$T/u23/pr-agent")" "0.1.0"
try_update o "$T/u23/pr-agent" --force
eq "force rc" "$RC" 0
eq "force installed" "$(uver "$T/u23/pr-agent")" "9.9.9"

echo "== S24: no releases and non-semver tags die =="
new_repo u24 0.1.0
cp "$REPO/pr-agent" "$T/u24-script"; chmod 755 "$T/u24-script"
try_update o "$T/u24-script"
has "none published" "$o" 'no releases published yet'
touch "$GH_STUB_STATE/vbeta"       # newest marker, wrong shape
try_update o "$T/u24-script"
has "bad tag shape" "$o" "unexpected release tag 'vbeta' — want vX.Y.Z"

echo "== S25: update arg-count and reachability errors =="
new_repo u25 0.1.0
seed_update 0.1.0 9.9.9
try_update o "$T/upd/pr-agent" 9.9.9 8.8.8
has "extra arg dies" "$o" 'too many arguments'
try_update o "$T/upd/pr-agent" --bogus
has "unknown flag dies" "$o" "unknown flag '--bogus'"
try_update o "$T/upd/pr-agent" 8.8.8        # gh up, release missing
has "missing release" "$o" 'no release v8.8.8'
GH_STUB_DOWN=1 try_update o "$T/upd/pr-agent" 9.9.9
has "gh down pinned" "$o" "can't reach releases"
GH_STUB_DOWN=1 try_update o "$T/upd/pr-agent" --check
has "gh down latest" "$o" "can't reach releases"

echo "== S26: same-version, reinstall, and downgrade paths =="
new_repo u26 0.1.0
seed_update 0.1.0 0.1.0
try_update o "$T/upd/pr-agent" --check
has "up to date" "$o" 'up to date'
try_update o "$T/upd/pr-agent"
has "already on" "$o" 'already on 0.1.0 — nothing to do'
try_update o "$T/upd/pr-agent" --force
eq "reinstall rc" "$RC" 0
has "reinstalled" "$o" 'installed v0.1.0'
seed_update 9.9.9 0.1.0
try_update o "$T/upd/pr-agent" --check
has "newer than latest" "$o" 'newer than latest'
try_update o "$T/upd/pr-agent"
has "downgrade msg" "$o" 'installed v0.1.0'
has "was 9.9.9" "$o" 'was 9.9.9'

echo "== S27: update resolves a symlinked install =="
new_repo u27 0.1.0
seed_update 0.1.0 9.9.9
ln -s "$T/upd/pr-agent" "$T/updl"          # absolute link
try_update o "$T/updl"
eq "link rc" "$RC" 0
eq "real file updated" "$(uver "$T/upd/pr-agent")" "9.9.9"
[ -L "$T/updl" ] && ok "link survives" || bad "link survives" "link gone"
( cd "$T" && ln -s "upd/pr-agent" "$T/uprel" )   # relative link
try_update o "$T/uprel"
has "relative link sees real file" "$o" 'already on 9.9.9'
cp "$REPO/pr-agent" "$T/u27/wt-copy"; chmod 755 "$T/u27/wt-copy"
ln -s "$T/u27/wt-copy" "$T/wlink"
try_update o "$T/wlink"
has "linked worktree refused" "$o" 'inside a git worktree — refusing'

echo "== S28: notes grouped from merged PRs =="
new_repo r28 0.1.0
git checkout -qb side
git commit -q --allow-empty -m 'feat: shiny thing'
git checkout -q main
git merge -q --no-ff side -m 'Merge pull request #7 from t/side'
git commit -q --allow-empty -m 'fix: a typo (#9)'
git commit -q --allow-empty -m 'feat!: drop old flag (#11)'
git commit -q --allow-empty -m 'fix!: harder break (#13)'
git commit -q --allow-empty -m 'feat(api)!: scoped break (#15)'
git push -q origin main
printf '7\tfeat: shiny thing\n9\tfix: a typo\n11\tfeat!: drop old flag\n13\tfix!: harder break\n15\tfeat(api)!: scoped break\n' >"$GH_STUB_STATE/prs"
try_release o 0.1.0
eq "rc 0" "$RC" 0
notes="$(cat "$GH_STUB_STATE/v0.1.0.notes")"
has "features group" "$notes" '### Features'
has "feat line" "$notes" 'feat: shiny thing — #7'
has "feat bang line" "$notes" 'feat!: drop old flag — #11'
has "scoped bang line" "$notes" 'feat(api)!: scoped break — #15'
has "fixes group" "$notes" '### Fixes'
has "fix line" "$notes" 'fix: a typo — #9'
has "fix bang line" "$notes" 'fix!: harder break — #13'
eq "notes not a release" "$(gh release list --limit 1)" "v0.1.0"

echo "== S29: no PRs in range -> falls back to generated notes =="
try_release o 0.1.1
eq "rc 0" "$RC" 0
has "generated fallback" "$(cat "$GH_STUB_STATE/v0.1.1.notes")" 'generated'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
