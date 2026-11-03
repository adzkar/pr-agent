#!/usr/bin/env bash
# Fixture checks for case-insensitive author/login matching — no gh, no repo.
# Lifts PR_AUTHOR_JQ and the feedback functions out of `pr-agent` and feeds
# synthetic items through the exact jq the script ships: configured logins
# (PR_AUTHOR_FILTER, AUTHOR_FILTER, BOTS, @me/$me) match API-sourced .author
# case-insensitively, while a missing .author (deleted/ghost accounts) still
# never matches — fail-closed.
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(sed -n "/^PR_AUTHOR_JQ='/,/'$/p" pr-agent)"
eval "$(grep '^me()' pr-agent)"
eval "$(sed -n '/^scope_label()/,/^}/p' pr-agent)"
eval "$(sed -n '/^filter_feedback()/,/^}/p' pr-agent)"
eval "$(sed -n '/^format_feedback()/,/^}/p' pr-agent)"
eval "$(sed -n '/^review_failure_plan()/,/^}/p' pr-agent)"
[ -n "${PR_AUTHOR_JQ:-}" ] || { echo "FAIL could not extract PR_AUTHOR_JQ"; exit 1; }

STATE_DIR="$(mktemp -d)"; trap 'rm -rf "$STATE_DIR"' EXIT
mkdir -p "$STATE_DIR/seen"
echo owner >"$STATE_DIR/me"          # me() reads the cached login
# defaults mirror the script: every regex non-empty, AUTHOR_FILTER off
AUTHOR_FILTER="" BOTS="devin-bot[bot]" SKIP_RE="in-progress -->"
RETRY_RE="^Review failed:" BOT_STATUS_RE='\b(underway|already running|queued)\b' TRIGGER='!do'

fail=0
check() { # name want got -> report
  if [ "$2" = "$3" ]; then echo "  ok   $1 ('$3')"
  else echo "  FAIL $1 — want '$2', got '$3'"; fail=1; fi
}

pr_author() { # author(json) pa me -> true/false through the shipped fragment
  jq -n --arg pa "$2" --arg me "$3" --argjson a "$1" '{author:$a} | '"$PR_AUTHOR_JQ"
}
mk_item() { # key author(json) kind body -> one feedback item (fetch_feedback shape)
  jq -n --arg k "$1" --argjson a "$2" --arg knd "$3" --arg b "$4" \
    '{key:$k, ts:"2026-01-01T00:00:00Z", kind:$knd, id:1, author:$a, body:$b, url:"u"}'
}
ff_keys() { # items-file -> keys filter_feedback lets through (AUTHOR_FILTER etc. are globals)
  filter_feedback 1 "$1" | jq -r .key | paste -sd, -
}

echo "author_match: case-insensitive login fixtures"

# --- PR_AUTHOR_JQ ("all"-mode watch scope) -----------------------------------
t() { check "$1" "$2" "$(pr_author "$3" "$4" "$5")"; }   # name want author pa me
t "list entry matches API casing"        true  '"ALICE"' 'alice'        'x'
t "API casing matches list entry"        true  '"alice"'  'Alice'       'x'
t "different login still rejected"       false '"alice"'  'bob'         'x'
t "@me resolves case-insensitively"      true  '"OWNER"'  '@me'         'owner'
t "@ME token + login casing"             true  '"owner"'  '@ME'         'Owner'
t "@ALL means any author"                true  '"bob"'    '@ALL'        'x'
t "blank filter means any author"        true  '"bob"'    ''            'x'
t "missing author never matches"         false 'null'     'alice'       'x'
t "missing author vs unresolvable @me"   false 'null'     '@me'         ''

# --- scope_label agrees with the filter --------------------------------------
PR_AUTHOR_FILTER='@ALL';  check "@ALL label is everyone" "all open PRs"        "$(scope_label)"
PR_AUTHOR_FILTER='A,bob'; check "list label keeps casing" "open PRs by A,bob"  "$(scope_label)"
PR_AUTHOR_FILTER='';      check "blank label is everyone" "all open PRs"       "$(scope_label)"

# --- filter_feedback -----------------------------------------------------------
f() { check "$1" "$2" "$(mk_item "$3" "$4" "$5" "$6" | ff_keys /dev/stdin)"; }  # name want key auth kind body
AUTHOR_FILTER='alice'
f "AUTHOR_FILTER matches API casing"  i:k   i:k  '"Alice"'  comment 'hi'
AUTHOR_FILTER='Alice'
f "AUTHOR_FILTER entry downcased"     i:k   i:k  '"alice"'  comment 'hi'
f "AUTHOR_FILTER drops other authors" ''    i:k  '"mallory"' comment 'hi'
AUTHOR_FILTER=''
f "BOTS matches API casing"           i:k   i:k  '"Devin-Bot[bot]"' comment 'note'
f "unconfigured [bot] still dropped"  ''    i:k  '"OtherBot[bot]"'  comment 'hi'
f "me match is case-insensitive"      i:k   i:k  '"OWNER"'  comment '!do fix'
f "me casing, non-trigger body"       ''    i:k  '"OWNER"'  comment 'no trig'
f "missing author passes open list"   i:k   i:k  'null'     comment 'hi'
RETRY_RE=''
f "empty RETRY_RE keeps feedback"     i:k   i:k  '"Devin-Bot[bot]"' comment 'Review failed: x'
RETRY_RE="^Review failed:"
f "bot failure notice still gated"    ''    i:k  '"Devin-Bot[bot]"' comment 'Review failed: x'

# me unresolved (empty cache): a ghost-author trigger item must not read as
# "mine" — if it did, the owner branch would bypass the non-empty AUTHOR_FILTER
echo -n >"$STATE_DIR/me"
AUTHOR_FILTER='alice'
f "ghost author isn't me"             ''    i:k  'null'     comment '!do x'
AUTHOR_FILTER=''
echo owner >"$STATE_DIR/me"

# --- format_feedback ------------------------------------------------------------
fmt() { mk_item k1 "$1" comment x | format_feedback; }
case "$(fmt '"OWNER"')"  in *"PR owner"*) got=owner;; *) got=other;; esac
check "owner label case-insensitive" owner "$got"
case "$(fmt '"mallory"')" in *"PR comment"*) got=comment;; *) got=other;; esac
check "other author is PR comment"   comment "$got"
case "$(fmt 'null')"     in *"PR comment"*) got=comment;; *) got=other;; esac
check "ghost author is PR comment"   comment "$got"

# --- review_failure_plan ---------------------------------------------------------
plan="$(mk_item c:9:x '"Devin-Bot[bot]"' comment 'Review failed: boom' | review_failure_plan 1 /dev/stdin)"
check "bot failure found despite casing" 'c:9:x' "$(echo "$plan" | jq -r .key)"

echo
if [ "$fail" -eq 0 ]; then echo "author_match: all checks passed"
else echo "author_match: FAILURES"; exit 1; fi
