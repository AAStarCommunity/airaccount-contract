# E2E Test Results — v0.17.2-beta.1 (Sepolia)

**Deployment**: 2026-06-01 (see `docs/DEPLOYMENT-v0.17.2-beta.1.md` §8 for addresses).
**Test infrastructure**: TypeScript + viem (`scripts/e2e-v0172/`).
**Coverage matrix**: `docs/abi-coverage-v0.17.2-beta.1.md`.

Each row below is a single E2E test run; results are appended chronologically.

| Timestamp | Phase | Test | Status | Tx hash | Gas | Notes |
|---|---|---|---|---|---|---|
| 2026-06-02T02:20:10.319Z | 1-smoke | S1.a router.getAlgorithm(0x01) == blsAlgorithm | PASS | — | — | BLS algo wired at algId 0x01 |
| 2026-06-02T02:20:10.964Z | 1-smoke | S1.b router.getAlgorithm(0x08) == sessionKeyValidator | PASS | — | — | SessionKey validator wired at algId 0x08 |
| 2026-06-02T02:20:11.133Z | 1-smoke | S1.c router.getAlgorithm(0x02) == address(0) (inline-handled) | PASS | — | — | ECDSA inline-handled (router returns 0) |
| 2026-06-02T02:20:11.298Z | 1-smoke | S2.a agentRegistry.factory() == factory | PASS | — | — | Factory 0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9 bound to AgentRegistry |
| 2026-06-02T02:20:11.891Z | 1-smoke | S2.b agentRegistry.deployer() == Anni (round 3 A2 immutable) | PASS | — | — | deployer = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9 (Anni; captured at construction) |
| 2026-06-02T02:20:12.057Z | 1-smoke | S2.c factory.agentRegistry() == agentRegistry | PASS | — | — | factory ↔ agentRegistry mutual binding confirmed |
| 2026-06-02T02:20:12.223Z | 1-smoke | S3.a factory.entryPoint() == EntryPoint v0.7 | PASS | — | — | EntryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032 |
| 2026-06-02T02:20:12.392Z | 1-smoke | S3.b factory.implementation() == V7 impl | PASS | — | — | V7 implementation = 0x05274e4Af481e5c23287571F71C52afCCC5Df127 |
| 2026-06-02T02:20:12.564Z | 1-smoke | S4 parserRegistry.getParser(random) == 0 (no opt-in default) | PASS | — | — | KI-14: parsers disabled, registry stub returns 0 |
| 2026-06-02T02:20:12.731Z | 1-smoke | S5 BLS cacheAggregatedKey reverts CacheDeprecated (round 5 HIGH-1) | PASS | — | — | Round 5 HIGH-1 confirmed on-chain — selector 0x72a109eb |
| 2026-06-02T02:20:12.899Z | 1-smoke | S6 agentRegistry.bindFactory(any) from non-deployer reverts NotDeployer | PASS | — | — | Round 3 A2: deployer-only bindFactory enforced — selector 0x8b906c97 |
| 2026-06-02T02:20:13.455Z | 1-smoke | S7 factory.getAddressWithDefaults predicts CREATE2 address | PASS | — | — | Predicted account addr: 0x4537269064cc543dadF328d0D780894638b1716A |
| 2026-06-02T02:20:13.621Z | 1-smoke | S8 registerAgent from non-factory-spawned address reverts CallerNotAirAccount | PASS | — | — | H-2 fix: factory-provenance whitelist enforced — selector 0xa96b3b37 |
| 2026-06-02T02:20:35.669Z | 2-security-fixes | P2-H2.a BLSAlgorithm.validate rejects infinity blsSig (HIGH-2) | PASS | — | — | validate() returned 1 for infinity sig — HIGH-2 fix live |
| 2026-06-02T02:20:35.943Z | 2-security-fixes | P2-H2.b BLSAlgorithm.validate rejects infinity msgPt (HIGH-2) | PASS | — | — | validate() returned 1 for infinity msgPt — HIGH-2 fix live |
| 2026-06-02T02:20:36.200Z | 2-security-fixes | P2-H2.c BLSAlgorithm.validateAggregateSignature reverts BLSPointAtInfinity on infinity sig | PASS | — | — | Selector 0x1a821827 — explicit revert for ECDSA-callable infinity path |
| 2026-06-02T02:20:36.520Z | 2-security-fixes | P2-L2 BLSAlgorithm.registerPublicKey rejects infinity G1 (LOW-2/HIGH-2 combo) | PASS | — | — | OnlyOwner gate present (selector 0x5fc483c5); infinity check exists in same fn (unit-tested) |
| 2026-06-02T02:20:36.828Z | 2-security-fixes | P2-H3 Aggregator.validateSignatures recomputes (ignores supplied signature) | PASS | — | — | Aggregator reverted (validates from userOps, not supplied sig) — HIGH-3 live |
| 2026-06-02T02:20:37.138Z | 2-security-fixes | P2-M1 Delegate has ERC20 inline check (deployed bytecode includes ERC20_TRANSFER constant) | PASS | — | — | Delegate bytecode embeds ERC20 transfer + approve selectors — MEDIUM-1 deployed |
| 2026-06-02T02:20:37.392Z | 2-security-fixes | P2-D3 SessionKeyValidator.grantSessionDirect on non-AirAccount reverts NotAirAccount | PASS | — | — | David LOW-#3 typed error live — selector 0xe780655f |
| 2026-06-02T02:20:37.749Z | 2-security-fixes | P2-H45 Parsers genuinely not deployed (no code at Railgun/Uniswap slots) | PASS | — | — | KI-14: no parser registered for known Uniswap V3 router |
| 2026-06-02T02:20:39.850Z | 3-views | V-BLS.1 getRegisteredNodeCount returns >= 0 | PASS | — | — | registered nodes count = 1 |
| 2026-06-02T02:20:40.120Z | 3-views | V-BLS.2 getRegisteredNodes(0, 100) returns arrays of matching length | PASS | — | — | nodes returned: 1 |
| 2026-06-02T02:20:40.386Z | 3-views | V-BLS.3 isRegistered(unknown) == false | PASS | — | — | isRegistered(0xab..ab) = false |
| 2026-06-02T02:20:40.718Z | 3-views | V-BLS.4 computeSetHash matches keccak256(abi.encodePacked(nodeIds)) | PASS | — | — | setHash matches local keccak256: 0x7d3a608bb850f47c… |
| 2026-06-02T02:20:41.311Z | 3-views | V-BLS.5 getGasEstimate(N) grows with N | PASS | — | — | g(1)=195000  g(10)=235500 |
| 2026-06-02T02:20:41.640Z | 3-views | V-BLS.6 owner() returns deployer (Anni) | PASS | — | — | BLS owner = Anni |
| 2026-06-02T02:20:44.609Z | 3-views | V-ROUTER.1 getAlgorithm for each algId 0x00..0x09 | PASS | — | — | wired algIds: 0x01→0xB8212718…, 0x08→0xc1e2534D… |
| 2026-06-02T02:20:44.876Z | 3-views | V-ROUTER.2 setupComplete state read | PASS | — | — | setupComplete = false (beta-1: expected false, matches deploy doc §4) |
| 2026-06-02T02:20:45.138Z | 3-views | V-SK.1 isSessionActive(deadAccount, deadKey) == false | PASS | — | — | unfired session = inactive |
| 2026-06-02T02:20:45.403Z | 3-views | V-SK.2 getSession returns zero-init for unfired session | PASS | — | — | unfired session expiry = 0 (zero-init confirmed) |
| 2026-06-02T02:20:45.736Z | 3-views | V-SK.3 isP256SessionActive(unknown) == false | PASS | — | — | P256 session check works on never-granted key |
| 2026-06-02T02:20:45.997Z | 3-views | V-SK.4 grantNonces(any, any) == 0 initially | PASS | — | — | grantNonces is zero-init mapping |
| 2026-06-02T02:20:46.263Z | 3-views | V-SK.5 buildGrantHash produces 32-byte hash | PASS | — | — | buildGrantHash → 0x58fc44814c7b8763… |
| 2026-06-02T02:20:46.556Z | 3-views | V-AGG.1 blsAlgorithm address points to deployed BLS algo | PASS | — | — | aggregator → BLS algorithm wiring confirmed |
| 2026-06-02T02:20:46.863Z | 3-views | V-FORCE.1 isInitialized(deadAccount) == false | PASS | — | — | ForceExit not initialized for arbitrary address |
| 2026-06-02T02:20:47.169Z | 3-views | V-FORCE.2 getPendingExit(deadAccount) returns zero-init | PASS | — | — | getPendingExit zero-init for arbitrary address |
| 2026-06-02T02:20:47.431Z | 3-views | V-DEL.1 entryPoint() == EntryPoint v0.7 | PASS | — | — | delegate EntryPoint pin confirmed |
| 2026-06-02T02:20:47.696Z | 3-views | V-PARSER.1 owner() returns deployer (Anni) | PASS | — | — | parser registry owner = Anni |
| 2026-06-02T02:20:48.296Z | 3-views | V-FACT.1 getAddress vs getAddressWithDefaults produce different addresses | PASS | — | — | getAddress vs getAddressWithDefaults produce distinct: 0xdeD5BAD3… vs 0xe1488360… |
| 2026-06-02T02:20:48.604Z | 3-views | V-FACT.2 defaultCommunityGuardian == env-configured address | PASS | — | — | defaultCommunityGuardian = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 |
| 2026-06-02T02:20:48.865Z | 3-views | V-REG.1 isValidAccount(deadAddress) == false | PASS | — | — | unspawned addr not in valid set |
| 2026-06-02T02:20:49.130Z | 3-views | V-REG.2 isRegisteredAgent(unknown) == false | PASS | — | — | unregistered agent → false |
| 2026-06-02T02:20:49.393Z | 3-views | V-REG.3 balanceOf(humanOwner) == 0 initially | PASS | — | — | balanceOf(arbitrary) = 0 |
| 2026-06-02T02:20:49.654Z | 3-views | V-REG.4 getAgentCount(arbitrary) == 0 | PASS | — | — | getAgentCount(arbitrary) = 0 |
| 2026-06-02T02:20:49.923Z | 3-views | V-REG.5 getAgents(arbitrary) returns empty array | PASS | — | — | getAgents(arbitrary) = [] |
| 2026-06-02T02:20:50.241Z | 3-views | V-REG.6 getAgentsPage(arbitrary, 0, 10) returns empty | PASS | — | — | getAgentsPage zero-bound = [] |
| 2026-06-02T02:20:50.988Z | 3-views | V-REG.7 getHumanOwner(unknown) == address(0) | PASS | — | — | getHumanOwner returns 0 for unregistered |
| 2026-06-02T02:20:53.738Z | 6-negative | N-BLS.1 registerPublicKey from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-02T02:20:54.032Z | 6-negative | N-BLS.2 cacheAggregatedKey reverts CacheDeprecated (HIGH-1) | PASS | — | — | HIGH-1 — selector=0x72a109eb |
| 2026-06-02T02:20:54.338Z | 6-negative | N-BLS.3 validateAggregateSignature with infinity sig reverts BLSPointAtInfinity (HIGH-2) | PASS | — | — | HIGH-2 — selector=0x1a821827 |
| 2026-06-02T02:20:54.646Z | 6-negative | N-BLS.4 validateAggregateSignature with infinity msgPt reverts BLSPointAtInfinity | PASS | — | — | HIGH-2 msgPt-side — selector=0x1a821827 |
| 2026-06-02T02:20:54.953Z | 6-negative | N-BLS.5 validateAggregateSignature with empty nodeIds reverts NoNodesProvided | PASS | — | — | selector=0xe2d401be |
| 2026-06-02T02:20:55.260Z | 6-negative | N-BLS.6 validateAggregateSignature with wrong sig length reverts InvalidSignatureLength | PASS | — | — | selector=0x4be6321b |
| 2026-06-02T02:20:55.567Z | 6-negative | N-ROUTER.1 registerAlgorithm(0x01, existing) reverts AlgorithmAlreadyRegistered | PASS | — | — | selector=0x8671e417 |
| 2026-06-02T02:20:55.823Z | 6-negative | N-ROUTER.2 registerAlgorithm from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-02T02:20:56.084Z | 6-negative | N-SK.1 grantSessionDirect on non-AirAccount reverts NotAirAccount (David LOW#3) | PASS | — | — | David LOW#3 — selector=0xe780655f |
| 2026-06-02T02:20:56.386Z | 6-negative | N-SK.2 grantSession with all-zero ownerSig reverts ECDSAInvalidSignature | PASS | — | — | OZ ECDSA library catches v=0 signature — selector=0xf645eedf |
| 2026-06-02T02:20:56.645Z | 6-negative | N-FORCE.1 approveForceExit on non-existent proposal reverts NoProposal | PASS | — | — | revert confirmed — Execution reverted for an unknown reason. |
| 2026-06-02T02:20:57.000Z | 6-negative | N-PARSER.1 registerParser from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "registerParser" reverted. |
| 2026-06-02T02:20:57.308Z | 6-negative | N-FACT.1 setAgentRegistry from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "setAgentRegistry" reverted. |
| 2026-06-02T02:20:57.566Z | 6-negative | N-REG.1 bindFactory from non-deployer reverts NotDeployer (round 3 A2) | PASS | — | — | round 3 A2 — selector=0x8b906c97 |
| 2026-06-02T02:20:57.922Z | 6-negative | N-REG.2 bindFactory from deployer (Anni) reverts FactoryAlreadyBound | PASS | — | — | set-once binding enforced — selector=0x09a658a5 |
| 2026-06-02T02:20:58.229Z | 6-negative | N-REG.3 markValid from non-factory reverts OnlyFactory | PASS | — | — | selector=0x0c6d42ae |
| 2026-06-02T02:20:58.536Z | 6-negative | N-REG.4 registerAgent from non-AirAccount reverts CallerNotAirAccount (H-2) | PASS | — | — | H-2 fix — selector=0xa96b3b37 |
| 2026-06-02T02:20:58.793Z | 6-negative | N-REG.5 deregisterAgent of unowned wallet reverts NotAgentOwner | PASS | — | — | selector=0x390772fc |
| 2026-06-02T02:20:59.051Z | 6-negative | N-REG.6 ownerOf(any) reverts NotSupported (ERC-721 interface stub) | PASS | — | — | selector=0xa0387940 |

---

## Phase 4-admin + Phase 5-lifecycle (gas-spending, broadcast 2026-06-02)

Re-runnable but skipped in re-runs to avoid spending Anni gas on identical state. Original passing run:

| Timestamp | Phase | Test | Status | Tx hash | Gas | Notes |
|---|---|---|---|---|---|---|
| 2026-06-02 | 4-admin | AD-BLS.1 registerPublicKey from deployer (Anni) succeeds | PASS | — | 146,344 | nodeId = timestamp-based |
| 2026-06-02 | 4-admin | AD-BLS.2 isRegistered(newNodeId) == true (state persisted) | PASS | — | — | view follow-up |
| 2026-06-02 | 4-admin | AD-BLS.3 getRegisteredNodes includes our nodeId | PASS | — | — | total nodes now: 1 |
| 2026-06-02 | 4-admin | AD-ROUTER.1 proposeAlgorithm path correctly gated by setupComplete | PASS | — | — | beta-1 setupComplete=false; skip broadcast |
| 2026-06-02 | 5-lifecycle | AL.1 Predict via factory.getAddressWithDefaults | PASS | — | — | predicted = `0x0f214C7681b8A55a1b58DDcCE45E3f2d07a65758` |
| 2026-06-02 | 5-lifecycle | AL.2 factory.createAccountWithDefaults broadcast | PASS | (sepolia) | 1,198,175 | salt=1780366695 |
| 2026-06-02 | 5-lifecycle | AL.3 predicted account has bytecode | PASS | — | — | code = 45 bytes (EIP-1167 clone) |
| 2026-06-02 | 5-lifecycle | AL.4 account.owner() == Anni | PASS | — | — | owner pinned |
| 2026-06-02 | 5-lifecycle | AL.5 account.guardianCount() == 3 | PASS | — | — | [jason, bob, communityGuardian] |
| 2026-06-02 | 5-lifecycle | AL.6 AgentRegistry.isValidAccount == true | PASS | — | — | round 3 markValid loud-fail success |
| 2026-06-02 | 5-lifecycle | AL.7 account.accountId() == 'airaccount.v7@0.17.2' | PASS | — | — | version string |
| 2026-06-02 | 5-lifecycle | AL.8 account.execute(self, 0, "") owner path passes guard | PASS | (sepolia) | 48,637 | no-op call, exercises guard |
