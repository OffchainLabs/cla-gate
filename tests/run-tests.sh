#!/usr/bin/env bash
# Runs the shell scripts embedded in the workflows against stubbed gh and openssl, and checks
# each case's exit code, the statuses or variable it writes, and its output.
# Needs GNU date, mikefarah yq and openssl, as on ubuntu-latest.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT

if ! date -u -d @0 +%s >/dev/null 2>&1; then
  echo "run-tests.sh needs GNU date (date -d)." >&2
  exit 1
fi

extract() {
  local script
  script=$(yq "$1" "$2")
  if [[ -z "$script" || "$script" == null ]]; then
    echo "Couldn't find the script ($1) in $2." >&2
    exit 1
  fi
  echo "$script"
}
extract '.jobs.cla-gate.steps[] | select(has("run")) | .run' \
  "$repo/.github/workflows/cla-gate.yml" >"$work/gate.sh"
extract '.jobs.sync.steps[] | select(has("run")) | .run' \
  "$repo/.github/workflows/sync-members.yml" >"$work/sync.sh"

REAL_OPENSSL=$(command -v openssl)
export REAL_OPENSSL
export PATH="$repo/tests/bin:$PATH"
export GH_LOG="$work/gh.log"

key=$("$REAL_OPENSSL" rand -hex 32)

# An independent implementation of the workflows' hash, for building lists by hand.
hash() {
  printf '%s' "$1" | "$REAL_OPENSSL" dgst -sha256 -hmac "$key" -r | cut -d' ' -f1
}

iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

now=$(date -u +%s)
fresh=$(iso "$now")
stale=$(iso $((now - 25 * 3600)))
skewed=$(iso $((now + 120)))
members="$fresh|,$(hash alice),$(hash bob),"
gate_success="success All authors are OffchainLabs members (CLA gate)"
assistant_success="success Contributor License Agreement is signed."

gate_env=(
  GH_TOKEN=unused REPO=o/r PR_NUMBER=1 PR_AUTHOR=alice HEAD_SHA=abc
  RUN_URL=https://example.invalid/run CLA_MEMBERS="$members" CLA_MEMBERS_KEY="$key"
)
failures=0

report() {
  local name=$1 ok=$2 detail=$3 output=$4
  if [[ "$ok" == yes ]]; then
    echo "ok   $name"
    return
  fi
  echo "FAIL $name: $detail"
  while IFS= read -r line; do echo "       $line"; done <<<"$output"
  failures=$((failures + 1))
}

# Usage: run_gate NAME RC POSTED OUTPUT [VAR=value ...]. POSTED lists the status states written.
run_gate() {
  local name=$1 want_rc=$2 want_posted=$3 want_output=$4
  shift 4
  : >"$GH_LOG"
  local output rc=0 posted ok=yes
  output=$(env "${gate_env[@]}" "$@" bash "$work/gate.sh" 2>&1) || rc=$?
  posted=$(paste -sd' ' "$GH_LOG")
  if [[ "$rc" != "$want_rc" || "$posted" != "$want_posted" || "$output" != *"$want_output"* ]]; then
    ok=no
  fi
  report "$name" "$ok" "rc=$rc posted='$posted'" "$output"
}

# Usage: run_sync NAME RC [VAR=value ...]. Sets $written to the value written, if any.
run_sync() {
  local name=$1 want_rc=$2
  shift 2
  : >"$GH_LOG"
  local output rc=0 ok=yes
  output=$(env GH_TOKEN=unused CLA_MEMBERS_KEY="$key" "$@" bash "$work/sync.sh" 2>&1) || rc=$?
  written=$(sed -n 's/^written //p' "$GH_LOG")
  if [[ "$rc" != "$want_rc" ]] || { [[ "$rc" != 0 ]] && [[ -n "$written" ]]; }; then
    ok=no
  fi
  report "sync: $name" "$ok" "rc=$rc written='$written'" "$output"
}

echo "Gate:"
run_gate "members pass" 0 success "Marked license/cla as passing"
run_gate "logins match regardless of case" 0 success "Marked" PR_AUTHOR=ALICE COMMIT_AUTHORS="Alice bob"
run_gate "bots pass without the list or key" 0 success "Marked" \
  PR_AUTHOR="dependabot[bot]" COMMIT_AUTHORS="dependabot[bot]" CLA_MEMBERS= CLA_MEMBERS_KEY=
run_gate "bots and members together pass" 0 success "Marked" COMMIT_AUTHORS="alice github-actions[bot]"
run_gate "timestamp a little ahead passes" 0 success "Marked" \
  CLA_MEMBERS="$skewed|,$(hash alice),"

