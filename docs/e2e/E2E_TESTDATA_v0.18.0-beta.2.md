# E2E Test Data & Prerequisites — v0.18.0-beta.2 (Sepolia)

> Part 1 of the E2E release gate (data/accounts/tokens prep). Paired with `E2E_PLAN_v0.18.0-beta.2.md`
> (test cases + verification) and the Codex challenge step. All three MUST pass before this release bar is met.

## 1. Network & infra
| Key | Value |
|---|---|
| Chain | Sepolia (11155111) |
| RPC | `SEPOLIA_RPC_URL` (Alchemy) |
| EntryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7) |
| Bundler | Pimlico (`PIMLICO_BUNDLER_URL`, sepolia) |
| EIP-2537 (BLS12-381) | live on Sepolia (prague) — required for DVT T2/T3 (S-C4/C5) |
| RIP-7212 P256 precompile (0x100) | available on Sepolia (proven by v0.18 Phase 16 WSG.P1) |

## 2. Deployed contracts (v0.18.0-beta.2 — the system under test)
| Contract | Address |
|---|---|
| Factory | `0x1b694Aa55fBe2953e724037d2449905d531C1e65` |
| Implementation | `0x9Bf4d9FeFaA1e7358e58583294569adf730A97b0` |
| Extension | `0x008B136106e98384B640bD5F0D0fb6012542F24D` |
| AAStarBLSAlgorithm | `0xA9EE4f8A59fCE1B56f9da8e153c3f5F38D3C59ED` |
| AAStarBLSAggregator | `0x321D68F5eD927B59E1A953Fd97972FbCB21f7601` |
| ValidatorRouter | `0xe8e5a8c5eeDfb75adb7FbA2BCCD3A6b1B766d6f0` |
| SessionKeyValidator | `0xBB79BF812aE239443fF48323dD24860F9bFb2874` |
| ForceExitModule | `0xEaDb9EEDD1aF021AEC687C18C3491337a481e4Ed` |
| AirAccountDelegate (7702) | `0x6b60897172B7CA2fa3986d19a55B25d968988c22` |
| AgentRegistry | `0x00D7045617b9807cE36db9591a63b5af66036192` |
| CalldataParserRegistry | `0xD6A16905C25F1D928e2fF5204f1385379e84D3Ff` |

## 3. Actors — addresses, roles, current vs required balance
| Actor | Address | Role | Current ETH | Required | Action |
|---|---|---|---|---|---|
| **Annie** | `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` | owner / deployer / primary signer | 0.817 | ≥ 0.30 | OK (reuse accounts to limit creations) |
| **Jason** | `0xb5600060e6de5E11D3636731964218E53caadf0E` | guardian[0] + gas tank | 8.378 | ≥ 0.10 | OK (also funds Community) |
| **Bob** | `0xE3D28Aa77c95d5C098170698e5ba68824BFC008d` | guardian[1] | 0.159 | ≥ 0.05 | OK |
| **Community** | `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114` | guardian[2] | **0.000** | ≥ 0.03 | ⚠️ **FUND 0.05 ETH from Jason** (only needed if a 3rd-guardian tx is exercised; 2-of-3 paths use Jason+Bob) |
| SessionKey1 | (derived, ephemeral) | ECDSA session key | 0 | 0 | no gas needed (used as signer only) |
| SessionKey2 | (derived, ephemeral) | scoped session key | 0 | 0 | — |
| DVT node1 | `BLS_TEST_NODE_ID_1` (pubkey registered at deploy) | DVT co-signer | n/a | n/a | BLS key already in `registeredKeys` |
| DVT node2 | `BLS_TEST_NODE_ID_2` (pubkey registered at deploy) | DVT co-signer | n/a | n/a | registered at deploy |

## 4. Test tokens
| Token | Status | Action |
|---|---|---|
| **MockERC20 "E2ET"** `0xeD075cD8b01F3F95120B218c3aD514d248E75011` | ✅ **DEPLOYED** 2026-06-15 (tx `0x455e2b22714d11e50653eb85f9fbec1ac1a76f196b6230173ce4c2a1192e35ad`) | 1,000,000 E2ET minted to Annie; has public `mint(to,amount)`. Register a TokenConfig on the S-B3 test account's guard before the transfer. |
| ETH (native) | available | use the sentinel `0xEeee…EEeE` semantics in guard |

## 4b. Part 1 prep — DONE (2026-06-15)
- ✅ Community funded 0.05 ETH from Jason — tx `0xe4068d2d87bd8f3c15628c6406d4e26ef493de61bef23e9869dc78c42f38d1f5`. (Note: Community is a Safe contract → guardian-sig scenarios use Jason+Bob EOAs, 2-of-3; Community does not send txs since v0.18 has no ERC-1271 guardian support.)
- ✅ MockERC20 deployed + 1M minted to Annie (above).

## 5. Pre-run setup checklist (Part 1 gate)
- [ ] Confirm all 11 beta.2 contracts above respond on-chain (read `ACCOUNT_VERSION`/`FACTORY_VERSION` = "0.18.0").
- [ ] Fund Community with 0.05 ETH from Jason (only if 3rd-guardian tx is in the final set).
- [ ] Deploy `MockERC20`, mint ≥ 1000 units to Annie; record address; will be added to a test account's guard TokenConfig.
- [ ] Verify DVT node1/node2 BLS pubkeys are in `AAStarBLSAlgorithm.registeredKeys` (registered at deploy).
- [ ] Confirm Pimlico bundler reachable (for S-D1).
- [ ] Confirm RIP-7212 (0x100) + EIP-2537 precompiles respond (for P256 / BLS scenarios).
- [ ] Salt registry: assign a unique salt per fresh account to avoid collisions with prior E2E runs (stale `activeRecovery` etc. — see `clearStaleRecovery` note in plan).

## 6. Output artifact (produced by the run, Part 2→3 input)
`docs/e2e/E2E_RESULTS_v0.18.0-beta.2.md` — one row per tx: `{S-ID, scenario, feature, params, txHash, status, gasUsed, etherscan, post-state assertion result}`. This file is the exact input handed to Codex for the challenge step.
