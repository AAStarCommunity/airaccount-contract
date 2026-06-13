// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @dev issue #45: setAggregatorWithGuardians is guardian-gated — owner alone cannot change the
///      batch aggregator; owner + RECOVERY_THRESHOLD (=2) distinct guardian signatures are required.
///      This closes the "single compromised owner points blsAggregator at a malicious no-op verifier"
///      hole while keeping the batch-aggregation feature usable.
contract AggregatorAuthTest is Test {
    AAStarAirAccountV7 account;

    address entryPointAddr = makeAddr("entryPoint");
    address ownerAddr = makeAddr("owner");

    uint256 guardian1Key = uint256(keccak256(abi.encodePacked("guardian1")));
    uint256 guardian2Key = uint256(keccak256(abi.encodePacked("guardian2")));
    address guardian1 = makeAddr("guardian1");
    address guardian2 = makeAddr("guardian2");
    address guardian3 = makeAddr("guardian3");

    uint8 internal constant GUARDIAN_SIG_VERSION = 4;
    address constant AGG = address(0xA66);

    function setUp() public {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7();
        account.initialize(entryPointAddr, ownerAddr, config);

        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1);
        account.addGuardian(guardian2);
        account.addGuardian(guardian3);
        vm.stopPrank();
    }

    function _signSet(uint256 key, address agg, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "SET_AGGREGATOR",
            abi.encode(nonce, agg, deadline)
        ));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(h);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _twoSigs(address agg, uint256 nonce, uint256 deadline) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signSet(guardian1Key, agg, nonce, deadline);
        sigs[1] = _signSet(guardian2Key, agg, nonce, deadline);
    }

    // 1. owner + 2 guardians → succeeds
    function test_ownerPlusGuardians_succeeds() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(ownerAddr);
        account.setAggregatorWithGuardians(AGG, deadline, _twoSigs(AGG, 0, deadline));
        assertEq(account.blsAggregator(), AGG, "aggregator should be set");
    }

    // 2. owner alone (no guardian sigs) → reverts
    function test_ownerAlone_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory none = new bytes[](0);
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InsufficientGuardianApprovals()"));
        account.setAggregatorWithGuardians(AGG, deadline, none);
        assertEq(account.blsAggregator(), address(0), "aggregator must remain unset");
    }

    // 3. owner + only 1 guardian → reverts (below RECOVERY_THRESHOLD)
    function test_oneGuardian_insufficient_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory one = new bytes[](1);
        one[0] = _signSet(guardian1Key, AGG, 0, deadline);
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InsufficientGuardianApprovals()"));
        account.setAggregatorWithGuardians(AGG, deadline, one);
    }

    // 4. non-owner caller → reverts NotOwner (modifier runs before guardian checks)
    function test_nonOwner_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.setAggregatorWithGuardians(AGG, deadline, _twoSigs(AGG, 0, deadline));
    }

    // 5. expired deadline → reverts
    function test_expiredDeadline_reverts() public {
        vm.warp(1_000_000);
        uint256 deadline = 500_000; // strictly in the past
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("TierLimitSigExpired()"));
        account.setAggregatorWithGuardians(AGG, deadline, _twoSigs(AGG, 0, deadline));
    }

    // 6. duplicate guardian signature (same guardian twice) → reverts
    function test_duplicateGuardianSig_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory dup = new bytes[](2);
        dup[0] = _signSet(guardian1Key, AGG, 0, deadline);
        dup[1] = _signSet(guardian1Key, AGG, 0, deadline);
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("DuplicateGuardianSig()"));
        account.setAggregatorWithGuardians(AGG, deadline, dup);
    }

    // 7. disable (set to address(0)) is allowed under the guardian gate
    function test_disable_withGuardians() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(ownerAddr);
        account.setAggregatorWithGuardians(AGG, deadline, _twoSigs(AGG, 0, deadline));
        assertEq(account.blsAggregator(), AGG);

        // nonce is now 1; sign disable over nonce 1.
        vm.prank(ownerAddr);
        account.setAggregatorWithGuardians(address(0), deadline, _twoSigs(address(0), 1, deadline));
        assertEq(account.blsAggregator(), address(0), "aggregator should be disabled");
    }

    // 8. nonce replay: reusing nonce-0 signatures after a successful set must fail.
    function test_nonceReplay_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs0 = _twoSigs(AGG, 0, deadline);
        vm.prank(ownerAddr);
        account.setAggregatorWithGuardians(AGG, deadline, sigs0);

        // nonce advanced to 1; the same sigs (bound to nonce 0) now recover non-guardian addresses,
        // so _guardianIndex rejects them — the replay cannot succeed.
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.setAggregatorWithGuardians(AGG, deadline, sigs0);
    }
}
