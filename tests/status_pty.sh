#!/usr/bin/env bash
# PTY fixtures for `status -w` — drives the tool on a real pty via
# tests/status_pty.py: key navigation, bounds, terminal sizes, resize,
# NO_COLOR, termios restoration, garbage input, and the instrumented bound
# that navigation/resize never re-gathers. Also covers the non-tty `status -w`
# fallback (one readable snapshot, no cursor-control bytes).
# Run from anywhere: tests/status_pty.sh  (needs python3)
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$T/state"
D="$STATE/repos/test__pty"
GH="$T/gh"

mkdir -p "$D/seen" "$T/bin"
echo 'test/pty' >"$D/repo"
echo 'alice'   >"$D/me"
echo 'all'     >"$D/targets"
echo '{"prs":{"200":{"session_id":"sess-200"}}}' >"$D/map.json"
: >"$D/status_pending"
: >"$STATE/gh.log"

# seeded prs cache (fresh -> refresh_prs skips the live fetch under ttl 30):
# ten wrap-length titles — one CJK — so the vertical body really scrolls and
# the cell-width engine sees multibyte input end-to-end
python3 - "$D/prs.jsonl" <<'PY'
import json, sys
wrap = " with a title long enough to wrap across several lines of the body region so vertical scrolling has room to work — plus a fair amount more detail text for extra wrap"
prs = [{"number": 200+i, "state": "OPEN",
        "title": ("fix: テストのワイドタイトル" + wrap if i == 3 else "fix: pr number %d" % i + wrap),
        "review": "APPROVED", "draft": False, "updated": "u", "branch": "b",
        "head": "h", "base": "main", "mergeable": "MERGEABLE", "ci": "pass",
        "ci_failed": [], "author": "alice"} for i in range(10)]
with open(sys.argv[1], "w") as f:
    for p in prs:
        f.write(json.dumps(p) + "\n")
PY
cp "$D/prs.jsonl" "$STATE/prs_seed.jsonl"   # the gh stub replays this so a forced refresh reseeds rather than wipes

# instrumented stub: every gh invocation lands in gh.log; list never runs
# (cache stays fresh), anything else is a silent success. Optional hooks the
# async-refresh scenarios drive: GH_PIDFILE records every stub pid (orphan
# asserts), GH_DELAY execs a hanging sleep per call (never-completing gh),
# GH_SLOW_FILE/GH_SLOW_SECS flip to hang mid-run (worker-bound asserts).
cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
[ -n "\${GH_PIDFILE:-}" ] && echo "\$\$" >>"\$GH_PIDFILE"
printf '%s\n' "\$*" >>"$STATE/gh.log"
if [ -n "\${GH_SLOW_FILE:-}" ] && [ -f "\$GH_SLOW_FILE" ]; then exec sleep "\${GH_SLOW_SECS:-20}"; fi
[ -n "\${GH_DELAY:-}" ] && exec sleep "\$GH_DELAY"
case "\$1 \$2" in "pr list") cat "$STATE/prs_seed.jsonl" ;; esac
exit 0
EOF
chmod +x "$T/bin/gh"

# model-source probe stub: the PR_AGENT_MODEL_LOOKUP seam — hangs when
# MODEL_PROBE_SLEEP is set so scenario 13 can pin a stalled model source
cat >"$T/bin/model-probe" <<'EOF'
#!/usr/bin/env bash
[ -n "${MODEL_PIDFILE:-}" ] && echo "$$" >>"$MODEL_PIDFILE"
[ -n "${MODEL_PROBE_SLEEP:-}" ] && exec sleep "$MODEL_PROBE_SLEEP"
printf 'probe-model\n'
EOF
chmod +x "$T/bin/model-probe"

