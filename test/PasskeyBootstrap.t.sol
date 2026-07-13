// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @dev Minimal mock validator for testing P1 auto-wire.
contract MockValidator {}

/// @title PasskeyBootstrapTest — v0.22.0 P1 feature tests
/// @notice P1: validator auto-wired at account birth via impl immutable.
///         ownerP256X/Y set atomically at account birth via createAccount params.
contract PasskeyBootstrapTest is Test {
    Vm.Wallet ownerWallet;
    MockValidator mockValidator;
    AAStarAirAccountFactoryV7 factory;
    AAStarAirAccountV7 implWithRouter;
    AAStarAirAccountV7 implNoRouter;

    address[] noTokens;
    AAStarGlobalGuard.TokenConfig[] noConfigs;

    bytes32 constant PX = bytes32(uint256(0xdeadbeef));
    bytes32 constant PY = bytes32(uint256(0xcafebabe));

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        mockValidator = new MockValidator();

        implWithRouter = new AAStarAirAccountV7(address(mockValidator));
        implNoRouter   = new AAStarAirAccountV7(address(0));

        factory = new AAStarAirAccountFactoryV7(
            address(implWithRouter),
            address(0xEE), // entryPoint stub
            address(0),    // communityGuardian
            noTokens,
            noConfigs
        );
    }

    // ────────────────────────────────────────────────────────────────
    // P1: validator auto-wire at account birth
    // ────────────────────────────────────────────────────────────────

    function test_p1_validatorRouter_wiredOnImpl() public view {
        assertEq(implWithRouter.validatorRouter(), address(mockValidator));
    }

    function test_p1_implNoRouter_hasZeroAddress() public view {
        assertEq(implNoRouter.validatorRouter(), address(0));
    }

    function test_p1_accountCreated_validatorAutoSet() public {
        vm.prank(ownerWallet.addr);
        address account = factory.createAccount(ownerWallet.addr, 0, _emptyConfig(), bytes32(0), bytes32(0), 0, 0, new bytes(0));

        // Validator must equal the impl's validatorRouter, set at initialize() time.
        assertEq(address(AAStarAirAccountV7(payable(account)).validator()), address(mockValidator));
    }

    function test_p1_accountWithNoRouter_validatorUnset() public {
        AAStarAirAccountFactoryV7 noRouterFactory = new AAStarAirAccountFactoryV7(
            address(implNoRouter),
            address(0xEE),
            address(0),
            noTokens,
            noConfigs
        );

        vm.prank(ownerWallet.addr);
        address account = noRouterFactory.createAccount(ownerWallet.addr, 0, _emptyConfig(), bytes32(0), bytes32(0), 0, 0, new bytes(0));
        assertEq(address(AAStarAirAccountV7(payable(account)).validator()), address(0));
    }

    // ────────────────────────────────────────────────────────────────
    // ownerP256X/Y set at account birth via createAccount
    // ────────────────────────────────────────────────────────────────

    function test_p256Key_setOnAccountCreation() public {
        vm.prank(ownerWallet.addr);
        address account = factory.createAccount(ownerWallet.addr, 1, _emptyConfig(), PX, PY, 0, 0, new bytes(0));
        assertEq(AAStarAirAccountV7(payable(account)).p256KeyX(), PX);
        assertEq(AAStarAirAccountV7(payable(account)).p256KeyY(), PY);
    }

    function test_p256Key_notSetWhenZero() public {
        vm.prank(ownerWallet.addr);
        address account = factory.createAccount(ownerWallet.addr, 2, _emptyConfig(), bytes32(0), bytes32(0), 0, 0, new bytes(0));
        assertEq(AAStarAirAccountV7(payable(account)).p256KeyX(), bytes32(0));
        assertEq(AAStarAirAccountV7(payable(account)).p256KeyY(), bytes32(0));
    }

    function test_differentP256Keys_differentAddresses() public {
        address predicted1 = factory.getAddress(ownerWallet.addr, 3, _emptyConfig(), PX, PY);
        address predicted2 = factory.getAddress(ownerWallet.addr, 3, _emptyConfig(), bytes32(0), bytes32(0));
        assertTrue(predicted1 != predicted2, "different passkeys must yield different CREATE2 addresses");
    }

    function test_getAddress_matches_createAccount_withP256Key() public {
        address predicted = factory.getAddress(ownerWallet.addr, 4, _emptyConfig(), PX, PY);
        vm.prank(ownerWallet.addr);
        address actual = factory.createAccount(ownerWallet.addr, 4, _emptyConfig(), PX, PY, 0, 0, new bytes(0));
        assertEq(predicted, actual, "getAddress must match deployed address");
    }

    // ────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────

    function _emptyConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: new uint8[](0),
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
    }
}
