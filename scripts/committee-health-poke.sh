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
# it confirms a new run actually appeared and reports its conclusion.
#
# WHAT THIS STILL CANNOT TELL YOU (measured 2026-08-31, do not re-derive the retracted version):
# silence here is NOT decidable. This script previously claimed "either it ran and said something, or
# the machine was off". A laptop that CLOSES ITS LID is neither: launchd SKIPS StartInterval firings
# during sleep instead of catching up, and caffeinate does not cover Clamshell Sleep. That stopped
# this monitor and the keeper it watches at the same moment, and nobody knew until someone touched the
# machine. See the SELF-GAP block below, which reports the slots that were missed -- it makes the
# blind window visible AFTERWARDS; it cannot close it.
#
# Usage:  ./scripts/committee-health-poke.sh            # dispatch, wait, report
#         VERIFY_TIMEOUT=180 ./scripts/committee-health-poke.sh
# Exit:   0 = run dispatched and concluded success
#         1 = the run concluded non-success -- the CHECK FOUND A PROBLEM
#         2 = TRIGGER broken: dispatch rejected, or accepted but produced no run
#         3 = UNDETERMINED: could not read a verdict (API error, run still in flight)
#
# 1 IS NEVER USED FOR AN UNKNOWN. committee-health.mjs spent three PRs separating "could not look"
# from "is broken" so an RPC blip is never printed as an outage; folding that back together out here
# would undo it at 15-minute cadence, and a code nobody trusts is a code nobody reads.

set -uo pipefail

REPO="${REPO:-AAStarCommunity/airaccount-contract}"
WF="${WF:-committee-health.yml}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-240}"
# The script owns its history rather than leaning on launchd's redirect: /tmp is periodically cleaned
# on some macOS configurations, which would erase the log exactly when someone reaches for it. Each
# append reopens the file, so rotating here (before any write) is safe and needs no external tool.
POKE_LOG="${POKE_LOG:-$HOME/Library/Logs/committee-health-poke.log}"
mkdir -p "$(dirname "$POKE_LOG")" 2>/dev/null
if [ -f "$POKE_LOG" ] && [ "$(stat -f%z "$POKE_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv -f "$POKE_LOG" "${POKE_LOG}.1"
fi
log() {
  local line; line="$(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$POKE_LOG" 2>/dev/null || true
}

# SELF-GAP: report slots this monitor MISSED. launchd SKIPS StartInterval firings while the machine
# sleeps -- it does not catch up -- and `caffeinate` does not cover Clamshell Sleep, so closing the lid
# silently stops both this monitor and the keeper it watches. That was measured, not theorised: on
# 2026-08-31 a clamshell sleep skipped 2 slots here while the keeper missed pinning an epoch, and the
# alert only appeared after the machine woke. A monitor sharing a failure mode with its subject is not
# a monitor, and the blind window is invisible from inside it. This cannot prevent that; it makes the
# gap VISIBLE afterwards instead of silent, which is the property I wrongly claimed the laptop already
# had. The real fix is not hosting keeper and monitor on a machine that sleeps.
INTERVAL="${POKE_INTERVAL_SECONDS:-900}"
# Validate: `0` divided by zero and `abc` raised an unbound variable, and BOTH produced no GAP line at
# all (no `set -e` here, so the script sailed on). A check whose whole purpose is to catch silence
# must not answer misconfiguration with silence.
case "$INTERVAL" in
  ''|*[!0-9]*|0) log "GAP CHECK MISCONFIGURED: POKE_INTERVAL_SECONDS='${INTERVAL}' is not a positive integer; using 900s."
                 INTERVAL=900 ;;