run_gate "outside pull request author" 0 "" "eve is not an org member" PR_AUTHOR=eve
run_gate "outside commit author" 0 "" "eve is not an org member" COMMIT_AUTHORS="alice eve"
run_gate "unlinked commit email" 0 "" "isn't linked" COMMIT_AUTHORS="alice <unlinked>"
run_gate "too many commits" 0 "" "exceeds the API listing limit" COMMIT_COUNT=251
run_gate "wrong key" 0 "" "alice is not an org member" CLA_MEMBERS_KEY="$("$REAL_OPENSSL" rand -hex 32)"
run_gate "head moved" 0 "" "Head moved to def" HEAD_NOW=def
run_gate "head moved leaves the earlier success" 0 "" "Head moved" HEAD_NOW=def \
  LATEST_STATUS="$gate_success"

run_gate "missing list" 1 "" "empty or unset" CLA_MEMBERS=
run_gate "missing key" 1 "" "empty or unset" CLA_MEMBERS_KEY=
run_gate "stale list" 1 "" "stale or in the future" CLA_MEMBERS="$stale|,$(hash alice),"
run_gate "future timestamp" 1 "" "stale or in the future" \
  CLA_MEMBERS="2099-01-01T00:00:00Z|,$(hash alice),"
run_gate "no timestamp" 1 "" "no valid sync timestamp" CLA_MEMBERS=",$(hash alice),"
run_gate "empty timestamp" 1 "" "no valid sync timestamp" CLA_MEMBERS="|,$(hash alice),"
run_gate "word timestamp" 1 "" "no valid sync timestamp" CLA_MEMBERS="now|,$(hash alice),"
run_gate "impossible date" 1 "" "no valid sync timestamp" \
  CLA_MEMBERS="2026-13-45T00:00:00Z|,$(hash alice),"
run_gate "empty list entry" 1 "" "malformed member list" CLA_MEMBERS="$fresh|,,$(hash bob),"
run_gate "plain logins" 1 "" "malformed member list" CLA_MEMBERS="$fresh|,alice,bob,"
run_gate "API error" 1 "" "HTTP 502" FAIL_COMMITS=1
run_gate "hash error" 1 "" "openssl stub" FAIL_OPENSSL=1

run_gate "decline withdraws the gate's success" 0 pending "Withdrew" \
  COMMIT_AUTHORS="alice eve" LATEST_STATUS="$gate_success"
run_gate "decline leaves CLA assistant's success" 0 "" "eve is not an org member" \
  COMMIT_AUTHORS="alice eve" LATEST_STATUS="$assistant_success"
run_gate "too many commits withdraws" 0 pending "Withdrew" \
  COMMIT_COUNT=251 LATEST_STATUS="$gate_success"
run_gate "stale list withdraws" 1 pending "Withdrew" \
  CLA_MEMBERS="$stale|,$(hash alice)," LATEST_STATUS="$gate_success"
run_gate "stale list leaves CLA assistant's success" 1 "" "stale" \
  CLA_MEMBERS="$stale|,$(hash alice)," LATEST_STATUS="$assistant_success"
run_gate "missing key withdraws" 1 pending "Withdrew" CLA_MEMBERS_KEY= LATEST_STATUS="$gate_success"
run_gate "API error withdraws" 1 pending "Withdrew" FAIL_COMMITS=1 LATEST_STATUS="$gate_success"
run_gate "hash error withdraws" 1 pending "Withdrew" FAIL_OPENSSL=1 LATEST_STATUS="$gate_success"

echo "Sync:"
run_sync "writes hashed members" 0 ORG_MEMBERS="Bob alice"
if [[ "$written" != *",$(hash alice),"* || "$written" != *",$(hash bob),"* ]] ||
  [[ "$written" == *alice* || "$written" == *Bob* ]]; then
  report "sync: list holds both hashes and no logins" no "written='$written'" ""
else
  report "sync: list holds both hashes and no logins" yes "" ""
fi
run_gate "gate accepts what the sync writes" 0 success "Marked" CLA_MEMBERS="$written"
run_sync "missing key" 1 CLA_MEMBERS_KEY=
run_sync "empty member list" 1 ORG_MEMBERS=
run_sync "one hash fails" 1 FAIL_OPENSSL_ONCE="$work/failed-once"
run_sync "every hash fails" 1 FAIL_OPENSSL=1

if ((failures > 0)); then
  echo "$failures failed."
  exit 1
fi
echo "All passed."
