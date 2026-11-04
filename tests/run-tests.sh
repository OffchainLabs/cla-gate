#!/usr/bin/env bash
# Runs the gate's script from its workflow against stubbed gh and curl, and checks each case's
# exit code, the statuses it posts, the logins it looks up, and its output. Needs mikefarah yq.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT

# Usage: step_script NAME FILE [JOB]. Writes the named step's run script to FILE.
step_script() {
  local query=".jobs.${3:-cla-gate}.steps[] | select(.name == \"$1\") | .run"
  yq "$query" "$repo/.github/workflows/cla-gate.yml" >"$2"
  if [[ ! -s "$2" || "$(cat "$2")" == null ]]; then
    echo "Couldn't find the \"$1\" step's script in cla-gate.yml." >&2
    exit 1
  fi
}

step_script "Pass license/cla if every author is an org member" "$work/gate.sh"
step_script "Read the app key" "$work/key.sh"
step_script "Pass license/cla for merge group" "$work/merge-group.sh" merge-group

export PATH="$repo/tests/bin:$PATH"
export GH_LOG="$work/gh.log" CURL_LOG="$work/curl.log" AWS_LOG="$work/aws.log"

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

# The merge queue posts directly to the merge group's SHA, without PR or membership API calls.
run_merge_group() {
  local name=$1 want_rc=$2 want_posted=$3 want_output=$4
  shift 4
  local output rc=0 posted args
  : >"$GH_LOG"
  : >"$CURL_LOG"
  : >"$AWS_LOG"
  : >"$work/gh-args.log"
  output=$(env GH_TOKEN=unused REPO=o/r HEAD_SHA=merge-sha \
    RUN_URL=https://example.invalid/run GH_ARGS_LOG="$work/gh-args.log" \
    "$@" bash "$work/merge-group.sh" 2>&1) || rc=$?
  posted=$(paste -sd' ' "$GH_LOG")
  args=$(cat "$work/gh-args.log")
  local want_args=$'api\nrepos/o/r/statuses/merge-sha\n--silent\n-f\nstate=success\n-f\ncontext=license/cla\n-f\n'
  want_args+=$'description=Dummy status to green light merge group. CLA checks only happen on Pull Requests.\n-f\n'
  want_args+='target_url=https://example.invalid/run'
  if [[ "$rc" == "$want_rc" && "$posted" == "$want_posted" && "$args" == "$want_args" &&
    "$output" == *"$want_output"* && ! -s "$CURL_LOG" && ! -s "$AWS_LOG" ]]; then
    echo "ok   merge group: $name"
  else
    echo "FAIL merge group: $name: rc=$rc posted='$posted' args='$args' output='$output'"
    failures=$((failures + 1))
  fi
}

run_merge_group "posts license/cla success on the merge commit" 0 success \
  "Marked license/cla as passing for merge group merge-sha."
run_merge_group "reports a status posting failure" 1 "" "HTTP 403" FAIL_STATUS=1

fake_key=$'-----BEGIN RSA PRIVATE KEY-----\nMIIEfirstline\nMIIEsecondline\n'
fake_key+='-----END RSA PRIVATE KEY-----'

key_env=(
  FAKE_KEY="$fake_key" ROLE_ARN=arn:aws:iam::123456789012:role/gate-role
  FAKE_ROLE_ARN=arn:aws:iam::123456789012:role/gate-role
  ACTIONS_ID_TOKEN_REQUEST_URL="https://token.invalid/request?api-version=2.0"
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
)
# Each must be masked before anything could print it.
secret_values=(fake-oidc-token ASIAFAKEKEYID fake-secret fake-session)

