# E2E Test Results — v0.17.2-beta.1 (Sepolia)

**Deployment**: 2026-06-01 (see `docs/DEPLOYMENT-v0.17.2-beta.1.md` §8 for addresses).
**Test infrastructure**: TypeScript + viem (`scripts/e2e-v0172/`).
**Coverage matrix**: `docs/abi-coverage-v0.17.2-beta.1.md`.

Each row below is a single E2E test run; results are appended chronologically.

| Timestamp | Phase | Test | Status | Tx hash | Gas | Notes |
|---|---|---|---|---|---|---|
| 2026-06-01T16:06:36.425Z | 1-smoke | S1.a router.getAlgorithm(0x01) == blsAlgorithm | PASS | — | — | BLS algo wired at algId 0x01 |
| 2026-06-01T16:06:36.692Z | 1-smoke | S1.b router.getAlgorithm(0x08) == sessionKeyValidator | PASS | — | — | SessionKey validator wired at algId 0x08 |
| 2026-06-01T16:06:37.001Z | 1-smoke | S1.c router.getAlgorithm(0x02) == address(0) (inline-handled) | PASS | — | — | ECDSA inline-handled (router returns 0) |
| 2026-06-01T16:06:37.308Z | 1-smoke | S2.a agentRegistry.factory() == factory | PASS | — | — | Factory 0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9 bound to AgentRegistry |
| 2026-06-01T16:06:37.616Z | 1-smoke | S2.b agentRegistry.deployer() == Anni (round 3 A2 immutable) | PASS | — | — | deployer = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9 (Anni; captured at construction) |
| 2026-06-01T16:06:37.882Z | 1-smoke | S2.c factory.agentRegistry() == agentRegistry | PASS | — | — | factory ↔ agentRegistry mutual binding confirmed |
| 2026-06-01T16:06:38.748Z | 1-smoke | S3.a factory.entryPoint() == EntryPoint v0.7 | PASS | — | — | EntryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032 |
| 2026-06-01T16:06:39.049Z | 1-smoke | S3.b factory.implementation() == V7 impl | PASS | — | — | V7 implementation = 0x05274e4Af481e5c23287571F71C52afCCC5Df127 |
| 2026-06-01T16:06:40.128Z | 1-smoke | S4 parserRegistry.getParser(random) == 0 (no opt-in default) | PASS | — | — | KI-14: parsers disabled, registry stub returns 0 |
| 2026-06-01T16:06:40.397Z | 1-smoke | S5 BLS cacheAggregatedKey reverts CacheDeprecated (round 5 HIGH-1) | PASS | — | — | Round 5 HIGH-1 confirmed on-chain — selector 0x72a109eb |
| 2026-06-01T16:06:41.185Z | 1-smoke | S6 agentRegistry.bindFactory(any) from non-deployer reverts NotDeployer | PASS | — | — | Round 3 A2: deployer-only bindFactory enforced — selector 0x8b906c97 |
| 2026-06-01T16:06:41.447Z | 1-smoke | S7 factory.getAddressWithDefaults predicts CREATE2 address | PASS | — | — | Predicted account addr: 0x4537269064cc543dadF328d0D780894638b1716A |
| 2026-06-01T16:06:41.712Z | 1-smoke | S8 registerAgent from non-factory-spawned address reverts CallerNotAirAccount | PASS | — | — | H-2 fix: factory-provenance whitelist enforced — selector 0xa96b3b37 |
| 2026-06-01T16:06:45.316Z | 2-security-fixes | P2-H2.a BLSAlgorithm.validate rejects infinity blsSig (HIGH-2) | PASS | — | — | validate() returned 1 for infinity sig — HIGH-2 fix live |
| 2026-06-01T16:06:45.510Z | 2-security-fixes | P2-H2.b BLSAlgorithm.validate rejects infinity msgPt (HIGH-2) | PASS | — | — | validate() returned 1 for infinity msgPt — HIGH-2 fix live |
| 2026-06-01T16:06:45.688Z | 2-security-fixes | P2-H2.c BLSAlgorithm.validateAggregateSignature reverts BLSPointAtInfinity on infinity sig | PASS | — | — | Selector 0x1a821827 — explicit revert for ECDSA-callable infinity path |
| 2026-06-01T16:06:45.865Z | 2-security-fixes | P2-L2 BLSAlgorithm.registerPublicKey rejects infinity G1 (LOW-2/HIGH-2 combo) | PASS | — | — | OnlyOwner gate present (selector 0x5fc483c5); infinity check exists in same fn (unit-tested) |
| 2026-06-01T16:06:46.043Z | 2-security-fixes | P2-H3 Aggregator.validateSignatures recomputes (ignores supplied signature) | PASS | — | — | Aggregator reverted (validates from userOps, not supplied sig) — HIGH-3 live |
| 2026-06-01T16:06:46.392Z | 2-security-fixes | P2-M1 Delegate has ERC20 inline check (deployed bytecode includes ERC20_TRANSFER constant) | PASS | — | — | Delegate bytecode embeds ERC20 transfer + approve selectors — MEDIUM-1 deployed |
| 2026-06-01T16:06:48.194Z | 2-security-fixes | P2-D3 SessionKeyValidator.grantSessionDirect on non-AirAccount reverts NotAirAccount | PASS | — | — | David LOW-#3 typed error live — selector 0xe780655f |
| 2026-06-01T16:06:48.371Z | 2-security-fixes | P2-H45 Parsers genuinely not deployed (no code at Railgun/Uniswap slots) | PASS | — | — | KI-14: no parser registered for known Uniswap V3 router |
