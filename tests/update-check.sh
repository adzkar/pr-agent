#!/usr/bin/env bash
# Harness for the OMZ-style update check in ./pr-agent: extracts ver_gt /
# maybe_update_check / pending_update_version and stubs latest_release_tag.
# No GitHub touched. Run from anywhere: tests/update-check.sh
set -euo pipefail

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n '/^ver_gt()/,/^}/p;/^maybe_update_check()/,/^}/p;/^pending_update_version()/,/^}/p' \
  "$REPO/pr-agent" >"$T/funcs.sh"

# run.sh STATE_ROOT SCENARIO -> source funcs + stub gh-less latest_release_tag,
# run the scenario, print "survived" if the function didn't kill the shell.
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_ROOT="\$1"; scenario="\$2"
UPDATE_CHECK="\${UPDATE_CHECK:-1}"
UPDATE_CHECK_EVERY="\${UPDATE_CHECK_EVERY:-10}"
VERSION="0.1.0"
latest_release_tag() { touch "\$STATE_ROOT/.called"; echo v9.9.9; }
. "$T/funcs.sh"
case "\$scenario" in
  check)   maybe_update_check; wait ;;
  pending) pending_update_version || true ;;
esac
echo survived
EOF
chmod +x "$T/run.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want '$3' in: $2" ;; esac; }
not() { case "$2" in *"$3"*) bad "$1" "unwanted '$3' in: $2" ;; *) ok "$1" ;; esac; }
yes() { [ -e "$2" ] && ok "$1" || bad "$1" "missing $2"; }
no()  { [ -e "$2" ] && bad "$1" "unexpected $2" || ok "$1"; }

# try SCENARIODIR SCENARIO -> O=output RC
try() {
  if O="$(UPDATE_CHECK="${UPDATE_CHECK:-1}" "$T/run.sh" "$1" "$2" 2>&1)"; then RC=0; else RC=$?; fi
}

sr() { mkdir -p "$T/$1"; echo "$T/$1"; }

echo "== S1: no stamp -> spawn + stamp =="
d="$(sr s1)"; try "$d" check
has "survived" "$O" survived
yes "gh called" "$d/.called"
yes "latest_release written" "$d/latest_release"
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2' want '$3'"; }
eq "recorded tag" "$(cat "$d/latest_release")" v9.9.9
yes "stamp written" "$d/update_check.ts"

echo "== S2: fresh stamp -> throttled =="
d="$(sr s2)"; date +%s >"$d/update_check.ts"; try "$d" check
has "survived" "$O" survived
no "gh not called" "$d/.called"

echo "== S3: stale stamp -> spawn =="
d="$(sr s3)"; echo $(( $(date +%s) - 11 )) >"$d/update_check.ts"; try "$d" check
yes "gh called" "$d/.called"

echo "== S4: far-future stamp -> treated as stale, spawn =="
d="$(sr s4)"; echo $(( $(date +%s) + 999999 )) >"$d/update_check.ts"; try "$d" check
has "survived" "$O" survived
yes "gh called" "$d/.called"
yes "latest_release written" "$d/latest_release"

echo "== S5: UPDATE_CHECK=0 -> no stamp, no spawn =="
d="$(sr s5)"; UPDATE_CHECK=0 try "$d" check
has "survived" "$O" survived
no "gh not called" "$d/.called"
no "no stamp" "$d/update_check.ts"

echo "== S6: unwritable stamp -> survives quietly, no spawn =="
d="$(sr s6)"; echo 1 >"$d/update_check.ts"; chmod 444 "$d/update_check.ts"; try "$d" check
eq "rc 0" "$RC" 0
has "survived" "$O" survived
not "no EACCES noise" "$O" "denied"
no "gh not called" "$d/.called"
chmod 644 "$d/update_check.ts"  # let the trap clean up

echo "== S7: pending_update_version respects the toggle =="
d="$(sr s7)"; printf v9.9.9 >"$d/latest_release"
UPDATE_CHECK=1 try "$d" pending; has "enabled prints" "$O" 9.9.9
UPDATE_CHECK=0 try "$d" pending; not "disabled silent" "$O" 9.9.9
d="$(sr s7b)"; try "$d" pending
case "$O" in survived) ok "absent file silent" ;; *) bad "absent file" "got: $O" ;; esac

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