# mktemp stub: bare calls land in ${TMPDIR:-$MKTEMP_STUB_DIR} so scenarios can
# assert no tempfile leaks — including inside the watch's exported TMPDIR;
# MKTEMP_STUB_DIR unset -> delegate (handles the bare `mktemp` the tool calls)
cat >"$T/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
[ -n "${MKTEMP_STUB_DIR:-}" ] || exec /usr/bin/mktemp "$@"
d="${TMPDIR:-$MKTEMP_STUB_DIR}"; mkdir -p "$d"
f="$d/stubtmp.$$.$RANDOM$RANDOM"
if [ "${1:-}" = "-d" ]; then mkdir "$f"; else : >"$f"; fi
printf '%s\n' "$f"
EOF
chmod +x "$T/bin/mktemp"

export PR_AGENT_STATE_DIR="$STATE" PR_AGENT_REPO='test/pty' PR_AGENT_UPDATE_CHECK=0
export PATH="$T/bin:$PATH"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }

# --- non-tty -w: readable snapshot, no cursor control, no key wait --------------
OUT="$(NO_COLOR=1 "$REPO/pr-agent" status -w 60 </dev/null)"
case "$OUT" in
  *'[?1049h'*|*$'\033[?25'*|*'[H'*)
    bad 'non-tty -w has no cursor control' 'escape bytes in output' ;;
  *) ok 'non-tty -w has no cursor control' ;;
esac
printf '%s' "$OUT" | grep -q '#200' && ok 'non-tty -w renders records' \
  || bad 'non-tty -w renders records' 'no #200'
printf '%s' "$OUT" | grep -q 'watching open PRs' && ok 'non-tty -w renders head' \
  || bad 'non-tty -w renders head' 'no head line'
G0=$(wc -l <"$STATE/gh.log" | tr -d ' ')
NO_COLOR=1 "$REPO/pr-agent" status -w 60 </dev/null >/dev/null
G1=$(wc -l <"$STATE/gh.log" | tr -d ' ')
[ "$G0" = "$G1" ] && ok 'non-tty -w gather made no gh calls (fresh cache)' \
  || bad 'non-tty -w gh calls' "$G0 -> $G1"

# --- redirected stdio: one readable snapshot, no control bytes, no block -------
# stdin /dev/null + stdout a file — the plain render must complete inside the
# watchdog, produce exactly one snapshot, and carry no escape bytes at all
redirect_check() { # name args... -> rc via watchdog; OUTF holds output
  "$REPO/pr-agent" "$@" </dev/null >"$OUTF" 2>/dev/null &
  # plain `status` forces a live refresh — a gather over ten records takes a
  # while; 45s is generous head-room, the point is "no indefinite block"
  rpid=$!; ( sleep 45; kill "$rpid" 2>/dev/null ) & wd=$!
  if wait "$rpid" 2>/dev/null; then rrc=0; else rrc=$?; fi
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
}
OUTF="$T/redirect.out"
redirect_check status
[ "$rrc" -eq 0 ] && ok 'redirected status exits 0 (no block)' \
  || bad 'redirected status' "rc=$rrc — blocked or failed"
grep -q '#200' "$OUTF" && ok 'redirected renders records' \
  || bad 'redirected renders records' 'no #200'
grep -q $'\x1b' "$OUTF" \
  && bad 'redirected has no control bytes' 'ESC byte found' \
  || ok 'redirected has no control bytes'
[ "$(grep -c 'pr-agent v' "$OUTF")" = "1" ] && ok 'exactly one snapshot' \
  || bad 'exactly one snapshot' "$(grep -c 'pr-agent v' "$OUTF") banners"
redirect_check status -w 60
[ "$rrc" -eq 0 ] && ok 'redirected -w exits 0 (no block)' \
  || bad 'redirected -w' "rc=$rrc — blocked or failed"
grep -q '#200' "$OUTF" && ok 'redirected -w renders records' \
  || bad 'redirected -w renders records' 'no #200'

# --- the PTY scenarios ---------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 "$REPO/tests/status_pty.py" "$REPO" "$STATE" "$T/bin/gh" \
    || fail=$((fail+1))
else
  echo "skip — python3 unavailable"
fi

echo "--- status_pty: $pass shell checks + driver above"
[ "$fail" -eq 0 ]
