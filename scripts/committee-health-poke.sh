#!/usr/bin/env bash
# External trigger for the committee-health workflow, plus the one check Actions cannot do for itself.
#
# WHY THIS EXISTS: the `schedule:` trigger in .github/workflows/committee-health.yml does not fire.
# Measured, not inferred -- this repo: 83 minutes / ~5 due slots / 0 runs; the upstream YAAA repo,
# identical `7,22,37,52` expression: 6h33m / 26 due slots / 0 runs. Config was ruled out (YAML valid,
# workflow state=active, repo active, workflow_dispatch green). So the check's capability is fine and
# its trigger is falsified. This script supplies a trigger that is proven to work.
#
# WHY THE POKER ALSO VERIFIES: dvt raised that an Actions-hosted alert cannot distinguish "the poke
# never fired" from "it fired but the alert could not be sent" -- both look like silence from outside.
# That is true of anything running INSIDE Actions. This script runs outside it, so after dispatching
# it confirms a new run actually appeared and reports its conclusion. Silence here is decidable:
# either this script ran (and said something) or the machine running it was off.
#
# Usage:  ./scripts/committee-health-poke.sh            # dispatch, wait, report
#         VERIFY_TIMEOUT=180 ./scripts/committee-health-poke.sh
# Exit:   0 = run dispatched and concluded success
#         1 = run concluded non-success (the check found a problem, or the job itself broke)
#         2 = dispatch failed, or no run appeared within VERIFY_TIMEOUT (TRIGGER-level failure)

set -uo pipefail

REPO="${REPO:-AAStarCommunity/airaccount-contract}"
WF="${WF:-committee-health.yml}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-240}"
log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Record the newest run id BEFORE dispatching, so "a new run appeared" is a real comparison and not a
# guess from a timestamp window.
before="$(gh run list --repo "$REPO" --workflow "$WF" --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)" || before=0
log "newest run before dispatch: ${before}"

if ! gh workflow run "$WF" --repo "$REPO" >/dev/null 2>&1; then
  log "TRIGGER FAILURE: gh workflow run was rejected (auth, rate limit, or workflow disabled)."
  exit 2
fi
log "dispatched; waiting up to ${VERIFY_TIMEOUT}s for a new run to appear"

deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
run_id=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  latest="$(gh run list --repo "$REPO" --workflow "$WF" --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)" || latest=0
  if [ "$latest" != "$before" ] && [ "$latest" != "0" ]; then run_id="$latest"; break; fi
  sleep 5
done

if [ "$run_id" = "0" ]; then
  # This is the branch Actions itself can never report: the poke was accepted but produced no run.
  log "TRIGGER FAILURE: dispatch accepted but no new run appeared within ${VERIFY_TIMEOUT}s."
  exit 2
fi
log "run ${run_id} started; waiting for it to conclude"

# Do not treat a watch failure as a verdict -- fall through to an explicit status read either way.
gh run watch "$run_id" --repo "$REPO" --exit-status >/dev/null 2>&1
read -r status conclusion <<<"$(gh run view "$run_id" --repo "$REPO" --json status,conclusion --jq '[.status,.conclusion] | @tsv' 2>/dev/null)"
log "run ${run_id}: status=${status:-unknown} conclusion=${conclusion:-none}"
log "https://github.com/${REPO}/actions/runs/${run_id}"

[ "${conclusion:-}" = "success" ] && exit 0
exit 1
