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
| Trigger (schedule) | `schedule:` cron in that workflow | **fires, but ~3% of due slots — unusable as coverage** |
| Trigger (dispatch) | `workflow_dispatch` | **works** |
| Trigger (external) | `scripts/committee-health-poke.sh` + `ops/*.plist.template` | **works when installed; NOT installed by this PR — until `launchctl print` shows a `run interval` line, coverage is unchanged** |

## The trigger fires — far too sparsely to be coverage

**Corrected.** This section previously said the `schedule:` trigger was *falsified — it does not
fire*. That was wrong, and how it went wrong is worth more than the conclusion: every window measured
(83 min here, then 4 h 01 min; 6 h 33 min in the dvt repo) fell inside the **registration delay** of a
newly created scheduled workflow. No firing could have been observed in any of them. **A window in
which the first event has not happened yet is not a delivery rate of zero.**

Measured here after waiting long enough:

| | |
|---|---|
| workflow landed | `2026-08-31T08:55Z` |
| **first** `schedule` fire | `2026-08-31T17:01:39Z` — **8.1 h later** |
| registration delay | 8.1 h in which **no firing was possible** |
| since the first fire (7.7 h) | **2 fires / ~30 due slots ≈ 7%** |

That last row deliberately excludes the registration delay from its denominator. Dividing 2 fires by
all 63 slots since the workflow landed gives ~3%, but 32 of those slots were inside the window where
firing could not happen — which is the very error this section is correcting, repeated one paragraph
later. Rates need a denominator of slots that could actually have fired.

dvt measured the same shape at 15-minute cadence (3.6%) and the opposite for **daily** crons:
`aastar-sdk`'s `0 6` delivered **76/76 over 75 days** — a delivery rate that holds precisely — arriving
late by a **variable** amount (median ~2.1 h, spread 0.25–11.7 h across those 76 runs). An earlier
draft of this section said "consistently ~6 h late"; that figure was second-hand and wrong, and is
corrected here before it spread further. Only the delivery rate is load-bearing for the conclusion
below; the latency is context. So the rule is not "cron
is broken" but:

- **sub-hourly schedules are mostly dropped**,
- **daily schedules do arrive, hours late**,
- **a newly created schedule is silent for hours** — budget >12 h before concluding anything.

Ruled out, so this is GitHub's scheduler rather than this config: the YAML parses with a valid
`on.schedule.cron`, the workflow is `state=active` via the API, the repo is neither archived nor
disabled, and `workflow_dispatch` on the same file runs green.

**~7% delivery cannot catch what this exists to catch**: the real incident on 2026-08-31 lasted 12.8
minutes. The cron is kept as redundancy, not as coverage; the external poker supplies the cadence.

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

**Correction, measured 2026-08-31:** this script previously claimed its silence was decidable — "either
it ran and said something, or the host was off". **That is false on a laptop.** `launchd` *skips*
`StartInterval` firings while the machine sleeps (it does not catch up), and `caffeinate` does not
cover `Clamshell Sleep`, so closing the lid stops this monitor **and** the keeper it watches, with
nobody informed. It happened: a clamshell sleep skipped two slots here while the keeper missed pinning
an epoch, and the alert only surfaced after the machine woke — by which point the incident had nearly
self-healed. **A monitor sharing a failure mode with its subject is not a monitor.**

So each run now reports the slots it MISSED (`GAP: … that window is UNOBSERVED, not healthy`). That
does not close the blind window — nothing running on the sleeping machine can — it makes the window
visible afterwards instead of silent, which is the property the earlier claim assumed for free. The
actual fix is not hosting the keeper and its monitor on a machine that sleeps.

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

## k missed pins cost k+1 epochs (measured 2026-09-02)

`requiredQuorum()` needs `_epochUsable(e)` **and** `_epochUsable(e-1)`. That conjunction means **a run
of `k` consecutive unpinned epochs fails-closed tier-2/3 for `k+1` epochs** — the last miss is still
inside the pair one epoch after it ends.

