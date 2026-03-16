// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/**
 * @title M5ScenarioTests - Business scenario tests for all M5 features
 *
 * Each test models a real user/attacker scenario as documented in docs/M5-plan.md.
 * Tests are grouped by milestone and named to tell the story of the scenario.
 *
 * M5.1 - ERC20 Token Guard: stolen ECDSA key cannot drain ERC20 assets
 * M5.2 - Governance Hardening: validator lockdown + cross-op replay prevention
 * M5.3 - Guardian Validation: wrong guardian address caught at creation time
 * M5.7 - Force Guard: zero daily limit rejected
 * M5.8 - Zero-Trust T1: TE compromise alone cannot transact
 */

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

// ═══════════════════════════════════════════════════════════════════════
// Mocks
// ═══════════════════════════════════════════════════════════════════════

/// @dev Minimal ERC20 mock - tracks balances, emits Transfer
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _symbol, uint8 _decimals) {
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) { return true; }
}

/// @dev Mock EntryPoint
contract MockEP {
    mapping(address => uint256) public balances;
    function depositTo(address a) external payable { balances[a] += msg.value; }
    function balanceOf(address a) external view returns (uint256) { return balances[a]; }
    function withdrawTo(address payable to, uint256 amount) external {
        balances[msg.sender] -= amount;
        (bool s,) = to.call{value: amount}("");
        require(s);
    }
    receive() external payable {}
}

/// @dev Mock algorithm that always succeeds
contract MockAlg is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }
}

/// @dev Mock P256 precompile that always returns valid
contract MockP256Valid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @dev Mock P256 precompile that always returns invalid
contract MockP256Invalid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test Base
// ═══════════════════════════════════════════════════════════════════════

