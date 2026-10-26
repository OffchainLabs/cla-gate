#!/usr/bin/env bash
# Runs the gate's script from its workflow against stubbed gh and curl, and checks each case's
# exit code, the statuses it posts, the logins it looks up, and its output. Needs mikefarah yq.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT

yq '.jobs.cla-gate.steps[] | select(has("run")) | .run' \
  "$repo/.github/workflows/cla-gate.yml" >"$work/gate.sh"
if [[ ! -s "$work/gate.sh" || "$(cat "$work/gate.sh")" == null ]]; then
  echo "Couldn't find the gate's script in cla-gate.yml." >&2
  exit 1
fi

export PATH="$repo/tests/bin:$PATH"
export GH_LOG="$work/gh.log" CURL_LOG="$work/curl.log"

gate_env=(
  LC_ALL=C GH_TOKEN=unused REPO=o/r PR_NUMBER=1 PR_AUTHOR=alice HEAD_SHA=abc
  RUN_URL=https://example.invalid/run MEMBERS_TOKEN=good VALID_TOKEN=good
  ORG_MEMBERS="alice bob"
)
failures=0

# Usage: run_gate NAME RC POSTED LOOKUPS OUTPUT [VAR=value ...]. POSTED lists the status states
# posted and LOOKUPS the logins checked against the members API, each space-separated.
run_gate() {
  local name=$1 want_rc=$2 want_posted=$3 want_lookups=$4 want_output=$5
  shift 5
  : >"$GH_LOG"
  : >"$CURL_LOG"
  local output rc=0 posted lookups
  output=$(env "${gate_env[@]}" "$@" bash "$work/gate.sh" 2>&1) || rc=$?
  posted=$(paste -sd' ' "$GH_LOG")
  lookups=$(paste -sd' ' "$CURL_LOG")
  if [[ "$rc" == "$want_rc" && "$posted" == "$want_posted" && "$lookups" == "$want_lookups" &&
    "$output" == *"$want_output"* ]]; then
    echo "ok   $name"
    return
  fi
  echo "FAIL $name: rc=$rc posted='$posted' lookups='$lookups'"
  while IFS= read -r line; do echo "       $line"; done <<<"$output"
  failures=$((failures + 1))
}

run_gate "members pass" 0 success "alice" "Marked license/cla as passing"
run_gate "every author is checked once" 0 success "alice bob" "Marked" \
  COMMIT_AUTHORS="bob alice bob"
run_gate "bots pass without a token or lookup" 0 success "" "Marked" \
  PR_AUTHOR="dependabot[bot]" COMMIT_AUTHORS="dependabot[bot]" MEMBERS_TOKEN=
run_gate "bots and members together pass" 0 success "alice" "Marked" \
  COMMIT_AUTHORS="alice github-actions[bot]"

run_gate "outside pull request author with member commits" 0 "" "alice eve" \
  "eve is not an org member" PR_AUTHOR=eve COMMIT_AUTHORS=alice
run_gate "outside commit author" 0 "" "alice eve" "eve is not an org member" \
  COMMIT_AUTHORS="alice eve"
run_gate "unlinked commit email" 0 "" "" "isn't linked" COMMIT_AUTHORS="alice <unlinked>"
run_gate "too many commits" 0 "" "" "exceeds the API listing limit" COMMIT_COUNT=251
run_gate "head moved" 0 "" "alice" "Head moved to def" HEAD_NOW=def

run_gate "missing token" 1 "" "" "No membership token" MEMBERS_TOKEN=
run_gate "rejected token" 1 "" "alice" "returned HTTP 401" MEMBERS_TOKEN=revoked
run_gate "members API error" 1 "" "alice" "returned HTTP 500" MEMBERS_HTTP=500
run_gate "members API unreachable" 1 "" "alice" "returned HTTP 000" MEMBERS_HTTP=000
run_gate "commit listing error" 1 "" "" "HTTP 502" FAIL_COMMITS=1

if ((failures > 0)); then
  echo "$failures failed."
  exit 1
fi
echo "All passed."