```
epoch N   never pinned  -> needs {N,   N-1}: N   missing  -> sentinel for all of N
epoch N+1 pinned fine   -> needs {N+1, N  }: N   missing  -> sentinel for all of N+1
epoch N+2 pinned fine   -> needs {N+2, N+1}: both present -> recovered
```

> ⚠️ **This is not a newly discovered coupling.** @repo:dvt's keeper file has carried it since before
> this incident — *"a missed window fail-closes committee ops for that epoch and the next, then
> self-heals"* — on the same line as its mitigation, *"run several for redundancy"*. The mitigation
> was never implemented; this outage is the first time it cost anything. **The gap was in redundancy,
> not in knowledge.**

Observed on Sepolia against validator `0x7ac7E9d4…`:

| block | epoch | state |
|---|---|---|
| 11614051 | 181469 (off 35/63) | `requiredQuorum=SENTINEL`, `usable(e)=true`, **`usable(e-1)=false`** → CRITICAL |
| 11614080 | 181470 (off 0/63) | e-1 now usable, e not yet pinned → WARN (structural window) |
| **11614084** | **181470 (off 4/63)** | **both pinned, `requiredQuorum=2` → OK** |

**Two corrections from @repo:dvt after this was first written, both in the worse direction.** From
this repo we can only see the epoch that blocks the *current* quorum, so a run of misses looks like
one miss:

- **`181467` was also unpinned**, not just `181468`. Nothing visible from here distinguished them —
  `181468` is simply the one that gated `e=181469`.
- So tier-2/3 was fail-closed across **three** epochs (`181467`–`181469`, ≈38 min at L=64), not one.
  `k=2` misses, `k+1=3` epochs — the formula above, instantiated.

**Root cause (relayed from @repo:dvt with `pmset -g log` + `EpochSnapshotted` timeline; no verifiable
foothold here):** the laptop running the keeper went to **Clamshell Sleep** at 16:47:18Z on AC power.
Epochs 181467 and 181468 elapsed entirely while asleep; DarkWake at 17:21:48Z, and 181469 was pinned
108 s later at offset 25 instead of the usual 2–5 — the signature of catching up after waking. The
keeper process never died. Consistent with what was verifiable here: `configVersion` stayed 5 and
`blsAggregator` stayed 4.11.0 throughout, so **neither documented cause applied** — not a rotation,
and not ordinary latency, since 181469 was itself pinned.

> **Counter-intuitive detail worth carrying:** the machine already runs `caffeinate`
> (`PreventUserIdleSystemSleep`), **which does not block Clamshell Sleep**. The protection was present
> and inapplicable — it looked covered and was not. Same shape as the rest of this document's
> failures: nothing announces that a guard does not apply.

**This class of interruption is accepted, not an escalation.** Jason's standing decision (2026-09-01)
is that production runs DVT+KMS on independent nodes while **during testing the laptop is fine and
slots missed with the lid closed are accepted**. Redundant keepers are @repo:dvt's to land. Nothing in
this repo's wiring or config was involved, and nothing here needs to change.

## "e-1 is still serving" understates the structural window

The script header says the rollover window is one where "e-1 is still serving". Measured, that is not
what the account sees: during that window `requiredQuorum()` returns the sentinel, so the account-side
`signerCount >= requiredQuorum()` gate can never pass and **tier-2/3 is fail-closed for the whole
window**. What e-1 keeps serving is the snapshot, not the quorum.

That does not change the WARN classification — paging on it would be the alert fatigue this check
exists to avoid — but it does change what WARN *means*: not "tier-2/3 is fine", rather "tier-2/3 is
down for a short, expected, self-clearing interval". Anything reading a WARN as healthy is reading it
wrong.

**Measured by @repo:dvt over 138 pinned epochs (~31 h, ~9,000 blocks)** — this supersedes the ~6%
first written here, which was a single observation of 4/64 extrapolated as if it were a mean:

