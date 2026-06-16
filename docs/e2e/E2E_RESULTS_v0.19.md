# E2E Results — AirAccount v0.19 (Sepolia, real on-chain)

v0.19 development. Each milestone: live txs + 3-layer verification + Codex challenge (per RELEASE_CHECKLIST gate).

## ✅ #42 — Gnosis Safe multisig as COMMUNITY GUARDIAN in social recovery (2026-06-16)
Proves a Gnosis Safe (contract) can serve as a guardian and participate in 2-of-3 social recovery via
`Safe.execTransaction` — **msg.sender-based, NO ERC-1271 needed** (recovery functions check `_guardianIndex(msg.sender)`).

- Safe (1-of-1, owner Jason): `0x1d9a20f9Ebb2A56417aE2684a16E04DAda1387a7`
- AirAccount (owner Annie, guardians [jason, bob, **SAFE**]): `0x874b86DBbeF47A848ccc1d685f81565Fa301A0a4`

| Step | Feature | Result | Tx |
|---|---|---|---|
| Safe deploy | SafeProxyFactory 1.4.1 1-of-1 | ✅ | [`0x5a163b60…`](https://sepolia.etherscan.io/tx/0x5a163b603dcbf08d83410b02667ef41ee833c825569968d9f0918af17d741ae5) |
| account create | guardians incl. Safe contract | ✅ | [`0xee759e76…`](https://sepolia.etherscan.io/tx/0xee759e761a3b0081a34cdc58e441d356847efbc11c8b97cb0da4b8446db4bb74) |
| proposeRecovery (jason EOA) | guardian[0] proposes | ✅ | [`0xdce7e206…`](https://sepolia.etherscan.io/tx/0xdce7e206d03c65a2978541d06ac985d28cc41a7dd23e3b0d258c011f4101a367) |
| **approveRecovery (SAFE via execTransaction)** | **Safe contract guardian approves** | ✅ | [`0x351c8fa9…`](https://sepolia.etherscan.io/tx/0x351c8fa980d98597529048f129804ea25ffcb521892b95e1d675f1084b4d7470) |
| state assert | `activeRecovery.approvalBitmap == 5` (0b101 = jason bit0 + Safe bit2), newOwner == 0xBEEF | ✅ | on-chain read |

**Codex challenge: REAL (5/5).** All txs real, Safe proxy has bytecode, `to` of the approve tx = the Safe (msg.sender path), and on-chain `activeRecovery.approvalBitmap == 5` confirms BOTH jason AND the Safe approved. Feature confirmed: a Gnosis Safe genuinely participated as a guardian in on-chain 2-of-3 social recovery.

Script: `scripts/e2e-v019-safe-guardian-recovery.ts`.
