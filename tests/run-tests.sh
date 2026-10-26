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

# Usage: run_mask_step NAME RC ROLE_ARN ROLE_ID WANT. WANT is the expected output, one line each.
run_mask_step() {
  local name=$1 want_rc=$2 arn=$3 id=$4 want=$5 output rc=0
  output=$(env ROLE_ARN="$arn" ROLE_ID="$id" bash "$work/mask.sh" 2>&1) || rc=$?
  if [[ "$rc" == "$want_rc" && "$output" == "$want" ]]; then
    echo "ok   mask step: $name"
    return
  fi
  echo "FAIL mask step: $name: rc=$rc output='$output'"
  failures=$((failures + 1))
}

arn="arn:aws:iam::123456789012:role/gate-role"
masks=$'::add-mask::123456789012\n::add-mask::gate-role'
not_arn="::error::CLA_GATE_AWS_ROLE_ARN isn't an IAM role ARN; not contacting AWS."
run_mask_step "masks the account ID and role name" 0 "$arn" "" "$masks"
run_mask_step "masks the role ID first" 0 "$arn" AROAEXAMPLE $'::add-mask::AROAEXAMPLE\n'"$masks"
run_mask_step "masks a role name under a path" 0 "arn:aws:iam::123456789012:role/ci/gate-role" "" \
  "$masks"
run_mask_step "no role ARN prints nothing" 0 "" "" ""
run_mask_step "malformed role ARN fails" 1 "not-an-arn" "" "$not_arn"
run_mask_step "role ARN with a trailing space fails" 1 "$arn " "" "$not_arn"

# The steps' scripts are tested above; these check how the workflow wires them together.
workflow="$repo/.github/workflows/cla-gate.yml"
check_wiring() {
  local name=$1 query=$2 want=$3 got
  got=$(yq "$query" "$workflow")
  if [[ "$got" == "$want" ]]; then
    echo "ok   wiring: $name"
  else
    echo "FAIL wiring: $name: got '$got', want '$want'"
    failures=$((failures + 1))
  fi
}
step() { echo ".jobs.cla-gate.steps[] | select(.name == \"$1\")"; }

check_wiring "every step continues on error" \
  '[.jobs.cla-gate.steps[] | select(.["continue-on-error"] != true)] | length' 0
check_wiring "job permissions" \
  '.jobs.cla-gate.permissions | to_entries | map(.key + "=" + .value) | join(",")' \
  "id-token=write,pull-requests=read,statuses=write"
check_wiring "AWS step needs the masks" "$(step "Assume the CLA gate AWS role") | .if" \
  "steps.mask.outcome == 'success'"
check_wiring "key step needs the AWS role" "$(step "Read the app key") | .if" \
  "steps.aws.outcome == 'success'"
check_wiring "token step needs the key" "$(step "Create org membership token") | .if" \
  "steps.key.outcome == 'success'"
# shellcheck disable=SC2016 # The workflow expression is meant literally.
check_wiring "token step uses the key step's output" \
  "$(step "Create org membership token") | .with[\"private-key\"]" \
  '${{ steps.key.outputs.private-key }}'

if ((failures > 0)); then
  echo "$failures failed."
  exit 1
fi
echo "All passed."
