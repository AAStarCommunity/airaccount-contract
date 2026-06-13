# Issue #45 Fix 1 (Option B) — Required YetAnotherAA / SDK changes

> Companion to the contract-side change on branch `v0.18/ws-a2-bls-binding`
> (`src/validators/AAStarBLSAlgorithm.sol` + `src/core/AAStarAirAccountBase.sol`).
> This document specifies the coordinated off-chain changes for a follow-up PR in
> `AAStarCommunity/YetAnotherAA-Validator` and the SDK. **No code in `lib/YetAnotherAA-Validator`
> was modified by this PR.**

## What changed on-chain

`AAStarBLSAlgorithm.validate(bytes32 hash, bytes signature)` no longer accepts a caller-supplied
`messagePoint`. It recomputes the BLS message point on-chain from `hash` (= the ERC-4337
`userOpHash`) via RFC 9380 `hash_to_curve` (suite `BLS12381G2_XMD:SHA-256_SSWU_RO_`, DST
`BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`) and verifies the pairing against that. The
recomputation is byte-identical to `bls12_381.G2.hashToCurve(getBytes(userOpHash), { DST })`
in `@noble/curves` (verified by a golden-vector test against v2.0.1, the version the DVT runs).

### New wire formats (the algId byte is stripped by the account before these offsets)

| Path | algId | Old format | **New format** |
|---|---|---|---|
| BLS algorithm `validate` calldata | n/a | `[nodeIds][blsSig(256)][messagePoint(256)]` | `[nodeIds][blsSig(256)]` |
| Triple signature | `0x01` | `[len(32)][nodeIds][blsSig(256)][messagePoint(256)][aaSig(65)][mpSig(65)]` | `[len(32)][nodeIds][blsSig(256)][aaSig(65)]` |
| Cumulative T2 (P256+BLS) | `0x04` | `[P256(64)][len(32)][nodeIds][blsSig(256)][messagePoint(256)][mpSig(65)]` | `[P256(64)][len(32)][nodeIds][blsSig(256)]` |
| Cumulative T3 (P256+BLS+Guardian) | `0x05` | `…[messagePoint(256)][mpSig(65)][guardian(65)]` | `[P256(64)][len(32)][nodeIds][blsSig(256)][guardian(65)]` |
| Weighted BLS block | `0x07` (bit 2) | `[len(32)][nodeIds][blsSig(256)][messagePoint(256)][mpSig(65)]` | `[len(32)][nodeIds][blsSig(256)]` |

`messagePoint` (256 bytes) **and** the owner-signed `messagePointSignature` / `mpSig` (65 bytes,
ECDSA over `keccak256(userOpHash ‖ messagePoint)`) are **both removed** from every BLS payload.
The `mpSig` existed only to bind the supplied point to the `userOpHash` (replay prevention); the
on-chain recomputation makes it redundant.

## Required SDK / packer changes

In the SDK signature packers (e.g. `packSignature` / `packCumulativeT2Signature` /
`packCumulativeT3Signature` / the weighted BLS-block builder):

1. **Stop appending `messagePoint`** (the 256-byte EIP-2537 G2 point) to every BLS payload.
2. **Stop appending `messagePointSignature`** (the owner ECDSA over `userOpHash ‖ messagePoint`).
   Nothing replaces it — owner authorization in each tier is provided by the existing factor
   (`aaSignature` for `0x01`, the P256 passkey for `0x04`/`0x05`, the bitmap factors for `0x07`).
3. **`generateMessagePoint` is no longer needed for the on-chain payload.** The DVT still computes
   the message point internally to *sign* it (`bls.G2.hashToCurve(getBytes(userOpHash), {DST})`),
   but it must NOT be included in the UserOperation signature. Keep the DST and pre-image exactly
   as today (`BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, raw 32-byte `userOpHash`) — the
   contract reproduces precisely this point, so any divergence here will break verification.
4. **`aaSignature` for triple sig (`0x01`) stays** and now sits immediately after `blsSig(256)`.
5. **Guardian ECDSA for T3 (`0x05`) stays** and now sits immediately after `blsSig(256)`.

No change is required to how the DVT nodes sign (they already sign
`hashToCurve(userOpHash, {DST})`); only the assembly of the final on-chain signature changes.

## Migration note (CHANGELOG)

- This is a **new BLS algorithm + new signature format**. It requires a new `AAStarBLSAlgorithm`
  deployment, re-wiring the `AAStarValidator` router (algId `0x01`), and redeploying the
  factory/implementation (the account is non-upgradable).
- **Beta accounts on the old algorithm stay vulnerable** to the #45 replay (a valid
  `(messagePoint, aggSig)` from op A replays onto op B). They MUST be redeployed onto the new
  algorithm; the old algorithm cannot be patched in place.
- Old-format signatures (with the trailing `messagePoint`/`mpSig`) are rejected by the new code on
  a strict length check, so there is no silent acceptance during a mixed rollout.

## Batch aggregator path (`AAStarBLSAggregator`) — now #45-safe (KEPT, not disabled)

For each op in the batch the aggregator recomputes the message point on-chain from that op's own
`userOpHash` (`blsAlgorithm.hashToG2(entryPoint.getUserOpHash(op_i))`) and aggregates THOSE — never
the embedded point. A valid aggregate for one set of `userOpHash`es cannot be replayed under a batch
with different ones. SDK / deploy implications for the batch path:

- Per-op signature uses the SAME new triple-sig format as single-op
  (`[0x01][len(32)][nodeIds][blsSig(256)][aaSig(65)]`) — **also drop the embedded `messagePoint`**.
- `AAStarBLSAggregator` constructor is now `(blsAlgorithm, entryPoint)` — deploy scripts must pass
  the canonical EntryPoint (used to derive each op's `userOpHash`).
- The aggregator's G2ADD precompile address was corrected `0x0e → 0x0d` (final EIP-2537).
- Selecting the aggregator on an account is **guardian-gated**: `setAggregatorWithGuardians(agg,
  deadline, guardianSigs[])` needs owner + RECOVERY_THRESHOLD guardian sigs over
  `keccak(GUARDIAN_SIG_VERSION, chainid, account, "SET_AGGREGATOR", abi.encode(nonce, agg,
  deadline))`. A lone compromised owner can no longer swap `blsAggregator`. `address(0)` (disable)
  is allowed under the same gate.

> RECOMMENDED HARDENING (pending product confirmation; documented in the contract): add a SECOND
> protocol-level gate — a Gnosis-Safe-governed `AggregatorRegistry` allowlist wired immutably into
> the account by the factory — so even owner + colluding guardians could only select a Safe-vetted
> aggregator. NOT implemented in this PR: guardian-gating already closes the single-compromised-owner
> swap #45 flagged; the registry is flagged for the user to confirm scope (it touches the V7/Base
> constructor + factory since all clones share one registry via the implementation immutable).

## Out of scope here (flagged for follow-up)

- **Fix 2 (DVT node authorization / policy)** — nodes still sign any `userOpHash` handed to them
  with no owner-factor verification. Fix 1 stops *replay of old approvals*; it does not stop a
  *freshly forged* unauthorized approval. The BLS/DVT tier is only a sound security factor once
  Fix 2 ships in `YetAnotherAA-Validator` (see the #45 design doc §4).
