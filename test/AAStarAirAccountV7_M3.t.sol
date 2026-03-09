// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
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
        account = new AAStarAirAccountV7(entryPoint, ownerAddr);
        vm.deal(address(account), 10 ether);
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

    // ─── Guard Configuration ─────────────────────────────────────────

    function test_setGuard() public {
        guard = new AAStarGlobalGuard(ownerAddr, 1 ether);
        vm.prank(ownerAddr);
        account.setGuard(address(guard));
        assertEq(address(account.guard()), address(guard));
    }

    function test_setGuard_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.setGuard(address(0x1234));
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
