#!/usr/bin/env bash
# Runs the gate's script from its workflow against stubbed gh and curl, and checks each case's
# exit code, the statuses it posts, the logins it looks up, and its output. Needs mikefarah yq.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT

# Usage: step_script NAME FILE. Writes the run script of the gate step named NAME to FILE.
step_script() {
  local query=".jobs.cla-gate.steps[] | select(.name == \"$1\") | .run"
  yq "$query" "$repo/.github/workflows/cla-gate.yml" >"$2"
  if [[ ! -s "$2" || "$(cat "$2")" == null ]]; then
    echo "Couldn't find the \"$1\" step's script in cla-gate.yml." >&2
    exit 1
  fi
}

step_script "Pass license/cla if every author is an org member" "$work/gate.sh"
step_script "Read the app key" "$work/key.sh"
step_script "Mask AWS identifiers" "$work/mask.sh"

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
run_gate "other bots are looked up and declined" 0 "" "alice renovate[bot]" \
  "renovate[bot] is not an org member" COMMIT_AUTHORS="alice renovate[bot]"
run_gate "unlinked commit email" 0 "" "" "isn't linked" COMMIT_AUTHORS="alice <unlinked>"
run_gate "too many commits" 0 "" "" "exceeds the API listing limit" COMMIT_COUNT=251
run_gate "head moved" 0 "" "alice" "Head moved to def" HEAD_NOW=def

run_gate "missing token" 1 "" "" "No membership token" MEMBERS_TOKEN=
run_gate "rejected token" 1 "" "alice" "returned HTTP 401" MEMBERS_TOKEN=revoked
run_gate "members API error" 1 "" "alice" "returned HTTP 500" MEMBERS_HTTP=500
run_gate "members API unreachable" 1 "" "alice" "returned HTTP 000" MEMBERS_HTTP=000
run_gate "commit listing error" 1 "" "" "HTTP 502" FAIL_COMMITS=1

fake_key=$'-----BEGIN RSA PRIVATE KEY-----\nMIIEfirstline\nMIIEsecondline\n'
fake_key+='-----END RSA PRIVATE KEY-----'

# Usage: run_key_step NAME RC [VAR=value ...]. Checks that the step prints nothing but masks,
# masks every line of the key, and passes the key on intact only when it succeeds.
run_key_step() {
  local name=$1 want_rc=$2
  shift 2
  local out="$work/github_output" output rc=0 ok=yes detail=""
  : >"$out"
  output=$(env GITHUB_OUTPUT="$out" FAKE_KEY="$fake_key" "$@" bash "$work/key.sh" 2>&1) || rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    ok=no detail="rc=$rc"
  elif [[ -n "$(grep -v -e '^::add-mask::' -e "^::error::Couldn't read the app key" \
    -e "^::error::The app key in AWS Secrets Manager isn't" <<<"$output" || true)" ]]; then
    ok=no detail="printed something other than masks or its own error: $output"
  fi
  if [[ "$want_rc" == 0 && "$ok" == yes ]]; then
    while IFS= read -r line; do
      if ! grep -qxF "::add-mask::$line" <<<"$output"; then
        ok=no detail="unmasked line: $line"
      fi
    done <<<"$fake_key"
    if [[ "$(sed '1d;$d' "$out")" != "$fake_key" ]]; then
      ok=no detail="key not passed on intact"
    fi
  elif [[ "$want_rc" != 0 && -s "$out" ]]; then
    ok=no detail="wrote output after failing"
  fi
  if [[ "$ok" == yes ]]; then
    echo "ok   key step: $name"
  else
    echo "FAIL key step: $name: $detail"
    failures=$((failures + 1))
  fi
}

run_key_step "masks every line and passes the key on" 0
run_key_step "AWS error writes nothing" 1 FAIL_AWS=1
run_key_step "empty secret writes nothing" 1 FAKE_KEY=
run_key_step "binary secret (None) writes nothing" 1 FAKE_KEY=None
run_key_step "non-PEM secret writes nothing" 1 FAKE_KEY=not-a-private-key

# Usage: run_mask_step NAME ROLE_ARN WANT. WANT is the expected output, one mask per line.
run_mask_step() {
  local name=$1 arn=$2 want=$3 output rc=0
  output=$(env ROLE_ARN="$arn" bash "$work/mask.sh" 2>&1) || rc=$?
  if [[ "$rc" == 0 && "$output" == "$want" ]]; then
    echo "ok   mask step: $name"
    return
  fi
  echo "FAIL mask step: $name: rc=$rc output='$output'"
  failures=$((failures + 1))
}

run_mask_step "masks the account ID and role name" "arn:aws:iam::123456789012:role/gate-role" \
  $'::add-mask::123456789012\n::add-mask::gate-role'
run_mask_step "masks a role name under a path" "arn:aws:iam::123456789012:role/ci/gate-role" \
  $'::add-mask::123456789012\n::add-mask::gate-role'
run_mask_step "no role ARN prints nothing" "" ""
run_mask_step "malformed role ARN prints nothing" "not-an-arn" ""

if ((failures > 0)); then
  echo "$failures failed."
  exit 1
fi
echo "All passed."
