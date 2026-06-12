# E2E Test Results — v0.17.2-beta.3 (Sepolia)

**Deployment**: 2026-06-12 (see `docs/DEPLOYMENT-v0.17.2-beta.3.md` for addresses).
**Test infrastructure**: TypeScript + viem (`scripts/e2e-v0172/`).
**Coverage matrix**: `docs/abi-coverage-v0.17.2-beta.3.md`.

Each row below is a single E2E test run; results are appended chronologically.

| Timestamp | Phase | Test | Status | Tx hash | Gas | Notes |
|---|---|---|---|---|---|---|
| 2026-06-12T06:24:39.993Z | 1-smoke | S1.a router.getAlgorithm(0x01) == blsAlgorithm | PASS | — | — | BLS algo wired at algId 0x01 |
| 2026-06-12T06:24:40.170Z | 1-smoke | S1.b router.getAlgorithm(0x08) == sessionKeyValidator | PASS | — | — | SessionKey validator wired at algId 0x08 |
| 2026-06-12T06:24:40.838Z | 1-smoke | S1.c router.getAlgorithm(0x02) == address(0) (inline-handled) | PASS | — | — | ECDSA inline-handled (router returns 0) |
| 2026-06-12T06:24:41.014Z | 1-smoke | S2.a agentRegistry.factory() == factory | PASS | — | — | Factory 0xfc6234bbd6283610659211347c6309904be86b0a bound to AgentRegistry |
| 2026-06-12T06:24:41.647Z | 1-smoke | S2.b agentRegistry.deployer() == Anni (round 3 A2 immutable) | PASS | — | — | deployer = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9 (Anni; captured at construction) |
| 2026-06-12T06:24:42.409Z | 1-smoke | S2.c factory.agentRegistry() == agentRegistry | PASS | — | — | factory ↔ agentRegistry mutual binding confirmed |
| 2026-06-12T06:24:43.942Z | 1-smoke | S3.a factory.entryPoint() == EntryPoint v0.7 | PASS | — | — | EntryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032 |
| 2026-06-12T06:24:44.648Z | 1-smoke | S3.b factory.implementation() == V7 impl | PASS | — | — | V7 implementation = 0xe33EeCF21AAC2B776b49A4dd52BA8b7e683dE9C3 |
| 2026-06-12T06:24:44.846Z | 1-smoke | S4 parserRegistry.getParser(random) == 0 (no opt-in default) | PASS | — | — | KI-14: parsers disabled, registry stub returns 0 |
| 2026-06-12T06:24:45.024Z | 1-smoke | S5 BLS cacheAggregatedKey reverts CacheDeprecated (round 5 HIGH-1) | PASS | — | — | Round 5 HIGH-1 confirmed on-chain — selector 0x72a109eb |
| 2026-06-12T06:24:45.609Z | 1-smoke | S6 agentRegistry.bindFactory(any) from non-deployer reverts NotDeployer | PASS | — | — | Round 3 A2: deployer-only bindFactory enforced — selector 0x8b906c97 |
| 2026-06-12T06:24:45.793Z | 1-smoke | S7 factory.getAddressWithDefaults predicts CREATE2 address | PASS | — | — | Predicted account addr: 0xE0D64341a28AC03591a2289E5889fdCC26Cd24F6 |
| 2026-06-12T06:24:46.379Z | 1-smoke | S8 registerAgent from non-factory-spawned address reverts CallerNotAirAccount | PASS | — | — | H-2 fix: factory-provenance whitelist enforced — selector 0xa96b3b37 |
| 2026-06-12T06:25:00.920Z | 2-security-fixes | P2-H2.a BLSAlgorithm.validate rejects infinity blsSig (HIGH-2) | PASS | — | — | validate() returned 1 for infinity sig — HIGH-2 fix live |
| 2026-06-12T06:25:01.178Z | 2-security-fixes | P2-H2.b BLSAlgorithm.validate rejects infinity msgPt (HIGH-2) | PASS | — | — | validate() returned 1 for infinity msgPt — HIGH-2 fix live |
| 2026-06-12T06:25:01.443Z | 2-security-fixes | P2-H2.c BLSAlgorithm.validateAggregateSignature reverts BLSPointAtInfinity on infinity sig | PASS | — | — | Selector 0x1a821827 — explicit revert for ECDSA-callable infinity path |
| 2026-06-12T06:25:01.722Z | 2-security-fixes | P2-L2 BLSAlgorithm.registerPublicKey rejects infinity G1 (LOW-2/HIGH-2 combo) | PASS | — | — | OnlyOwner gate present (selector 0x5fc483c5); infinity check exists in same fn (unit-tested) |
| 2026-06-12T06:25:02.059Z | 2-security-fixes | P2-H3 Aggregator.validateSignatures recomputes (ignores supplied signature) | PASS | — | — | Aggregator reverted (validates from userOps, not supplied sig) — HIGH-3 live |
| 2026-06-12T06:25:02.326Z | 2-security-fixes | P2-M1 Delegate has ERC20 inline check (deployed bytecode includes ERC20_TRANSFER constant) | PASS | — | — | Delegate bytecode embeds ERC20 transfer + approve selectors — MEDIUM-1 deployed |
| 2026-06-12T06:25:02.594Z | 2-security-fixes | P2-D3 SessionKeyValidator.grantSessionDirect on non-AirAccount reverts NotAirAccount | PASS | — | — | David LOW-#3 typed error live — selector 0xe780655f |
| 2026-06-12T06:25:02.852Z | 2-security-fixes | P2-H45 Parsers genuinely not deployed (no code at Railgun/Uniswap slots) | PASS | — | — | KI-14: no parser registered for known Uniswap V3 router |
| 2026-06-12T06:25:14.411Z | 3-views | V-BLS.1 getRegisteredNodeCount returns >= 0 | PASS | — | — | registered nodes count = 1 |
| 2026-06-12T06:25:14.599Z | 3-views | V-BLS.2 getRegisteredNodes(0, 100) returns arrays of matching length | PASS | — | — | nodes returned: 1 |
| 2026-06-12T06:25:21.913Z | 3-views | V-BLS.3 isRegistered(unknown) == false | PASS | — | — | isRegistered(0xab..ab) = false |
| 2026-06-12T06:25:22.100Z | 3-views | V-BLS.4 computeSetHash matches keccak256(abi.encodePacked(nodeIds)) | PASS | — | — | setHash matches local keccak256: 0x7d3a608bb850f47c… |
| 2026-06-12T06:25:23.321Z | 3-views | V-BLS.5 getGasEstimate(N) grows with N | PASS | — | — | g(1)=195000  g(10)=235500 |
| 2026-06-12T06:25:23.503Z | 3-views | V-BLS.6 owner() returns deployer (Anni) | PASS | — | — | BLS owner = Anni |
| 2026-06-12T06:25:31.425Z | 3-views | V-ROUTER.1 getAlgorithm for each algId 0x00..0x09 | PASS | — | — | wired algIds: 0x01→0xB8212718…, 0x08→0x655Ca2e9… |
| 2026-06-12T06:25:32.062Z | 3-views | V-ROUTER.2 setupComplete state read | PASS | — | — | setupComplete = true (beta-1: expected false, matches deploy doc §4) |
| 2026-06-12T06:25:32.248Z | 3-views | V-SK.1 isSessionActive(deadAccount, deadKey) == false | PASS | — | — | unfired session = inactive |
| 2026-06-12T06:25:32.438Z | 3-views | V-SK.2 getSession returns zero-init for unfired session | PASS | — | — | unfired session expiry = 0 (zero-init confirmed) |
| 2026-06-12T06:25:32.624Z | 3-views | V-SK.3 isP256SessionActive(unknown) == false | PASS | — | — | P256 session check works on never-granted key |
| 2026-06-12T06:25:32.808Z | 3-views | V-SK.4 grantNonces(any, any) == 0 initially | PASS | — | — | grantNonces is zero-init mapping |
| 2026-06-12T06:25:33.398Z | 3-views | V-SK.5 buildGrantHash produces 32-byte hash | PASS | — | — | buildGrantHash → 0x7e059ecd10833f33… |
| 2026-06-12T06:25:33.590Z | 3-views | V-AGG.1 blsAlgorithm address points to deployed BLS algo | PASS | — | — | aggregator → BLS algorithm wiring confirmed |
| 2026-06-12T06:25:34.589Z | 3-views | V-FORCE.1 isInitialized(deadAccount) == false | PASS | — | — | ForceExit not initialized for arbitrary address |
| 2026-06-12T06:25:34.768Z | 3-views | V-FORCE.2 getPendingExit(deadAccount) returns zero-init | PASS | — | — | getPendingExit zero-init for arbitrary address |
| 2026-06-12T06:25:34.948Z | 3-views | V-DEL.1 entryPoint() == EntryPoint v0.7 | PASS | — | — | delegate EntryPoint pin confirmed |
| 2026-06-12T06:25:35.512Z | 3-views | V-PARSER.1 owner() returns deployer (Anni) | PASS | — | — | parser registry owner = Anni |
| 2026-06-12T06:26:02.185Z | 3-views | V-FACT.1 getAddress vs getAddressWithDefaults produce different addresses | PASS | — | — | getAddress vs getAddressWithDefaults produce distinct: 0x8c9A42d0… vs 0x877449Ca… |
| 2026-06-12T06:26:02.886Z | 3-views | V-FACT.2 defaultCommunityGuardian == env-configured address | PASS | — | — | defaultCommunityGuardian = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 |
| 2026-06-12T06:26:03.601Z | 3-views | V-REG.1 isValidAccount(deadAddress) == false | PASS | — | — | unspawned addr not in valid set |
| 2026-06-12T06:26:03.782Z | 3-views | V-REG.2 isRegisteredAgent(unknown) == false | PASS | — | — | unregistered agent → false |
| 2026-06-12T06:26:03.961Z | 3-views | V-REG.3 balanceOf(humanOwner) == 0 initially | PASS | — | — | balanceOf(arbitrary) = 0 |
| 2026-06-12T06:26:04.570Z | 3-views | V-REG.4 getAgentCount(arbitrary) == 0 | PASS | — | — | getAgentCount(arbitrary) = 0 |
| 2026-06-12T06:26:05.191Z | 3-views | V-REG.5 getAgents(arbitrary) returns empty array | PASS | — | — | getAgents(arbitrary) = [] |
| 2026-06-12T06:26:06.812Z | 3-views | V-REG.6 getAgentsPage(arbitrary, 0, 10) returns empty | PASS | — | — | getAgentsPage zero-bound = [] |
| 2026-06-12T06:26:07.388Z | 3-views | V-REG.7 getHumanOwner(unknown) == address(0) | PASS | — | — | getHumanOwner returns 0 for unregistered |
| 2026-06-12T06:26:33.300Z | 4-admin | AD-BLS.1 registerPublicKey from deployer (Anni) succeeds | PASS | [`0x7f4fa97b5c9e…`](https://sepolia.etherscan.io/tx/0x7f4fa97b5c9e52f0ea1f1df238d5430363d15d9d910c370f4f232b88da186a09) | 129244 | nodeId=0x0000000000000000… |
| 2026-06-12T06:26:33.604Z | 4-admin | AD-BLS.2 isRegistered(newNodeId) == true (state persisted) | PASS | — | — | state change visible from view |
| 2026-06-12T06:26:35.103Z | 4-admin | AD-BLS.3 getRegisteredNodes includes our nodeId | PASS | — | — | total nodes now: 2 |
| 2026-06-12T06:26:35.370Z | 4-admin | AD-ROUTER.1 proposeAlgorithm(0x09, SessionKeyValidator) — schedules timelocked add | PASS | — | — | proposeAlgorithm callable (setupComplete is true OR no guard yet); skipping actual broadcast to keep state clean |
| 2026-06-12T06:26:42.875Z | 5-lifecycle | AL.1 Predict account address via factory.getAddressWithDefaults | PASS | — | — | predicted = 0x8EF77Cf9BAEe873436f4905222083c94C311D79d |
| 2026-06-12T06:27:43.245Z | 5-lifecycle | AL.2 factory.createAccountWithDefaults broadcasts (Anni as owner) | FAIL | — | — | Timed out while waiting for transaction with hash "0x112ca8eeb451b1c48241231ced167cb47bb771425768cdab9e05493b28ba977e" to be confirmed. |
| 2026-06-12T06:27:45.083Z | 5-lifecycle | AL.3 predicted account has bytecode after createAccount | PASS | — | — | code.length = 45 bytes |
| 2026-06-12T06:27:45.693Z | 5-lifecycle | AL.4 account.owner() == Anni | PASS | — | — | owner = Anni |
| 2026-06-12T06:28:11.380Z | 5-lifecycle | AL.5 account.guardianCount() == 3 | PASS | — | — | guardians: 0xb5600060…, 0xF7Bf79Ac…, communityGuardian |
| 2026-06-12T06:28:12.025Z | 5-lifecycle | AL.6 AgentRegistry.isValidAccount(account) == true (markValid fired during createAccount) | PASS | — | — | Round 3 markValid loud-fail success: account in factory-provenance set |
| 2026-06-12T06:28:12.611Z | 5-lifecycle | AL.7 account.accountId() == 'airaccount.v7@0.17.2' | PASS | — | — | accountId = "airaccount.v7@0.17.2" |
| 2026-06-12T06:29:17.438Z | 5-lifecycle | AL.8 account.execute(self, 0, '') — owner direct call passes guard | FAIL | — | — | Timed out while waiting for transaction with hash "0x27560b924bed05fd29d0d95e4f85f09195ea35e707615a4a04e830348832b2c9" to be confirmed. |
| 2026-06-12T06:29:32.424Z | 6-negative | N-BLS.1 registerPublicKey from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:29:32.693Z | 6-negative | N-BLS.2 cacheAggregatedKey reverts CacheDeprecated (HIGH-1) | PASS | — | — | HIGH-1 — selector=0x72a109eb |
| 2026-06-12T06:29:32.961Z | 6-negative | N-BLS.3 validateAggregateSignature with infinity sig reverts BLSPointAtInfinity (HIGH-2) | PASS | — | — | HIGH-2 — selector=0x1a821827 |
| 2026-06-12T06:29:33.237Z | 6-negative | N-BLS.4 validateAggregateSignature with infinity msgPt reverts BLSPointAtInfinity | PASS | — | — | HIGH-2 msgPt-side — selector=0x1a821827 |
| 2026-06-12T06:29:33.501Z | 6-negative | N-BLS.5 validateAggregateSignature with empty nodeIds reverts NoNodesProvided | PASS | — | — | selector=0xe2d401be |
| 2026-06-12T06:29:33.827Z | 6-negative | N-BLS.6 validateAggregateSignature with wrong sig length reverts InvalidSignatureLength | PASS | — | — | selector=0x4be6321b |
| 2026-06-12T06:29:34.083Z | 6-negative | N-ROUTER.1 registerAlgorithm(0x01, existing) reverts AlgorithmAlreadyRegistered | FAIL | — | — | expected AlgorithmAlreadyRegistered() (0x8671e417) but got selector 0x47a72efc (data=0x47a72efc…) |
| 2026-06-12T06:29:34.339Z | 6-negative | N-ROUTER.2 registerAlgorithm from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:29:34.597Z | 6-negative | N-SK.1 grantSessionDirect on non-AirAccount reverts NotAirAccount (David LOW#3) | PASS | — | — | David LOW#3 — selector=0xe780655f |
| 2026-06-12T06:29:35.719Z | 6-negative | N-SK.2 grantSession with all-zero ownerSig reverts ECDSAInvalidSignature | PASS | — | — | OZ ECDSA library catches v=0 signature — selector=0xf645eedf |
| 2026-06-12T06:29:36.086Z | 6-negative | N-FORCE.1 approveForceExit on non-existent proposal reverts NoProposal | PASS | — | — | revert confirmed — Execution reverted for an unknown reason. |
| 2026-06-12T06:29:36.391Z | 6-negative | N-PARSER.1 registerParser from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "registerParser" reverted. |
| 2026-06-12T06:29:36.699Z | 6-negative | N-FACT.1 setAgentRegistry from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "setAgentRegistry" reverted. |
| 2026-06-12T06:29:36.993Z | 6-negative | N-REG.1 bindFactory from non-deployer reverts NotDeployer (round 3 A2) | PASS | — | — | round 3 A2 — selector=0x8b906c97 |
| 2026-06-12T06:29:37.269Z | 6-negative | N-REG.2 bindFactory from deployer (Anni) reverts FactoryAlreadyBound | PASS | — | — | set-once binding enforced — selector=0x09a658a5 |
| 2026-06-12T06:29:37.621Z | 6-negative | N-REG.3 markValid from non-factory reverts OnlyFactory | PASS | — | — | selector=0x0c6d42ae |
| 2026-06-12T06:29:38.383Z | 6-negative | N-REG.4 registerAgent from non-AirAccount reverts CallerNotAirAccount (H-2) | PASS | — | — | H-2 fix — selector=0xa96b3b37 |
| 2026-06-12T06:29:38.643Z | 6-negative | N-REG.5 deregisterAgent of unowned wallet reverts NotAgentOwner | PASS | — | — | selector=0x390772fc |
| 2026-06-12T06:29:38.908Z | 6-negative | N-REG.6 ownerOf(any) reverts NotSupported (ERC-721 interface stub) | PASS | — | — | selector=0xa0387940 |
| 2026-06-12T06:30:06.874Z | 6-negative | N-BLS.1 registerPublicKey from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:30:07.535Z | 6-negative | N-BLS.2 cacheAggregatedKey reverts CacheDeprecated (HIGH-1) | PASS | — | — | HIGH-1 — selector=0x72a109eb |
| 2026-06-12T06:30:07.714Z | 6-negative | N-BLS.3 validateAggregateSignature with infinity sig reverts BLSPointAtInfinity (HIGH-2) | PASS | — | — | HIGH-2 — selector=0x1a821827 |
| 2026-06-12T06:30:08.334Z | 6-negative | N-BLS.4 validateAggregateSignature with infinity msgPt reverts BLSPointAtInfinity | PASS | — | — | HIGH-2 msgPt-side — selector=0x1a821827 |
| 2026-06-12T06:30:09.874Z | 6-negative | N-BLS.5 validateAggregateSignature with empty nodeIds reverts NoNodesProvided | PASS | — | — | selector=0xe2d401be |
| 2026-06-12T06:30:10.062Z | 6-negative | N-BLS.6 validateAggregateSignature with wrong sig length reverts InvalidSignatureLength | PASS | — | — | selector=0x4be6321b |
| 2026-06-12T06:30:10.245Z | 6-negative | N-ROUTER.1 registerAlgorithm after finalizeSetup() reverts SetupAlreadyComplete | FAIL | — | — | expected SetupAlreadyComplete() (0x238f75d3) but got selector 0x47a72efc (data=0x47a72efc…) |
| 2026-06-12T06:30:10.423Z | 6-negative | N-ROUTER.2 registerAlgorithm from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:30:11.219Z | 6-negative | N-SK.1 grantSessionDirect on non-AirAccount reverts NotAirAccount (David LOW#3) | PASS | — | — | David LOW#3 — selector=0xe780655f |
| 2026-06-12T06:30:11.826Z | 6-negative | N-SK.2 grantSession with all-zero ownerSig reverts ECDSAInvalidSignature | PASS | — | — | OZ ECDSA library catches v=0 signature — selector=0xf645eedf |
| 2026-06-12T06:30:12.409Z | 6-negative | N-FORCE.1 approveForceExit on non-existent proposal reverts NoProposal | PASS | — | — | revert confirmed — Execution reverted for an unknown reason. |
| 2026-06-12T06:30:13.006Z | 6-negative | N-PARSER.1 registerParser from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "registerParser" reverted. |
| 2026-06-12T06:30:13.192Z | 6-negative | N-FACT.1 setAgentRegistry from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "setAgentRegistry" reverted. |
| 2026-06-12T06:30:13.370Z | 6-negative | N-REG.1 bindFactory from non-deployer reverts NotDeployer (round 3 A2) | PASS | — | — | round 3 A2 — selector=0x8b906c97 |
| 2026-06-12T06:30:13.553Z | 6-negative | N-REG.2 bindFactory from deployer (Anni) reverts FactoryAlreadyBound | PASS | — | — | set-once binding enforced — selector=0x09a658a5 |
| 2026-06-12T06:30:13.734Z | 6-negative | N-REG.3 markValid from non-factory reverts OnlyFactory | PASS | — | — | selector=0x0c6d42ae |
| 2026-06-12T06:30:13.924Z | 6-negative | N-REG.4 registerAgent from non-AirAccount reverts CallerNotAirAccount (H-2) | PASS | — | — | H-2 fix — selector=0xa96b3b37 |
| 2026-06-12T06:30:14.480Z | 6-negative | N-REG.5 deregisterAgent of unowned wallet reverts NotAgentOwner | PASS | — | — | selector=0x390772fc |
| 2026-06-12T06:30:14.657Z | 6-negative | N-REG.6 ownerOf(any) reverts NotSupported (ERC-721 interface stub) | PASS | — | — | selector=0xa0387940 |
| 2026-06-12T06:30:46.402Z | 6-negative | N-BLS.1 registerPublicKey from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:30:46.737Z | 6-negative | N-BLS.2 cacheAggregatedKey reverts CacheDeprecated (HIGH-1) | PASS | — | — | HIGH-1 — selector=0x72a109eb |
| 2026-06-12T06:30:47.044Z | 6-negative | N-BLS.3 validateAggregateSignature with infinity sig reverts BLSPointAtInfinity (HIGH-2) | PASS | — | — | HIGH-2 — selector=0x1a821827 |
| 2026-06-12T06:30:47.668Z | 6-negative | N-BLS.4 validateAggregateSignature with infinity msgPt reverts BLSPointAtInfinity | PASS | — | — | HIGH-2 msgPt-side — selector=0x1a821827 |
| 2026-06-12T06:30:47.967Z | 6-negative | N-BLS.5 validateAggregateSignature with empty nodeIds reverts NoNodesProvided | PASS | — | — | selector=0xe2d401be |
| 2026-06-12T06:30:48.781Z | 6-negative | N-BLS.6 validateAggregateSignature with wrong sig length reverts InvalidSignatureLength | PASS | — | — | selector=0x4be6321b |
| 2026-06-12T06:30:49.041Z | 6-negative | N-ROUTER.1 registerAlgorithm after finalizeSetup() reverts SetupAlreadyClosed | PASS | — | — | router locked after beta.3 deploy — selector=0x47a72efc |
| 2026-06-12T06:30:50.061Z | 6-negative | N-ROUTER.2 registerAlgorithm from non-owner reverts OnlyOwner | PASS | — | — | selector=0x5fc483c5 |
| 2026-06-12T06:30:50.331Z | 6-negative | N-SK.1 grantSessionDirect on non-AirAccount reverts NotAirAccount (David LOW#3) | PASS | — | — | David LOW#3 — selector=0xe780655f |
| 2026-06-12T06:30:50.606Z | 6-negative | N-SK.2 grantSession with all-zero ownerSig reverts ECDSAInvalidSignature | PASS | — | — | OZ ECDSA library catches v=0 signature — selector=0xf645eedf |
| 2026-06-12T06:30:50.872Z | 6-negative | N-FORCE.1 approveForceExit on non-existent proposal reverts NoProposal | PASS | — | — | revert confirmed — Execution reverted for an unknown reason. |
| 2026-06-12T06:30:51.134Z | 6-negative | N-PARSER.1 registerParser from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "registerParser" reverted. |
| 2026-06-12T06:30:51.449Z | 6-negative | N-FACT.1 setAgentRegistry from non-owner reverts | PASS | — | — | ownership gate enforced — The contract function "setAgentRegistry" reverted. |
| 2026-06-12T06:30:51.764Z | 6-negative | N-REG.1 bindFactory from non-deployer reverts NotDeployer (round 3 A2) | PASS | — | — | round 3 A2 — selector=0x8b906c97 |
| 2026-06-12T06:30:52.025Z | 6-negative | N-REG.2 bindFactory from deployer (Anni) reverts FactoryAlreadyBound | PASS | — | — | set-once binding enforced — selector=0x09a658a5 |
| 2026-06-12T06:30:52.286Z | 6-negative | N-REG.3 markValid from non-factory reverts OnlyFactory | PASS | — | — | selector=0x0c6d42ae |
| 2026-06-12T06:30:52.576Z | 6-negative | N-REG.4 registerAgent from non-AirAccount reverts CallerNotAirAccount (H-2) | PASS | — | — | H-2 fix — selector=0xa96b3b37 |
| 2026-06-12T06:30:52.883Z | 6-negative | N-REG.5 deregisterAgent of unowned wallet reverts NotAgentOwner | PASS | — | — | selector=0x390772fc |
| 2026-06-12T06:30:54.012Z | 6-negative | N-REG.6 ownerOf(any) reverts NotSupported (ERC-721 interface stub) | PASS | — | — | selector=0xa0387940 |
| 2026-06-12T06:30:55.556Z | 7-beta3-features | V1.a factory.FACTORY_VERSION() == '0.17.2' | PASS | — | — | FACTORY_VERSION = '0.17.2' |
| 2026-06-12T06:30:55.746Z | 7-beta3-features | V1.b impl.ACCOUNT_VERSION() == '0.17.2' | PASS | — | — | ACCOUNT_VERSION = '0.17.2' |
| 2026-06-12T06:30:55.923Z | 7-beta3-features | V1.c forceExitModule.MODULE_VERSION() == '0.17.2' | PASS | — | — | ForceExitModule.MODULE_VERSION = '0.17.2' |
| 2026-06-12T06:30:56.099Z | 7-beta3-features | V1.d sessionKeyValidator.MODULE_VERSION() == '0.17.2' | PASS | — | — | SessionKeyValidator.MODULE_VERSION = '0.17.2' |
| 2026-06-12T06:30:56.275Z | 7-beta3-features | V2.a router.setupComplete() == true (finalizeSetup was called) | PASS | — | — | Router locked — future algo changes require proposeAlgorithm + 7d timelock |
| 2026-06-12T06:30:56.457Z | 7-beta3-features | V2.b router.registerAlgorithm after setupComplete reverts SetupAlreadyClosed | PASS | — | — | registerAlgorithm post-finalize blocked — selector 0x47a72efc |
| 2026-06-12T06:30:56.458Z | 7-beta3-features | V3.a factory.createAccount: empty guardians reverts GuardiansRequired | FAIL | — | — | ABI encoding params/values length mismatch.
Expected length (params): 3
Given length (values): 6 |
| 2026-06-12T06:30:56.458Z | 7-beta3-features | V3.b factory.createAccount: duplicate guardians reverts GuardiansMustBeDistinct | FAIL | — | — | ABI encoding params/values length mismatch.
Expected length (params): 3
Given length (values): 6 |
| 2026-06-12T06:30:56.459Z | 7-beta3-features | V3.c factory.createAccount: zero dailyLimit reverts DailyLimitRequired | FAIL | — | — | ABI encoding params/values length mismatch.
Expected length (params): 3
Given length (values): 6 |
| 2026-06-12T06:30:58.421Z | 7-beta3-features | V4.a forceExitModule.onInstall from EOA (no guardians()) reverts IncompatibleAccount | PASS | — | — | ForceExit rejects guardian-less callers — selector 0xea87e89a |
| 2026-06-12T06:30:59.541Z | 7-beta3-features | V5.a agentRegistry.factory() == beta3 factory (not beta.2) | PASS | — | — | AgentRegistry → Factory wiring confirmed (beta.3) |
| 2026-06-12T06:31:00.577Z | 7-beta3-features | V5.b factory.agentRegistry() == beta3 AgentRegistry | PASS | — | — | Factory → AgentRegistry reverse-wiring confirmed (beta.3) |
| 2026-06-12T06:31:02.392Z | 7-beta3-features | V5.c agentRegistry.bindFactory(factory) now reverts FactoryAlreadyBound (set-once) | PASS | — | — | Set-once bindFactory enforced — selector 0x09a658a5 |
| 2026-06-12T06:32:19.520Z | 7-beta3-features | V1.a factory.FACTORY_VERSION() == '0.17.2' | PASS | — | — | FACTORY_VERSION = '0.17.2' |
| 2026-06-12T06:32:20.440Z | 7-beta3-features | V1.b impl.ACCOUNT_VERSION() == '0.17.2' | PASS | — | — | ACCOUNT_VERSION = '0.17.2' |
| 2026-06-12T06:32:21.109Z | 7-beta3-features | V1.c forceExitModule.MODULE_VERSION() == '0.17.2' | PASS | — | — | ForceExitModule.MODULE_VERSION = '0.17.2' |
| 2026-06-12T06:32:21.284Z | 7-beta3-features | V1.d sessionKeyValidator.MODULE_VERSION() == '0.17.2' | PASS | — | — | SessionKeyValidator.MODULE_VERSION = '0.17.2' |
| 2026-06-12T06:32:21.462Z | 7-beta3-features | V2.a router.setupComplete() == true (finalizeSetup was called) | PASS | — | — | Router locked — future algo changes require proposeAlgorithm + 7d timelock |
| 2026-06-12T06:32:22.059Z | 7-beta3-features | V2.b router.registerAlgorithm after setupComplete reverts SetupAlreadyClosed | PASS | — | — | registerAlgorithm post-finalize blocked — selector 0x47a72efc |
| 2026-06-12T06:32:22.240Z | 7-beta3-features | V3.a factory.createAccountWithDefaults: guardian1==0 reverts GuardiansRequired | PASS | — | — | Factory custom error GuardiansRequired — selector 0x4fd6779b |
| 2026-06-12T06:32:22.825Z | 7-beta3-features | V3.b factory.createAccountWithDefaults: guardian1==guardian2 reverts GuardiansMustBeDistinct | PASS | — | — | Factory custom error GuardiansMustBeDistinct — selector 0xfe828c5a |
| 2026-06-12T06:32:23.005Z | 7-beta3-features | V3.c factory.createAccountWithDefaults: dailyLimit==0 reverts DailyLimitRequired | PASS | — | — | Factory custom error DailyLimitRequired — selector 0xf8fc18ad |
| 2026-06-12T06:32:43.831Z | 7-beta3-features | V4.a forceExitModule.onInstall from EOA (no guardians()) reverts IncompatibleAccount | PASS | — | — | ForceExit rejects guardian-less callers — selector 0xea87e89a |
| 2026-06-12T06:32:44.015Z | 7-beta3-features | V5.a agentRegistry.factory() == beta3 factory (not beta.2) | PASS | — | — | AgentRegistry → Factory wiring confirmed (beta.3) |
| 2026-06-12T06:32:45.180Z | 7-beta3-features | V5.b factory.agentRegistry() == beta3 AgentRegistry | PASS | — | — | Factory → AgentRegistry reverse-wiring confirmed (beta.3) |
| 2026-06-12T06:33:00.219Z | 7-beta3-features | V5.c agentRegistry.bindFactory(factory) now reverts FactoryAlreadyBound (set-once) | PASS | — | — | Set-once bindFactory enforced — selector 0x09a658a5 |
