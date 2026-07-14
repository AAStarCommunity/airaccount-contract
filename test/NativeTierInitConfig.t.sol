// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title #161 — native-ETH tier limits baked from InitConfig at account birth
/// @notice Verifies tier1Limit/tier2Limit passed in InitConfig are set at construction (symmetric
///         with per-token TokenConfig), lock the owner-only setTierLimits() latch, and validate
///         tier1<=tier2 — the same semantics as a post-init setTierLimits() but in one step.
contract NativeTierInitConfigTest is Test {
    address entryPoint = address(0xEE);
    address ownerAddr;

    function setUp() public {
        ownerAddr = makeAddr("owner");
    }

    function _config(uint256 t1, uint256 t2) internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: new uint8[](0),
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: t1,
            tier2Limit: t2
        });
    }

    function _newAccount(uint256 t1, uint256 t2) internal returns (AAStarAirAccountV7 a) {
        a = new AAStarAirAccountV7(address(0));
        a.initialize(entryPoint, ownerAddr, _config(t1, t2), address(0), bytes32(0), bytes32(0));
    }

    /// tier1 + tier2 both provided → both baked at birth.
    function test_nativeTier_bakedAtBirth() public {
        AAStarAirAccountV7 a = _newAccount(1 ether, 5 ether);
        assertEq(a.tier1Limit(), 1 ether, "tier1 baked");
        assertEq(a.tier2Limit(), 5 ether, "tier2 baked");
    }

    /// A birth-baked profile locks the owner-only setTierLimits() path (latch set).
    function test_nativeTier_baked_locksSetTierLimits() public {
        AAStarAirAccountV7 a = _newAccount(1 ether, 5 ether);
        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.CannotIncreaseTierLimit.selector);
        a.setTierLimits(2 ether, 6 ether);
    }

    /// tier1-only (tier2 == 0) is valid and still latches.
    function test_nativeTier_tier1Only_baked() public {
        AAStarAirAccountV7 a = _newAccount(1 ether, 0);
        assertEq(a.tier1Limit(), 1 ether, "tier1 baked");
        assertEq(a.tier2Limit(), 0, "tier2 unused");
        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.CannotIncreaseTierLimit.selector);
        a.setTierLimits(1 ether, 2 ether);
    }

    /// tier1 > tier2 (both > 0) is rejected at initialize — same guard as setTierLimits().
    function test_nativeTier_invalidConfig_reverts() public {
        AAStarAirAccountV7 a = new AAStarAirAccountV7(address(0));
        vm.expectRevert(AAStarAirAccountBase.InvalidTierConfig.selector);
        a.initialize(entryPoint, ownerAddr, _config(5 ether, 1 ether), address(0), bytes32(0), bytes32(0));
    }

    /// (0,0) leaves tiering unconfigured — default behavior, and setTierLimits() still works after.
    function test_nativeTier_zeroLeavesUnset() public {
        AAStarAirAccountV7 a = _newAccount(0, 0);
        assertEq(a.tier1Limit(), 0, "tier1 unset");
        assertEq(a.tier2Limit(), 0, "tier2 unset");
        // latch NOT set → owner may still configure post-init
        vm.prank(ownerAddr);
        a.setTierLimits(1 ether, 5 ether);
        assertEq(a.tier1Limit(), 1 ether, "settable post-init when not baked");
    }
}
