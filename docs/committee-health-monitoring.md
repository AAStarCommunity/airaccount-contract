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
| airaccount-contract | 4 h 01 min, and counting | 16 | **0** |
| YetAnotherAA-Validator | 6 h 33 min | 26 | **0** |

Controls on the counting query, because "0 runs" and "the query returns nothing" are otherwise the
same reading:

- the identical query with `--event workflow_dispatch` returns **a non-zero count** (the load-bearing
  part is *non-zero*, not any particular number — it rises every time anyone pokes the workflow);
- **unfiltered**, the total equals the dispatch count. That is the stronger reading: not merely that
  the `schedule` filter came back empty, but that every run this workflow has ever had came from
  somewhere else.

So the zero is an observation, not an empty instrument.

Config was ruled out: YAML valid, workflow `state=active`, repo active, `workflow_dispatch` green on
the same file. Offset minutes (rather than `*/15`) did **not** help — an earlier note in the workflow
claiming they "fired normally" was an inference relayed as fact and is retracted; see PR #223.

A scheduled check that never fires is indistinguishable from having no check at all, which is the
exact state this tooling exists to end. Hence the external trigger.

## Why the poker verifies, and not just pokes — `committee-health-poke.sh`

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

`2` below is the poker's code and means *the trigger is broken*. The **other** table, further down, is
`committee-health.mjs`'s, where `2` means *undetermined*. Two tables, two owners, one number meaning
different things — read each against its own heading.

| Exit (`committee-health-poke.sh`) | Meaning |
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

Measured on this machine after loading, so the mechanism itself is not in question the way `schedule:`
is — `run interval = 900 seconds` present; `runs` went 1 → 2 at ~900 s (12:59 load, 13:14:55 second
fire), each firing completing the full chain: dispatch → new run id → `conclusion=success`. The
discriminator has a negative control too: a sibling agent on the same machine with `StartInterval`
nested one level too deep shows that line **zero** times, so its presence is an observation rather
than a constant. Whether an agent is loaded *right now* is not recorded here — that claim would rot;
run the two commands above and read the answer.

## Manual use

```bash
./scripts/committee-health-poke.sh                       # trigger + verify via Actions
node scripts/committee-health.mjs                        # run the check locally
AT_BLOCK=11604310 node scripts/committee-health.mjs      # replay a past block (needs archive RPC)
```

## Recovery closes what it resolved

A healthy run closes the alerts it resolved, so the open set equals the *current* failure set. This is
not a nicety layered on dedup — it is dedup's other half. Dedup means one issue per incident, so an
open issue stops meaning "there is a problem now" and starts meaning "there was one once"; a stale
open alert trains people to ignore open alerts, the same fatigue dedup exists to prevent, arriving
from the other end.

It closes on **`verdict == OK`**, not on exit code 0. Exit 0 covers OK *and* WARN, and one WARN —
"committee is OFF" — means CC-116 is fail-closing tier-2/3: safe, but still unavailable. Closing a
CRITICAL because someone disarmed the committee to stop the bleeding would report the incident
resolved while tier-2/3 stayed down.

Consequence to expect rather than file as a bug: the **structural keeper-latency WARN also blocks the
close**, so an issue can stay open an extra cycle or two before an OK run clears it. Seen in the wild
during this work — one dispatch landed inside that window. Separating the two WARNs needs a reason
code beyond the verdict, which is a redesign.

Closing keys on the **marker**, never on the shared label. There is deliberately no author filter
(that would make two monitors invisible to each other and each open their own issue), so the marker is
the only thing separating "a monitor opened this" from "a person filed this". Same convention as the
dvt repo, so both monitors agree.

## Verdicts — `committee-health.mjs`

These are the **check script's** codes, not the poker's; the poker wraps them and does not pass them
through.

| Exit (`committee-health.mjs`) | Verdict | Meaning |
|---|---|---|
| 0 | OK / WARN | armed and satisfiable; WARN covers the structural keeper-latency window |
| 1 | CRITICAL | armed but tier-2/3 is failing closed |
| 2 | UNDETERMINED | the check could not complete — says **nothing** about stack health |

`UNDETERMINED` is deliberately not an alias for CRITICAL: an RPC blip must never be printed as
"tier-2/3 is broken". It also covers a router pointing at a pre-CC-98 validator (a retired v0.31/v0.32
stack), detected by the **absence** of the hardening getters rather than by parsing error text.