```
pin offset from epoch start:  2:33  3:52  4:43  5:5  |  15:1  25:1  26:1  49:1  60:1
mean 3.15/64 excluding the 5 outliers   (133 of 138 pins land at offset 2-5)
⇒ steady-state fail-closed = 4.9% of wall-clock  (median 4.7%)
⇒ floor at 1-block latency  = 1.6%   (a pin cannot precede the epoch it snapshots)
```

Direction and magnitude of the estimate held; the single point was simply above the mean. A redundant
keeper that pins at 1–2 blocks would take this from **4.9% to ~2–3%** — which is the part of the
window that engineering can move, as against the 1.6% the design fixes.

**Total unavailability over that window: ≈8.3%, and that is a floor rather than an estimate of the
middle.** Populations, since mixing them is easy: the window holds **141 epochs** — 138 that were
pinned plus **3 that never were**, and the never-pinned ones are by definition not inside "138 pinned"
(caught in review; an earlier draft here divided by 138 and got 8.4%).

```
fully fail-closed          5 / 141                        = 3.55%
steady-state on the rest   136 / 141 × 3.15/64 (= 4.92%)  = 4.75%
                                                     total ≈ 8.29%
```

**Why it is a floor:** the 4.92% mean deliberately excludes five outlier pins (offsets 15, 25, 26, 49,
60), and those were real unavailability too. Counting them — minus 181469's, already inside the 5
fully-failed epochs — raises the steady-state mean to 4.18/64 and the total to **≈9.9%**. Excluding
outliers is the right call for describing *typical* keeper latency; it is the wrong call for
describing *availability*, because an outlier epoch is exactly when tier-2/3 was down longest. Read
8.3% as the optimistic end of an 8.3–9.9% band. That second term comes from three unpinned epochs, not two:
**`181356` as well**, on 08-31 at 23:14 +07, about a day before this incident and following a system
sleep at 23:03. It is invisible from this repo for exactly the reason recorded above — only the epoch
gating the current quorum is ever in view — which makes it a second instance of that blind spot rather
than a new one.

Both gaps follow a sleep, and both are late at night, so **this is a recurring nightly pattern, not a
one-off**. The `k+1` rule held for both: `k=1` at 181356 cost epochs 181356–181357, `k=2` at
181467–181468 cost 181467–181469.

## Other legitimate causes of the sentinel

A `requiredQuorum()` sentinel is not always a keeper failure. `setBlsAggregator` on the validator
requires the new aggregator to match the registry's and **bumps `configVersion`**, which fails the
`epochConfigVersion[e] == configVersion` conjunct of `_epochUsable` — so **every existing epoch
snapshot becomes unusable and must be re-pinned**. When SuperPaymaster rotates its aggregator,
tier-2/3 genuinely is fail-closed for a short window and this check correctly reports CRITICAL.
**Before chasing the keeper, look at `cfgMatch` in the epoch line** — that is what the check actually
prints for this conjunct (`cfgMatch=false` means `epochConfigVersion[e] != configVersion`), and then
read `configVersion` on the validator. If it just moved, the cause is the rotation and the fix is a
fresh pin, not a keeper restart. The same window makes a phase-aware E2E run right after
a rotation read a transient sentinel — an expected reading, not a regression.

## Which router is being watched

The validator is derived from the router every run, which is what stops this check reporting green
forever against a retired validator. **The router itself is not derived** — it falls back to a
built-in address and nothing forces anyone to update it when the stack moves, which is the same
failure mode one level up. No better default fixes that, so each run states whether a human picked
the router (`(from AIRACCOUNT_ROUTER)`) or the file did (`BUILT-IN DEFAULT`). Set the
`AIRACCOUNT_ROUTER` repo variable when the stack moves; until someone does, the warning is the honest
reading. The workflow deliberately passes that variable through **empty** rather than filling in a
default, because doing the latter made the script report a router as human-chosen when nobody had
chosen it.

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
