# Committee health monitoring

Guards one failure mode: the committee validator is **armed** (`committeeActive() == true`) but
`requiredQuorum()` returns the `UINT256_MAX` sentinel, so every tier-2/3 validation fails closed
while everything on-chain still looks configured. Upstream this went unseen for ~10 hours because
nothing durable was watching.

## Layers

| Layer | What it is | Status |
|---|---|---|
| Check | `scripts/committee-health.mjs` — reads the stack, prints a verdict, exits 0/1/2 | **works** |
| Alert | `.github/workflows/committee-health.yml` — opens/updates a deduped GitHub issue | **works** |
| Trigger (schedule) | `schedule:` cron in that workflow | **falsified — does not fire** |
| Trigger (dispatch) | `workflow_dispatch` | **works** |
| Trigger (external) | `scripts/committee-health-poke.sh` + `ops/*.plist.template` | **works when installed; NOT installed by this PR — until `launchctl print` shows a `run interval` line, coverage is unchanged** |

## The trigger is falsified, not unproven

Measured, both repos, same `7,22,37,52 * * * *` expression:

| Repo | Window observed | Due slots | Runs fired |
|---|---|---|---|
| airaccount-contract | 83 min | ~5 | **0** |
| YetAnotherAA-Validator | 6 h 33 min | 26 | **0** |

Config was ruled out: YAML valid, workflow `state=active`, repo active, `workflow_dispatch` green on
the same file. Offset minutes (rather than `*/15`) did **not** help — an earlier note in the workflow
claiming they "fired normally" was an inference relayed as fact and is retracted; see PR #223.

A scheduled check that never fires is indistinguishable from having no check at all, which is the
exact state this tooling exists to end. Hence the external trigger.

## Why the poker verifies, and not just pokes

An alert that lives inside Actions cannot tell you that Actions never ran it — "the poke never fired"
and "it fired but the alert could not be sent" are the same silence from the outside. So
`committee-health-poke.sh` runs **outside** Actions and closes that loop:

1. record the newest **dispatched** run id before dispatching (a real comparison, not a timestamp
   guess, and narrowed by event so another trigger's run cannot be mistaken for ours);
2. dispatch — a rejection is a trigger failure, exit **2**;
3. wait for a *different* run id — accepted-but-no-run is exit **2**, the branch Actions can never
   self-report. If not one poll succeeded, that is exit **3**, because "no run appeared" and "I could
   not see the runs" are not the same observation;
4. report the conclusion — **0** success, **1** non-success, **3** if no conclusion is readable.

| Exit | Meaning |
|---|---|
| 0 | healthy |
| 1 | **the check found a problem** |
| 2 | **the trigger is broken** |
| 3 | **undetermined** — could not read a verdict |

**1 is never used for an unknown.** `committee-health.mjs` spent three PRs separating "could not look"
from "is broken" so an RPC blip is never printed as an outage; folding them back together out here
would undo that at 15-minute cadence, and a code nobody trusts is a code nobody reads.

Silence from this script is decidable: either it ran and said something, or the host was off.

## Install the external trigger (manual, by design)

```bash
sed "s|REPO_PATH|$PWD|g" ops/com.aastar.committee-health.plist.template \
  > ~/Library/LaunchAgents/com.aastar.committee-health.plist
launchctl load ~/Library/LaunchAgents/com.aastar.committee-health.plist
launchctl list | grep committee-health   # second column 0 = last run exited clean
tail -f /tmp/committee-health-poke.log
```

Needs an authenticated `gh` on that machine. Runs every 15 min plus once at load, so a broken install
shows up immediately.

**Verify by asking launchd, not by reading the file.** `plutil -lint` only answers "is this legal XML":
a `StartInterval` nested one level too deep lints green and is never scheduled — dvt hit exactly that,
and the "self-heals every 120s" promised in that file's own comment had never once happened. The
**absence** of the run-interval line is the bug:

```bash
launchctl print gui/$(id -u)/com.aastar.committee-health | grep -E "run interval|last exit"
tail -f ~/Library/Logs/committee-health-poke.log     # run history, rotated by the script at 1 MB
```

This is the same lesson as the cron finding one layer up: **a legal config is not an accepted
schedule**, and neither one tells you it was ignored.

## Manual use

```bash
./scripts/committee-health-poke.sh                       # trigger + verify via Actions
node scripts/committee-health.mjs                        # run the check locally
AT_BLOCK=11604310 node scripts/committee-health.mjs      # replay a past block (needs archive RPC)
```

## Verdicts

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | OK / WARN | armed and satisfiable; WARN covers the structural keeper-latency window |
| 1 | CRITICAL | armed but tier-2/3 is failing closed |
| 2 | UNDETERMINED | the check could not complete — says **nothing** about stack health |

`UNDETERMINED` is deliberately not an alias for CRITICAL: an RPC blip must never be printed as
"tier-2/3 is broken". It also covers a router pointing at a pre-CC-98 validator (a retired v0.31/v0.32
stack), detected by the **absence** of the hardening getters rather than by parsing error text.