# Usage: [expect_key=KEY] run_key_step NAME RC CALLS ERROR [VAR=value ...]. CALLS lists the AWS
# services called, space-separated, and ERROR is text the step's output must contain. KEY is the
# key the step should pass on, $fake_key by default. Checks that the step prints only masks and its
# own errors, never AWS's (which name the role), and on success masks the token, the credentials
# and every line of the key, and passes the key on intact.
run_key_step() {
  local name=$1 want_rc=$2 want_calls=$3 want_error=$4
  shift 4
  local out="$work/github_output" output rc=0 ok=yes detail="" value line calls
  local want_key=${expect_key:-$fake_key}
  : >"$out"
  : >"$AWS_LOG"
  output=$(env GITHUB_OUTPUT="$out" "${key_env[@]}" "$@" bash "$work/key.sh" 2>&1) || rc=$?
  calls=$(paste -sd' ' "$AWS_LOG")
  if [[ "$rc" != "$want_rc" ]]; then
    ok=no detail="rc=$rc"
  elif [[ "$calls" != "$want_calls" ]]; then
    ok=no detail="called AWS for '$calls'"
  elif [[ "$output" != *"$want_error"* ]]; then
    ok=no detail="didn't print '$want_error': $output"
  elif [[ -n "$(grep -v -e '^::add-mask::' -e '^::error::' <<<"$output" || true)" ]]; then
    ok=no detail="printed something other than masks or its own errors: $output"
  elif [[ "$output" == *"arn:aws"* ]]; then
    ok=no detail="printed the role ARN: $output"
  elif grep -qxE '::add-mask::(null|None)' <<<"$output"; then
    ok=no detail="masked a placeholder word: $output"
  fi
  if [[ "$want_rc" == 0 && "$ok" == yes ]]; then
    for value in "${secret_values[@]}"; do
      if ! grep -qxF "::add-mask::$value" <<<"$output"; then
        ok=no detail="didn't mask $value"
      fi
    done
    while IFS= read -r line; do
      if ! grep -qxF "::add-mask::$line" <<<"$output"; then
        ok=no detail="unmasked key line: $line"
      fi
    done <<<"$want_key"
    if [[ "$(sed '1d;$d' "$out")" != "$want_key" ]]; then
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

both="sts secretsmanager"
not_pem="isn't a PEM private key"
run_key_step "masks everything and passes the key on" 0 "$both" ""
run_key_step "no role ARN fails before contacting AWS" 1 "" "CLA_GATE_AWS_ROLE_ARN isn't set" \
  ROLE_ARN=
run_key_step "no OIDC token request URL fails" 1 "" "can't get a GitHub OIDC token" \
  ACTIONS_ID_TOKEN_REQUEST_URL=
run_key_step "no OIDC token request token fails" 1 "" "can't get a GitHub OIDC token" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=
run_key_step "role ARN with a trailing newline is trimmed" 0 "$both" "" \
  ROLE_ARN=$'arn:aws:iam::123456789012:role/gate-role\n'
run_key_step "OIDC token error fails" 1 "" "Couldn't get a GitHub OIDC token" FAIL_OIDC=1
run_key_step "OIDC response without a token fails" 1 "" "Couldn't get a GitHub OIDC token" \
  OIDC_NO_VALUE=1
run_key_step "role assumption error prints only its own message" 1 sts \
  "Couldn't assume the AWS role" FAIL_STS=1
run_key_step "role assumption without credentials fails" 1 sts "didn't return credentials" \
  STS_NO_CREDS=1
run_key_step "secret read error prints only its own message" 1 "$both" \
  "Couldn't read the app key" FAIL_AWS=1
pkcs8_key=$'-----BEGIN PRIVATE KEY-----\nMIIEpkcs8line\n-----END PRIVATE KEY-----'
expect_key=$pkcs8_key run_key_step "accepts a PKCS#8 key" 0 "$both" "" FAKE_KEY="$pkcs8_key"
expect_key=$fake_key run_key_step "strips Windows line endings" 0 "$both" "" \
  FAKE_KEY="${fake_key//$'\n'/$'\r\n'}"
run_key_step "empty secret writes nothing" 1 "$both" "$not_pem" FAKE_KEY=
run_key_step "binary secret (None) writes nothing" 1 "$both" "$not_pem" FAKE_KEY=None
run_key_step "non-PEM secret writes nothing" 1 "$both" "$not_pem" FAKE_KEY=not-a-private-key
run_key_step "PEM block after other text writes nothing" 1 "$both" "$not_pem" \
  FAKE_KEY=$'not a header\n'"$fake_key"
run_key_step "text before the header writes nothing" 1 "$both" "$not_pem" FAKE_KEY="junk$fake_key"
run_key_step "EC key writes nothing" 1 "$both" "$not_pem" \
  FAKE_KEY=$'-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----'

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

check_wiring "pull requests and merge groups trigger the gate" '.on | keys | join(",")' \
  "pull_request,merge_group"
check_wiring "merge groups run when checks are requested" '.on.merge_group.types | join(",")' \
  checks_requested
check_wiring "the workflow grants no permissions by default" '.permissions' '{}'
check_wiring "fork pull requests are skipped" '.jobs.cla-gate.if' \
  "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository"
check_wiring "merge group job runs only for merge groups" '.jobs.merge-group.if' \
  "github.event_name == 'merge_group'"
check_wiring "merge group job needs only status permission" \
  '.jobs.merge-group.permissions | to_entries | map(.key + "=" + .value) | join(",")' \
  "statuses=write"
check_wiring "merge group job only posts the status" '.jobs.merge-group.steps | length' 1
check_wiring "merge group status failures fail the job" \
  '[.jobs.merge-group.steps[] | select(.["continue-on-error"] == true)] | length' 0
# shellcheck disable=SC2016 # The workflow expressions are meant literally.
check_wiring "merge group status targets its head SHA" '.jobs.merge-group.steps[0].env.HEAD_SHA' \
  '${{ github.event.merge_group.head_sha }}'
# shellcheck disable=SC2016
check_wiring "merge group status uses the workflow token" '.jobs.merge-group.steps[0].env.GH_TOKEN' \
  '${{ github.token }}'
# shellcheck disable=SC2016
check_wiring "concurrency separates pull requests and merge group refs" '.concurrency.group' \
  'cla-gate-${{ github.repository }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}'
check_wiring "every step continues on error" \
  '[.jobs.cla-gate.steps[] | select(.["continue-on-error"] != true)] | length' 0
check_wiring "job permissions" \
  '.jobs.cla-gate.permissions | to_entries | map(.key + "=" + .value) | join(",")' \
  "id-token=write,pull-requests=read,statuses=write"
# shellcheck disable=SC2016 # The workflow expression is meant literally.
check_wiring "key step reads the role ARN secret" "$(step "Read the app key") | .env.ROLE_ARN" \
  '${{ secrets.CLA_GATE_AWS_ROLE_ARN }}'
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