contract M5ScenarioTests is Test {
    uint256 constant USDC_DEC = 1e6;
    uint8 constant ALG_ECDSA = 0x02;
    uint8 constant ALG_P256 = 0x03;
    uint8 constant ALG_T2 = 0x04;
    uint8 constant ALG_T3 = 0x05;
    uint8 constant ALG_COMBINED_T1 = 0x06;

    bytes4 constant ERC20_TRANSFER = 0xa9059cbb;
    bytes4 constant ERC20_APPROVE = 0x095ea7b3;

    MockEP entryPoint;
    AAStarAirAccountFactoryV7 factory;
    MockAlg mockAlg;
    MockP256Valid p256Valid;
    MockP256Invalid p256Invalid;

    Vm.Wallet aliceWallet;
    Vm.Wallet bobWallet;
    Vm.Wallet carolWallet;
    Vm.Wallet attackerWallet;
    Vm.Wallet g1Wallet;
    Vm.Wallet g2Wallet;

    address communityGuardian;

    function setUp() public {
        aliceWallet = vm.createWallet("alice");
        bobWallet = vm.createWallet("bob");
        carolWallet = vm.createWallet("carol");
        attackerWallet = vm.createWallet("attacker");
        g1Wallet = vm.createWallet("guardian1");
        g2Wallet = vm.createWallet("guardian2");

        communityGuardian = makeAddr("communityGuardian");

        entryPoint = new MockEP();
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        factory = new AAStarAirAccountFactoryV7(address(entryPoint), communityGuardian, noTokens, noConfigs);
        mockAlg = new MockAlg();
        p256Valid = new MockP256Valid();
        p256Invalid = new MockP256Invalid();

        // Default: valid P256 precompile at 0x100
        vm.etch(address(0x100), address(p256Valid).code);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _buildAccount(address owner) internal returns (AAStarAirAccountV7) {
        uint8[] memory algIds = new uint8[](4);
        algIds[0] = ALG_ECDSA;
        algIds[1] = ALG_P256;
        algIds[2] = ALG_T2;
        algIds[3] = ALG_T3;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        return new AAStarAirAccountV7(address(entryPoint), owner, config);
    }

    function _buildAccountWithTokenGuard(
        address owner,
        address token,
        uint256 t1,
        uint256 t2,
        uint256 daily
    ) internal returns (AAStarAirAccountV7) {
        uint8[] memory algIds = new uint8[](4);
        algIds[0] = ALG_ECDSA;
        algIds[1] = ALG_P256;
        algIds[2] = ALG_T2;
        algIds[3] = ALG_T3;

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({ tier1Limit: t1, tier2Limit: t2, dailyLimit: daily });

        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: cfgs
        });
        return new AAStarAirAccountV7(address(entryPoint), owner, config);
    }

    function _guardianAcceptSig(Vm.Wallet memory w, address owner, uint256 salt)
        internal pure returns (bytes memory)
    {
        bytes32 raw = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _buildUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _ecdsaSig(Vm.Wallet memory w, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(uint8(ALG_ECDSA), r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════════
    // M5.1 SCENARIO TESTS - ERC20 Token-Aware Guard
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Scenario: Alice has 10,000 USDC. Guard config: tier1=100 USDC, tier2=1000 USDC, daily=5000 USDC.
     * Happy path: small USDC transfer (50 USDC) with ECDSA succeeds.
     */
    function test_M51_scenario_aliceSmallUSDC_ECDSApasses() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        usdc.mint(address(alice), 10000 * USDC_DEC);
        vm.deal(address(alice), 1 ether);

        bytes memory transferData = abi.encodeWithSelector(ERC20_TRANSFER, bobWallet.addr, 50 * USDC_DEC);
        vm.prank(aliceWallet.addr);
        alice.execute(address(usdc), 0, transferData); // must NOT revert

        assertEq(usdc.balanceOf(bobWallet.addr), 50 * USDC_DEC);
    }

    /**
     * Scenario: Attacker has stolen Alice's ECDSA key.
     * Tries to drain all 10,000 USDC with a single ECDSA call => BLOCKED by tier guard.
     */
    function test_M51_scenario_stolenECDSA_cannotDrainUSDC() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        usdc.mint(address(alice), 10000 * USDC_DEC);
        vm.deal(address(alice), 1 ether);

        // Attacker (has Alice's ECDSA key, simulated by prank) tries to drain all USDC
        bytes memory drainData = abi.encodeWithSelector(ERC20_TRANSFER, attackerWallet.addr, 10000 * USDC_DEC);
        vm.prank(aliceWallet.addr); // attacker has the ECDSA key
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 3, 1));
        alice.execute(address(usdc), 0, drainData);

        assertEq(usdc.balanceOf(attackerWallet.addr), 0, "Attacker got nothing");
    }

    /**
     * Scenario: Attacker splits the drain into batches of 60 USDC, each below tier1 limit (100 USDC).
     * Cumulative check catches the second call when total would exceed tier1.
     */
    function test_M51_scenario_stolenECDSA_batchBypassPrevented() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        usdc.mint(address(alice), 10000 * USDC_DEC);
        vm.deal(address(alice), 1 ether);

        bytes memory batch1 = abi.encodeWithSelector(ERC20_TRANSFER, attackerWallet.addr, 60 * USDC_DEC);
        bytes memory batch2 = abi.encodeWithSelector(ERC20_TRANSFER, attackerWallet.addr, 60 * USDC_DEC);

        // First batch: 60 USDC (cumulative 60 <= 100, passes tier1)
        vm.prank(aliceWallet.addr);
        alice.execute(address(usdc), 0, batch1);
        assertEq(usdc.balanceOf(attackerWallet.addr), 60 * USDC_DEC);

        // Second batch: cumulative 120 > 100 => needs tier2 => BLOCKED
        vm.prank(aliceWallet.addr);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        alice.execute(address(usdc), 0, batch2);

        assertEq(usdc.balanceOf(attackerWallet.addr), 60 * USDC_DEC, "Attacker capped at 60 USDC");
    }

    /**
     * Scenario: Attacker tries to drain USDC over multiple days.
     * Daily limit of 5000 USDC caps per-day damage.
     */
    function test_M51_scenario_dailyCapLimitsMultiDayDrain() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        usdc.mint(address(alice), 100000 * USDC_DEC);

        // All guard calls require onlyAccount. Save guard ref first, then startPrank.
        AAStarGlobalGuard guard = alice.guard();
        address aliceAcct = address(alice);

        // Guard approved T3 for large transfers - but daily cap still applies
        vm.startPrank(aliceAcct);
        guard.approveAlgorithm(ALG_T3);

        // Day 1: Drain up to daily limit (5000 USDC)
        guard.checkTokenTransaction(address(usdc), 5000 * USDC_DEC, ALG_T3);
        vm.stopPrank();

        // Day 1: Any further amount blocked
        vm.prank(aliceAcct);
        vm.expectRevert(
            abi.encodeWithSelector(
                AAStarGlobalGuard.TokenDailyLimitExceeded.selector,
                address(usdc), 1 * USDC_DEC, 0
            )
        );
        guard.checkTokenTransaction(address(usdc), 1 * USDC_DEC, ALG_T3);

        // Day 2 (next day): cap resets
        vm.warp(block.timestamp + 1 days);
        vm.prank(aliceAcct);
        bool ok = guard.checkTokenTransaction(address(usdc), 5000 * USDC_DEC, ALG_T3);
        assertTrue(ok, "New day should reset daily cap");
    }

    /**
     * Scenario: Alice's account has USDC guard configured, but Bob's ERC20 (custom token)
     * is unconfigured. Bob's token transfers have no limits - pass-through.
     */
    function test_M51_scenario_unconfiguredToken_noLimits() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        MockERC20 bobToken = new MockERC20("BOB", 18);

        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        bobToken.mint(address(alice), 1_000_000 * 1e18);
        vm.deal(address(alice), 1 ether);

        // 999,999 BOB transfer with ECDSA - no token config => no limit
        bytes memory bigTransfer = abi.encodeWithSelector(ERC20_TRANSFER, bobWallet.addr, 999_999 * 1e18);
        vm.prank(aliceWallet.addr);
        alice.execute(address(bobToken), 0, bigTransfer); // must NOT revert

        assertEq(bobToken.balanceOf(bobWallet.addr), 999_999 * 1e18);
    }

    /**
     * Scenario: Alice wants to tighten USDC limits after seeing suspicious activity.
     * She decreases the daily limit - monotonic: cannot increase back.
     */
    function test_M51_scenario_tightenDailyLimit_irreversible() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, address(usdc),
            100 * USDC_DEC, 1000 * USDC_DEC, 5000 * USDC_DEC
        );

        // Alice sees suspicious activity, tightens daily limit to 500 USDC
        vm.prank(aliceWallet.addr);
        alice.guardDecreaseTokenDailyLimit(address(usdc), 500 * USDC_DEC);

        (, , uint256 daily) = alice.guard().tokenConfigs(address(usdc));
        assertEq(daily, 500 * USDC_DEC, "Daily limit should be tightened");

        // She cannot increase it back (attacker who got account control can't restore limits)
        vm.prank(aliceWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                AAStarGlobalGuard.TokenCanOnlyDecreaseLimit.selector,
                address(usdc), 500 * USDC_DEC, 5000 * USDC_DEC
            )
        );
        alice.guardDecreaseTokenDailyLimit(address(usdc), 5000 * USDC_DEC);
    }

    /**
     * Scenario: Non-ERC20 calldata (custom contract function) to a configured token address
     * is NOT intercepted by the token guard. Only transfer/approve selectors are checked.
     */
    function test_M51_scenario_nonERC20Calldata_notIntercepted() public {
        // Use an address with no code as the "token" address:
        // any call to it returns success=true with empty returndata (EVM behavior).
        // The guard is configured for this address with extremely tight limits.
        address targetToken = makeAddr("configurableToken");

        AAStarAirAccountV7 alice = _buildAccountWithTokenGuard(
            aliceWallet.addr, targetToken,
            1, 2, 3 // Extremely tight limits - any ERC20 transfer/approve call would fail
        );

        vm.deal(address(alice), 1 ether);

        // Call unknown selector (not transfer/approve) to the configured token address.
        // Guard only intercepts 0xa9059cbb (transfer) and 0x095ea7b3 (approve).
        // 0xdeadbeef is unknown => guard does NOT call checkTokenTransaction => no InsufficientTokenTier.
        // The EVM call to an empty address returns success => execute does NOT revert at all.
        bytes memory unknownCall = abi.encodeWithSelector(bytes4(0xdeadbeef));
        vm.prank(aliceWallet.addr);
        alice.execute(targetToken, 0, unknownCall); // must NOT revert
    }

    // ═══════════════════════════════════════════════════════════════════
    // M5.2 SCENARIO TESTS - Governance Hardening
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Scenario: AAStar team deploys validator router and registers initial algorithms.
     * After setup, calls finalizeSetup() to lock direct registration permanently.
     * Team cannot add backdoored algorithm without 7-day timelock observable by users.
     */
    function test_M52_scenario_teamFinalizes_subsequentRegistrationBlocked() public {
        AAStarValidator router = new AAStarValidator();
        MockAlg ecdsaAlg = new MockAlg();
        MockAlg blsAlg = new MockAlg();

        // Initial setup: register initial algorithms (fast path)
        router.registerAlgorithm(0x02, address(ecdsaAlg));
        router.registerAlgorithm(0x01, address(blsAlg));

        // Setup complete - lock it
        router.finalizeSetup();
        assertTrue(router.setupComplete(), "Setup should be locked");

        // Simulated rogue team member tries to register a backdoored ECDSA replacement
        // (Cannot replace existing - AlgorithmAlreadyRegistered fires first, but let's test new algId)
        MockAlg backdoor = new MockAlg();
        vm.expectRevert(AAStarValidator.SetupAlreadyClosed.selector);
        router.registerAlgorithm(0x09, address(backdoor)); // new algId, but setup locked

        // Legitimate new algorithm must go through 7-day timelock
        router.proposeAlgorithm(0x09, address(backdoor));
        (address alg, uint256 proposedAt) = router.proposals(0x09);
        assertEq(alg, address(backdoor));
        assertGt(proposedAt, 0, "Proposal should exist with timestamp");
    }

    /**
     * Scenario: Attacker captures a valid (userOpHash1, messagePoint, mpSig) tuple from Alice's Tier2 op.
     * Alice later submits another Tier2 UserOp (userOpHash2). Attacker tries to replay mpSig.
     * With F55 binding, the old mpSig is for userOpHash1 and fails against userOpHash2.
     */
    function test_M52_scenario_messagePointReplayPrevented() public {
        AAStarValidator router = new AAStarValidator();
        router.registerAlgorithm(0x01, address(mockAlg)); // BLS mock

        Vm.Wallet memory alice = vm.createWallet("alice_m52");
        AAStarAirAccountV7 account = _buildAccount(alice.addr);
        vm.deal(address(account), 10 ether);

        vm.prank(alice.addr);
        account.setValidator(address(router));
        vm.prank(alice.addr);
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        // Build userOpHash1
        PackedUserOperation memory op1 = _buildUserOp(address(account));
        bytes32 hash1 = keccak256(abi.encode(op1));

        // Alice's messagePoint and signature for hash1
        bytes memory messagePoint = new bytes(256);
        messagePoint[0] = 0xAB;

        // Sign mpSig with userOpHash1 binding (F55 format)
        bytes32 mpBound1 = keccak256(abi.encodePacked(hash1, messagePoint));
        bytes32 mpEthHash1 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", mpBound1));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(alice.privateKey, mpEthHash1);
        bytes memory mpSig1 = abi.encodePacked(r1, s1, v1);

        // Build userOpHash2 (different op)
        PackedUserOperation memory op2 = _buildUserOp(address(account));
        op2.nonce = 1; // different nonce
        bytes32 hash2 = keccak256(abi.encode(op2));

        // Attacker tries to replay mpSig1 against hash2 (cross-op replay attack)
        // Reconstruct: what would mpBound look like with hash2 but old mpSig1?
        // Contract computes: keccak256(hash2 ++ messagePoint), but mpSig1 was for hash1 ++ messagePoint
        // The recover call would return a different address => validation returns 1

        // Build fake Tier2 sig using the replayed mpSig1
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("node");
        bytes memory blsSig = new bytes(256);

        bytes memory fakeT2Sig = abi.encodePacked(
            bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), // P256 r,s (mock accepts any)
            bytes32(nodeIdsLength),
            fakeNodeId,
            blsSig,
            messagePoint,
            mpSig1 // replayed signature from hash1 => will not match hash2
        );

        op2.signature = abi.encodePacked(uint8(ALG_T2), fakeT2Sig);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(op2, hash2, 0);
        assertEq(result, 1, "Replayed messagePoint signature should fail");
    }

    // ═══════════════════════════════════════════════════════════════════
    // M5.3 SCENARIO TESTS - Guardian Validation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Scenario: Happy path. Bob invites his wife Alice and his brother Carol as guardians.
     * Both sign the acceptance message. Account created successfully.
     */
    function test_M53_scenario_bothGuardiansAccept_accountCreated() public {
        bytes memory sig1 = _guardianAcceptSig(g1Wallet, aliceWallet.addr, 42);
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 42);

        address account = factory.createAccountWithDefaults(
            aliceWallet.addr, 42,
            g1Wallet.addr, sig1,
            g2Wallet.addr, sig2,
            1 ether
        );

        assertTrue(account.code.length > 0, "Account should be deployed");
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
    }

    /**
     * Scenario: David creates account for his mother. He enters a typo for guardian1's address.
     * The real guardian1 can't sign because the address in the call is wrong.
     * Without M5.3: account created with wrong address, recovery permanently broken.
     * With M5.3: GuardianDidNotAccept reverts immediately at creation time.
     */
    function test_M53_scenario_typoGuardianAddress_caughtAtCreation() public {
        // Correct g1Wallet.addr, but sig was signed with g2Wallet (wrong key for that address slot)
        bytes memory wrongSig = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0); // signed by g2, not g1
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr)
        );
        factory.createAccountWithDefaults(
            aliceWallet.addr, 0,
            g1Wallet.addr, wrongSig, // g1 address but g2 signed it => mismatch
            g2Wallet.addr, sig2,
            1 ether
        );
    }

    /**
     * Scenario: UI bug pre-fills guardian field with zero address.
     * Zero address cannot sign => GuardianDidNotAccept.
     */
    function test_M53_scenario_zeroGuardian_rejectedAtCreation() public {
        bytes memory emptySig = new bytes(65); // zero sig
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        // Zero address as guardian1
        vm.expectRevert("Guardians required");
        factory.createAccountWithDefaults(
            aliceWallet.addr, 0,
            address(0), emptySig,
            g2Wallet.addr, sig2,
            1 ether
        );
    }

    /**
     * Scenario: Guardian acceptance sig is for a different owner.
     * Attacker pre-generated sig for their own account and tries to reuse it for Alice's account.
     */
    function test_M53_scenario_guardianSigForWrongOwner_rejected() public {
        // Guardian signed for attacker's account, not Alice's
        bytes memory wrongOwnerSig = _guardianAcceptSig(g1Wallet, attackerWallet.addr, 0);
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr)
        );
        factory.createAccountWithDefaults(
            aliceWallet.addr, 0, // Alice's account
            g1Wallet.addr, wrongOwnerSig, // but sig was for attackerWallet
            g2Wallet.addr, sig2,
            1 ether
        );
    }

    /**
     * Scenario: Guardian signs for salt=99 (a test account), sig is reused for salt=0 (production).
     * Salt binding prevents signature reuse across different account instances.
     */
    function test_M53_scenario_guardianSigForWrongSalt_rejected() public {
        bytes memory wrongSaltSig = _guardianAcceptSig(g1Wallet, aliceWallet.addr, 99); // salt=99
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr)
        );
        factory.createAccountWithDefaults(
            aliceWallet.addr, 0, // salt=0
            g1Wallet.addr, wrongSaltSig, // but sig was for salt=99
            g2Wallet.addr, sig2,
            1 ether
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // M5.7 SCENARIO TESTS - Force Guard Requirement
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Scenario: Developer integration test - accidentally passes dailyLimit=0.
     * Old behavior: guard deployed with no effective limit (unlimited).
     * New behavior: rejected immediately.
     */
    function test_M57_scenario_zeroDailyLimit_rejected() public {
        bytes memory sig1 = _guardianAcceptSig(g1Wallet, aliceWallet.addr, 0);
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        vm.expectRevert("Daily limit required");
        factory.createAccountWithDefaults(
            aliceWallet.addr, 0,
            g1Wallet.addr, sig1,
            g2Wallet.addr, sig2,
            0 // dailyLimit = 0 => rejected
        );
    }

    /**
     * Scenario: Developer correctly sets a 1-wei minimum limit.
     * Any positive value is accepted - forces intentional choice.
     */
    function test_M57_scenario_minimalNonZeroLimit_accepted() public {
        bytes memory sig1 = _guardianAcceptSig(g1Wallet, aliceWallet.addr, 0);
        bytes memory sig2 = _guardianAcceptSig(g2Wallet, aliceWallet.addr, 0);

        address account = factory.createAccountWithDefaults(
            aliceWallet.addr, 0,
            g1Wallet.addr, sig1,
            g2Wallet.addr, sig2,
            1 // dailyLimit = 1 wei => accepted (developer made explicit choice)
        );

        assertTrue(account.code.length > 0);
    }

    /**
     * Scenario: Raw createAccount (for testing) still accepts zero limit.
     * The force-guard applies only to the convenience method.
     */
    function test_M57_scenario_rawCreateAccount_acceptsZeroLimit() public {
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0, // explicitly zero - allowed in raw createAccount
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        address account = factory.createAccount(aliceWallet.addr, 0, config);
        assertTrue(account.code.length > 0, "Raw createAccount should succeed with zero limit");
    }

    // ═══════════════════════════════════════════════════════════════════
    // M5.8 SCENARIO TESTS - Zero-Trust Tier 1 (ALG_COMBINED_T1)
    // ═══════════════════════════════════════════════════════════════════

    function _buildCombinedT1Account(address owner) internal returns (AAStarAirAccountV7) {
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_COMBINED_T1;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        return new AAStarAirAccountV7(address(entryPoint), owner, config);
    }

    function _buildCombinedT1Sig(
        bytes32 userOpHash,
        Vm.Wallet memory ecdsaSigner
    ) internal pure returns (bytes memory) {
        // P256 r,s (mock accepts any value)
        bytes32 p256r = bytes32(uint256(0xAA));
        bytes32 p256s = bytes32(uint256(0xBB));

        // ECDSA signs userOpHash with EIP-191 prefix
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ecdsaSigner.privateKey, ethHash);

        return abi.encodePacked(uint8(ALG_COMBINED_T1), p256r, p256s, r, s, v);
    }

    /**
     * Scenario: Alice uses ALG_COMBINED_T1 (0x06) for all Tier-1 transactions.
     * Happy path: P256 (precompile returns valid) + ECDSA (owner signs) => validation succeeds.
     */
    function test_M58_scenario_combinedT1_bothFactorsValid_passes() public {
        AAStarAirAccountV7 alice = _buildCombinedT1Account(aliceWallet.addr);
        vm.deal(address(alice), 10 ether);

        vm.prank(aliceWallet.addr);
        alice.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        PackedUserOperation memory op = _buildUserOp(address(alice));
        bytes32 hash = keccak256(abi.encode(op));

        op.signature = _buildCombinedT1Sig(hash, aliceWallet);

        vm.prank(address(entryPoint));
        uint256 result = alice.validateUserOp(op, hash, 0);
        assertEq(result, 0, "Both factors valid => should pass");
    }

    /**
     * Scenario: TE (server) is compromised. Attacker has Alice's ECDSA key but not her device.
     * They submit a COMBINED_T1 sig with valid ECDSA but invalid P256 (no device = no passkey).
     * Validation fails - TE compromise alone cannot transact.
     */
    function test_M58_scenario_TEcompromised_ECDSAonly_fails() public {
        // Replace precompile with always-invalid mock (simulates: device not present)
        vm.etch(address(0x100), address(p256Invalid).code);

        AAStarAirAccountV7 alice = _buildCombinedT1Account(aliceWallet.addr);
        vm.prank(aliceWallet.addr);
        alice.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        PackedUserOperation memory op = _buildUserOp(address(alice));
        bytes32 hash = keccak256(abi.encode(op));

        // Attacker has ECDSA key (owns alice's TE) but P256 mock returns invalid
        op.signature = _buildCombinedT1Sig(hash, aliceWallet);

        vm.prank(address(entryPoint));
        uint256 result = alice.validateUserOp(op, hash, 0);
        assertEq(result, 1, "TE compromise alone cannot transact - P256 required");
    }

    /**
     * Scenario: Device is stolen. Attacker has the physical phone (P256 passes via precompile)
     * but doesn't have the ECDSA key (lives on server-side TE).
     * Validation fails - device theft alone cannot transact.
     */
    function test_M58_scenario_deviceStolen_P256only_fails() public {
        // P256 precompile returns valid (attacker has device + biometric)
        // But attacker uses WRONG ECDSA key (not the owner)

        AAStarAirAccountV7 alice = _buildCombinedT1Account(aliceWallet.addr);
        vm.prank(aliceWallet.addr);
        alice.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        PackedUserOperation memory op = _buildUserOp(address(alice));
        bytes32 hash = keccak256(abi.encode(op));

        // Attacker signs ECDSA with their own key (NOT alice's) - device stolen, TE not compromised
        op.signature = _buildCombinedT1Sig(hash, attackerWallet);

        vm.prank(address(entryPoint));
        uint256 result = alice.validateUserOp(op, hash, 0);
        assertEq(result, 1, "Device theft alone cannot transact - ECDSA required");
    }

    /**
     * Scenario: Standard ECDSA-only user account (algId=0x02) still works unchanged.
     * ALG_COMBINED_T1 is opt-in. Existing users unaffected.
     */
    function test_M58_scenario_standardECDSA_stillWorks_unaffected() public {
        AAStarAirAccountV7 alice = _buildAccount(aliceWallet.addr);
        vm.deal(address(alice), 1 ether);

        PackedUserOperation memory op = _buildUserOp(address(alice));
        bytes32 hash = keccak256(abi.encode(op));

        op.signature = _ecdsaSig(aliceWallet, hash);

        vm.prank(address(entryPoint));
        uint256 result = alice.validateUserOp(op, hash, 0);
        assertEq(result, 0, "Standard ECDSA should still work");
    }

    /**
     * Scenario: 0x06 maps to Tier 1 in the guard. Large transfers still require T2/T3.
     * User cannot use COMBINED_T1 to bypass tier enforcement.
     */
    function test_M58_scenario_combinedT1_tier1Only_largeTransferBlocked() public {
        AAStarAirAccountV7 alice = _buildCombinedT1Account(aliceWallet.addr);
        vm.deal(address(alice), 10 ether);

        // Set tier limits: above 0.1 ETH needs tier2+
        vm.prank(aliceWallet.addr);
        alice.setTierLimits(0.1 ether, 1 ether);

        vm.prank(aliceWallet.addr);
        alice.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        PackedUserOperation memory op = _buildUserOp(address(alice));
        // Set callData for a large ETH transfer - note: tier enforcement happens in _enforceGuard during execute
        // validateUserOp itself doesn't check tier, execute() does
        bytes32 hash = keccak256(abi.encode(op));
        op.signature = _buildCombinedT1Sig(hash, aliceWallet);

        // validateUserOp succeeds (sig is valid)
        vm.prank(address(entryPoint));
        uint256 result = alice.validateUserOp(op, hash, 0);
        assertEq(result, 0, "COMBINED_T1 signature itself is valid");

        // But executing a 0.5 ETH transfer (above tier1Limit) with algId=0x06 (tier1) is blocked
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountBase.InsufficientTier.selector, uint8(2), uint8(1)));
        alice.execute(address(0xdead), 0.5 ether, "");
    }
}
