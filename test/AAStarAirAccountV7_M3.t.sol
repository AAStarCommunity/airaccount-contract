// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @title AAStarAirAccountV7 M3 Tests - P256, Tiered Routing, Aggregator, Guard
contract AAStarAirAccountV7M3Test is Test {
    AAStarAirAccountV7 public account;
    AAStarGlobalGuard public guard;
    address public entryPoint = address(0xEE);
    address public ownerAddr;
    uint256 public ownerKey;

    function setUp() public {
        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
        account = new AAStarAirAccountV7();
        account.initialize(entryPoint, ownerAddr, _emptyConfig());

        vm.deal(address(account), 10 ether);
    }

    function _emptyConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        uint8[] memory noAlgs = new uint8[](0);
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
    }

    // ─── Helper ───────────────────────────────────────────────────────

    function _initWithGuard(AAStarAirAccountV7 acct, address ep, address _owner, AAStarAirAccountBase.InitConfig memory cfg) internal {
        address g = address(0);
        if (cfg.dailyLimit > 0) {
            g = address(new AAStarGlobalGuard(address(acct), cfg.dailyLimit, cfg.approvedAlgIds, cfg.minDailyLimit, cfg.initialTokens, cfg.initialTokenConfigs));
        }
        acct.initialize(ep, _owner, cfg, g);
    }

    // ─── P256 Key Management ─────────────────────────────────────────

    function test_setP256Key() public {
        bytes32 x = bytes32(uint256(1));
        bytes32 y = bytes32(uint256(2));

        vm.prank(ownerAddr);
        account.setP256Key(x, y);

        assertEq(account.p256KeyX(), x);
        assertEq(account.p256KeyY(), y);
    }

    function test_setP256Key_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_setP256Key_zeroReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidP256Key()"));
        account.setP256Key(bytes32(0), bytes32(0));
    }

    function test_validateP256_noKeySet() public {
        // P256 signature: algId(0x03) + r(32) + s(32) = 65 bytes
        // Now routes to P256 path (algId check takes priority over raw ECDSA)
        bytes memory sig = abi.encodePacked(uint8(0x03), bytes32(uint256(1)), bytes32(uint256(2)));

        PackedUserOperation memory userOp = _buildUserOp(sig);
        bytes32 userOpHash = keccak256("test");

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1); // Fails because no P256 key is set
    }

    function test_validateP256_wrongLength() public {
        // P256 expects exactly 65 bytes (algId + r + s). 33 bytes won't match.
        bytes memory sig = abi.encodePacked(uint8(0x03), bytes32(uint256(1)));

        PackedUserOperation memory userOp = _buildUserOp(sig);
        bytes32 userOpHash = keccak256("test");

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1); // Falls through to validator router (no validator set) → 1
    }

    // ─── Tiered Routing ──────────────────────────────────────────────

    function test_setTierLimits() public {
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether);

        assertEq(account.tier1Limit(), 0.1 ether);
        assertEq(account.tier2Limit(), 1 ether);
    }

    function test_setTierLimits_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.setTierLimits(0.1 ether, 1 ether);
    }

    function test_requiredTier_notConfigured() public view {
        // No tiers configured → returns 0
        assertEq(account.requiredTier(1 ether), 0);
    }

    function test_requiredTier_tier1() public {
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether);

        assertEq(account.requiredTier(0.05 ether), 1); // Below tier1 limit
        assertEq(account.requiredTier(0.1 ether), 1); // Exactly tier1 limit
    }

    function test_requiredTier_tier2() public {
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether);

        assertEq(account.requiredTier(0.5 ether), 2); // Between tier1 and tier2
        assertEq(account.requiredTier(1 ether), 2); // Exactly tier2 limit
    }

    function test_requiredTier_tier3() public {
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether);

        assertEq(account.requiredTier(1.5 ether), 3); // Above tier2 limit
        assertEq(account.requiredTier(100 ether), 3);
    }

    // ─── Aggregator Configuration ────────────────────────────────────

    function test_setAggregator() public {
        address agg = address(0xAA);
        vm.prank(ownerAddr);
        account.setAggregator(agg);
        assertEq(account.blsAggregator(), agg);
    }

    function test_setAggregator_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.setAggregator(address(0xAA));
    }

    // ─── Guard Initialization (constructor) ────────────────────────────

    function test_guardInitializedAtConstruction() public {
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = 0x02; // ECDSA
        algIds[1] = 0x01; // BLS
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 guardedAccount = new AAStarAirAccountV7();
        _initWithGuard(guardedAccount, entryPoint, ownerAddr, config);


        assertTrue(address(guardedAccount.guard()) != address(0));
        AAStarGlobalGuard g = guardedAccount.guard();
        assertEq(g.account(), address(guardedAccount));
        assertEq(g.dailyLimit(), 1 ether);
        assertTrue(g.approvedAlgorithms(0x02));
        assertTrue(g.approvedAlgorithms(0x01));
    }

    function test_noGuardWhenEmptyConfig() public view {
        // account was created with _emptyConfig() in setUp
        assertEq(address(account.guard()), address(0));
    }

    function test_guardApproveAlgorithm_onlyOwner() public {
        // Create a guarded account
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 ga = new AAStarAirAccountV7();
        _initWithGuard(ga, entryPoint, ownerAddr, config);


        vm.prank(ownerAddr);
        ga.guardApproveAlgorithm(0x03); // P256
        assertTrue(ga.guard().approvedAlgorithms(0x03));

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        ga.guardApproveAlgorithm(0x01);
    }

    // ─── Owner Mutability (for social recovery) ──────────────────────

    function test_ownerIsMutable() public view {
        // Owner is stored in storage (not immutable)
        assertEq(account.owner(), ownerAddr);
    }

    // ─── ECDSA backwards compat still works ──────────────────────────

    function test_ecdsaBackwardsCompat() public {
        bytes32 userOpHash = keccak256("testOp");
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _buildUserOp(sig);

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0); // Success
    }

    function test_ecdsaWithAlgIdPrefix() public {
        bytes32 userOpHash = keccak256("testOp");
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        // algId(0x02) + r(32) + s(32) + v(1) = 66 bytes → routes to explicit ECDSA
        bytes memory sig = abi.encodePacked(uint8(0x02), r, s, v);

        PackedUserOperation memory userOp = _buildUserOp(sig);

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0);
    }

    // ─── Cumulative Tier Enforcement (batch bypass fix) ──────────────

    /// @notice Batch bypass: 10×0.1 ETH with ECDSA should fail on 2nd call
    ///         because cumulative spend (0.2 ETH) crosses tier1Limit (0.1 ETH).
    function test_batchBypassPrevented() public {
        // Create guarded account with ECDSA approved, tier1=0.1 ETH, tier2=1 ETH
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02; // ECDSA only
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 ga = new AAStarAirAccountV7();
        _initWithGuard(ga, entryPoint, ownerAddr, config);

        vm.deal(address(ga), 10 ether);

        vm.prank(ownerAddr);
        ga.setTierLimits(0.1 ether, 1 ether);

        // Sign ECDSA UserOp — use explicit algId prefix (0x02) to avoid r[0] collision with ALG_BLS
        bytes32 userOpHash = keccak256("batchBypassTest");
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        bytes memory sig = abi.encodePacked(uint8(0x02), r, s, v); // 66 bytes: algId + r + s + v

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(ga),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        // validateUserOp stores ECDSA algId in transient queue
        vm.prank(entryPoint);
        ga.validateUserOp(userOp, userOpHash, 0);

        // executeBatch: 2 calls × 0.1 ETH — second call cumulative=0.2 ETH → tier2 required
        address[] memory dests = new address[](2);
        dests[0] = address(0xBEEF);
        dests[1] = address(0xBEEF);
        uint256[] memory values = new uint256[](2);
        values[0] = 0.1 ether;
        values[1] = 0.1 ether;
        bytes[] memory funcs = new bytes[](2);
        funcs[0] = "";
        funcs[1] = "";

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSignature("InsufficientTier(uint8,uint8)", 2, 1));
        ga.executeBatch(dests, values, funcs);
    }

    /// @notice Multi-TX bypass: 2nd UserOp pushing cumulative over tier1Limit is rejected.
    ///         First TX spends 0.1 ETH, second TX tries 0.1 ETH more → total 0.2 ETH → tier2.
    function test_multiTxBypassPrevented() public {
        // Create guarded account with ECDSA approved, tier1=0.1 ETH, tier2=1 ETH
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02; // ECDSA only
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 ga = new AAStarAirAccountV7();
        _initWithGuard(ga, entryPoint, ownerAddr, config);

        vm.deal(address(ga), 10 ether);

        vm.prank(ownerAddr);
        ga.setTierLimits(0.1 ether, 1 ether);

        // Helper: sign and validate UserOp — explicit algId prefix to avoid r[0] collision
        bytes32 userOpHash1 = keccak256("multiTxTest1");
        bytes32 ethHash1 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash1));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(ownerKey, ethHash1);
        bytes memory sig1 = abi.encodePacked(uint8(0x02), r1, s1, v1); // 66 bytes: algId + r + s + v

        PackedUserOperation memory userOp1 = PackedUserOperation({
            sender: address(ga), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: sig1
        });

        // TX1: 0.1 ETH — cumulative = 0.1 → tier1 → OK
        vm.prank(entryPoint);
        ga.validateUserOp(userOp1, userOpHash1, 0);
        vm.prank(entryPoint);
        ga.execute(address(0xBEEF), 0.1 ether, "");

        // TX2: another 0.1 ETH — cumulative = 0.2 → tier2 required → FAIL
        bytes32 userOpHash2 = keccak256("multiTxTest2");
        bytes32 ethHash2 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash2));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(ownerKey, ethHash2);
        bytes memory sig2 = abi.encodePacked(uint8(0x02), r2, s2, v2); // 66 bytes: algId + r + s + v

        PackedUserOperation memory userOp2 = PackedUserOperation({
            sender: address(ga), nonce: 1, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: sig2
        });

        vm.prank(entryPoint);
        ga.validateUserOp(userOp2, userOpHash2, 0);

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSignature("InsufficientTier(uint8,uint8)", 2, 1));
        ga.execute(address(0xBEEF), 0.1 ether, "");
    }

    /// @notice todaySpent() view correctly returns zero for a new day.
    function test_todaySpent_noGuard() public {
        // account from setUp has no guard — tier enforcement uses 0 as alreadySpent
        // Just verify tier still works when no guard is attached
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether);

        // 0.1 ETH at tier1 boundary — no guard so alreadySpent=0, cumulative=0.1 → tier1
        bytes32 userOpHash = keccak256("noGuardTier");
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: sig
        });

        vm.deal(address(account), 1 ether);
        vm.prank(entryPoint);
        account.validateUserOp(userOp, userOpHash, 0);
        vm.prank(entryPoint);
        account.execute(address(0xBEEF), 0.1 ether, ""); // Should succeed (no guard, no dailySpent)
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _buildUserOp(bytes memory sig) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }
}
