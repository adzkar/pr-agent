#!/usr/bin/env bash
# Fixture checks for the PR_JQ .review derivation — no gh, no repo. Feeds
# synthetic gh-shaped PR objects through the exact jq the script ships and
# asserts the verdict: reviewDecision wins when set; else each non-author
# reviewer's latest opinionated state (APPROVED / CHANGES_REQUESTED only —
# COMMENTED can't erase a standing verdict, DISMISSED drops out).
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(sed -n "/^PR_JSON_FIELDS='/,/'$/p" pr-agent)"   # lift the jq + field list out
eval "$(sed -n "/^PR_JQ='/,/'$/p" pr-agent)"            # untriggered — never runs dispatch
[ -n "${PR_JQ:-}" ] || { echo "FAIL could not extract PR_JQ"; exit 1; }

fail=0
check() { # name want got -> report
  if [ "$2" = "$3" ]; then echo "  ok   $1 ('$3')"
  else echo "  FAIL $1 — want '$2', got '$3'"; fail=1; fi
}

mk_pr() { # reviewDecision reviews-json -> gh-shaped PR object (PR_JQ's input)
  jq -n --arg rd "$1" --argjson rv "${2:-[]}" '{
    number:1, title:"t", state:"OPEN", isDraft:false,
    reviewDecision:$rd, reviews:$rv,
    updatedAt:"2026-01-01T00:00:00Z", headRefName:"b", headRefOid:"abc",
    baseRefName:"main", mergeable:"MERGEABLE", statusCheckRollup:[],
    body:"", isCrossRepository:false, author:{login:"adzkar"}
  }'
}
mk_rev() { # login state submittedAt -> review object
  jq -n --arg l "$1" --arg s "$2" --arg t "$3" \
    '{author:{login:$l}, state:$s, submittedAt:$t}'
}
revs() { jq -s '.'; }                            # slurp a stream of review objects
verdict() { mk_pr "$1" "${2:-[]}" | jq -r "$PR_JQ" | jq -r .review; }
t() { check "$1" "$2" "$(verdict "${4:-}" "${3:-[]}")"; }   # name want [reviews] [rd]

T1="2026-01-01T00:00:00Z" T2="2026-01-02T00:00:00Z" T3="2026-01-03T00:00:00Z"

echo "review_verdict: PR_JQ verdict fixtures"

case ",$PR_JSON_FIELDS," in *,reviews,*) fld=yes;; *) fld=no;; esac
check "PR_JSON_FIELDS fetches reviews" yes "$fld"

t "reviewDecision wins over reviews"          APPROVED \
  "$(mk_rev bob CHANGES_REQUESTED "$T1" | revs)" APPROVED
t "unprotected approval"                      APPROVED \
  "$(mk_rev bob APPROVED "$T1" | revs)"
t "unprotected changes-requested"             CHANGES_REQUESTED \
  "$(mk_rev bob CHANGES_REQUESTED "$T1" | revs)"
t "approve then comment-only"                 APPROVED \
  "$({ mk_rev bob APPROVED "$T1"; mk_rev bob COMMENTED "$T2"; } | revs)"
t "changes-requested then comment-only"       CHANGES_REQUESTED \
  "$({ mk_rev bob CHANGES_REQUESTED "$T1"; mk_rev bob COMMENTED "$T2"; } | revs)"
t "approve then changes-requested"            CHANGES_REQUESTED \
  "$({ mk_rev bob APPROVED "$T1"; mk_rev bob CHANGES_REQUESTED "$T2"; } | revs)"
t "changes-requested then approve"            APPROVED \
  "$({ mk_rev bob CHANGES_REQUESTED "$T1"; mk_rev bob APPROVED "$T2"; } | revs)"
t "comment between two verdicts"              APPROVED \
  "$({ mk_rev bob CHANGES_REQUESTED "$T1"; mk_rev bob COMMENTED "$T2"; mk_rev bob APPROVED "$T3"; } | revs)"
t "out-of-order array, newest wins"           APPROVED \
  "$({ mk_rev bob APPROVED "$T2"; mk_rev bob CHANGES_REQUESTED "$T1"; } | revs)"
t "dismissed verdict drops out"               "" \
  "$(mk_rev bob DISMISSED "$T1" | revs)"
t "dismiss then approve"                      APPROVED \
  "$({ mk_rev bob DISMISSED "$T1"; mk_rev bob APPROVED "$T2"; } | revs)"
t "comment-only review"                       "" \
  "$(mk_rev bob COMMENTED "$T1" | revs)"
t "pending review"                            "" \
  "$(mk_rev bob PENDING "$T1" | revs)"
t "PR author's own approval ignored"          "" \
  "$(mk_rev adzkar APPROVED "$T1" | revs)"
t "ghost-author approval counted"             APPROVED \
  "$(jq -n --arg t "$T1" '{author:null,state:"APPROVED",submittedAt:$t}' | revs)"
t "two reviewers: CR wins"                    CHANGES_REQUESTED \
  "$({ mk_rev alice APPROVED "$T1"; mk_rev bob CHANGES_REQUESTED "$T2"; } | revs)"
t "no reviews at all"                         "" "[]"

echo
if [ "$fail" -eq 0 ]; then echo "review_verdict: all checks passed"
else echo "review_verdict: FAILURES"; exit 1; fi