esac
if [ -f "$POKE_LOG" ]; then
  # Anchor on a line EVERY run writes before any early exit. Anchoring on "dispatched;" skipped runs
  # that exited 2 (dispatch rejected -- auth or rate limit, which recur), so the next run stepped over
  # them and reported "it was down ... UNOBSERVED" about a monitor that was awake and had correctly
  # reported TRIGGER FAILURE. A false claim of blindness is as bad as a missed one.
  last="$(grep 'newest run before dispatch:' "$POKE_LOG" | tail -1 | awk '{print $1}')"
  if [ -n "$last" ]; then
    # TZ=UTC is required: `date -j -f` parses in LOCAL time, so a UTC stamp comes back offset by the
    # zone and "ran a minute ago" reads as hours old -- which made the control cell (a fresh log)
    # report a gap it did not have.
    last_s="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%s 2>/dev/null || echo 0)"
    if [ "$last_s" -gt 0 ]; then
      gap=$(( $(date +%s) - last_s ))
      # COUPLING, easy to break silently: VERIFY_TIMEOUT must stay well under INTERVAL/2. launchd does
      # not run the same job concurrently, so a run still in flight delays the next launch and `gap`
      # becomes the PREVIOUS run's duration, not an outage. The threshold is 1.5*INTERVAL = 1350s and a
      # normal round tops out near 900+VERIFY_TIMEOUT = 1140s, leaving ~210s. Raise VERIFY_TIMEOUT past
      # ~450 (or shrink INTERVAL) and healthy rounds start reporting phantom gaps.
      # ROUND, do not floor: `gap/INTERVAL - 1` only opens its mouth at gap >= 2*INTERVAL, so ONE
      # skipped firing (INTERVAL < gap < 2*INTERVAL) -- the smallest and by far the commonest blind
      # window -- was the single case it stayed quiet about. Measured: 1799s was silent.
      missed=$(( (gap + INTERVAL / 2) / INTERVAL - 1 ))
      [ "$missed" -gt 0 ] && log "GAP: this monitor did not run for ${gap}s (~${missed} slot(s) missed since ${last}) -- it was down, so that window is UNOBSERVED, not healthy."
    fi
  fi
fi

# Record the newest run id BEFORE dispatching, so "a new run appeared" is a real comparison and not a
# guess from a timestamp window.
# Narrow to dispatched runs: --limit 1 across all events can return a run some other trigger started,
# which is "the newest", not "the one I asked for".
newest() { gh run list --repo "$REPO" --workflow "$WF" --event workflow_dispatch --limit 1 \
             --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null; }
before="$(newest)" || before=0
[ -z "$before" ] && before=0
log "newest run before dispatch: ${before}"

if ! gh workflow run "$WF" --repo "$REPO" >/dev/null 2>&1; then
  log "TRIGGER FAILURE: gh workflow run was rejected (auth, rate limit, or workflow disabled)."
  exit 2
fi
log "dispatched; waiting up to ${VERIFY_TIMEOUT}s for a new run to appear"

deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
run_id=0
polls_ok=0   # "no run appeared" and "I could not see the runs" are NOT the same observation.
while [ "$(date +%s)" -lt "$deadline" ]; do
  if latest="$(newest)" && [ -n "$latest" ]; then
    polls_ok=$(( polls_ok + 1 ))
    if [ "$latest" != "$before" ] && [ "$latest" != "0" ]; then run_id="$latest"; break; fi
  fi
  sleep 5
done

if [ "$run_id" = "0" ]; then
  if [ "$polls_ok" -eq 0 ]; then
    log "UNDETERMINED: could not list runs even once in ${VERIFY_TIMEOUT}s -- says nothing about the trigger."
    exit 3
  fi
  # Actions can never report this branch about itself: the poke was accepted but produced no run.
  log "TRIGGER FAILURE: dispatch accepted but no new run appeared in ${VERIFY_TIMEOUT}s (${polls_ok} successful polls)."
  exit 2
fi
log "run ${run_id} started; waiting for it to conclude"

# Do not treat a watch failure as a verdict -- fall through to an explicit status read either way.
gh run watch "$run_id" --repo "$REPO" --exit-status >/dev/null 2>&1
view="$(gh run view "$run_id" --repo "$REPO" --json status,conclusion --jq '[.status,.conclusion] | @tsv' 2>/dev/null)" || view=""
read -r status conclusion <<<"$view"
log "run ${run_id}: status=${status:-unknown} conclusion=${conclusion:-none}"
log "https://github.com/${REPO}/actions/runs/${run_id}"

# A run that has not completed, or a view we could not read, is an UNKNOWN -- not a finding. Reporting
# it as 1 would make an API timeout look exactly like "tier-2/3 is failing closed".
if [ "${status:-}" != "completed" ]; then
  log "UNDETERMINED: no conclusion readable for run ${run_id} (status=${status:-unreadable})."
  exit 3
fi

[ "${conclusion:-}" = "success" ] && exit 0
exit 1
