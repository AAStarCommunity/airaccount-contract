// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title AAStarAirAccountFactoryV7Test - Unit tests for CREATE2 factory
contract AAStarAirAccountFactoryV7Test is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public ownerA;
    address public ownerB;
    Vm.Wallet public g1Wallet;
    Vm.Wallet public g2Wallet;
    address public communityGuardian;

    uint256 constant TEST_DAILY_LIMIT = 0.5 ether;

    function setUp() public {
        entryPoint = makeAddr("entryPoint");
        ownerA = makeAddr("ownerA");
        ownerB = makeAddr("ownerB");
        g1Wallet = vm.createWallet("guardian1");
        g2Wallet = vm.createWallet("guardian2");
        communityGuardian = makeAddr("communityGuardian");

        factory = new AAStarAirAccountFactoryV7(entryPoint, communityGuardian);
    }

    /// @dev Sign the guardian acceptance message for a given owner+salt
    function _guardianSig(Vm.Wallet memory w, address owner, uint256 salt) internal pure returns (bytes memory) {
        bytes32 raw = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _minimalConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
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

    // ─── createAccountWithDefaults ──────────────────────────────────

    function test_createAccountWithDefaults() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        address account = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);

        assertTrue(account.code.length > 0);

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));
        assertEq(acc.owner(), ownerA);
        assertEq(acc.guardianCount(), 3);
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
        assertEq(acc.guardians(2), communityGuardian);

        // Guard should be initialized with user-specified daily limit
        assertTrue(address(acc.guard()) != address(0));
        AAStarGlobalGuard g = acc.guard();
        assertEq(g.account(), account);
        assertEq(g.dailyLimit(), TEST_DAILY_LIMIT);
        assertTrue(g.approvedAlgorithms(0x02)); // ECDSA
        assertTrue(g.approvedAlgorithms(0x01)); // BLS
        assertTrue(g.approvedAlgorithms(0x03)); // P256
    }

    function test_createAccountWithDefaults_deterministic() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 1);
        address a1 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        address a2 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        assertEq(a1, a2);
    }

    function test_getAddressWithDefaults_matchesCreated() public {
        address predicted = factory.getAddressWithDefaults(ownerA, 5, g1Wallet.addr, g2Wallet.addr, TEST_DAILY_LIMIT);
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 5);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 5);
        address actual = factory.createAccountWithDefaults(ownerA, 5, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        assertEq(predicted, actual);
    }

    function test_createAccountWithDefaults_differentLimits() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a1 = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, 0.1 ether);

        // Different limit → different config → different address (different initcode hash)
        // Need different salt since we're using the same owner and guardians
        bytes memory sig1b = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerA, 1);
        address a2 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, 1 ether);
        assertTrue(a1 != a2);
    }

    // ─── M5.3: Guardian acceptance validation ───────────────────────

    function test_guardian1_invalidSig_reverts() public {
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27)); // zero sig
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, badSig, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian2_invalidSig_reverts() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g2Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, badSig, TEST_DAILY_LIMIT);
    }

    function test_guardian1_wrongSigner_reverts() public {
        // g2 signs for g1's slot — wrong signer
        bytes memory wrongSig = _guardianSig(g2Wallet, ownerA, 0);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, wrongSig, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian_wrongOwner_reverts() public {
        // Guardian signs for wrong owner
        bytes memory sig1 = _guardianSig(g1Wallet, ownerB, 0); // signed for ownerB, not ownerA
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian_wrongSalt_reverts() public {
        // Guardian signs for wrong salt
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 99); // signed for salt=99, not 0
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    // ─── createAccount (full config) ────────────────────────────────

    function test_createAccount_fullConfig() public {
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = 0x02;
        algIds[1] = 0x03;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [g1Wallet.addr, g2Wallet.addr, address(0)],
            dailyLimit: 5 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        address account = factory.createAccount(ownerA, 0, config);
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        assertEq(acc.guardianCount(), 2);
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
        assertEq(acc.guard().dailyLimit(), 5 ether);
    }

    function test_getAddress_matchesCreated() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 123, config);
        address actual = factory.createAccount(ownerA, 123, config);
        assertEq(predicted, actual);
    }

    // ─── Different params produce different addresses ────────────────

    function test_differentOwners_differentAddresses() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, TEST_DAILY_LIMIT);

        bytes memory sig1b = _guardianSig(g1Wallet, ownerB, 0);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerB, 0);
        address b = factory.createAccountWithDefaults(ownerB, 0, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    function test_differentSalts_differentAddresses() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, TEST_DAILY_LIMIT);

        bytes memory sig1b = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerA, 1);
        address b = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    // ─── Factory state ──────────────────────────────────────────────

    function test_factoryEntryPoint() public view {
        assertEq(factory.entryPoint(), entryPoint);
    }

    function test_factoryCommunityGuardian() public view {
        assertEq(factory.defaultCommunityGuardian(), communityGuardian);
    }

    // ─── Event emission ─────────────────────────────────────────────

    function test_createAccount_emitsEvent() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 99, config);

        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountFactoryV7.AccountCreated(predicted, ownerA, 99);

        factory.createAccount(ownerA, 99, config);
    }
}
