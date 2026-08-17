// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {IAirAccountAgent} from "../src/interfaces/IAirAccountAgent.sol";
import {AAStarAgentStorageLayout} from "../src/core/AAStarAgentStorageLayout.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";

interface IRecoveryCC102 {
    function proposeRecovery(address newOwner) external;
    function approveRecovery() external;
    function executeRecovery() external;
}

contract MockEP_CC102 {
    receive() external payable {}
}

contract MockBLSOk_CC102 is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure returns (uint256) { return 0; }
}

contract MockP256Ok_CC102 {
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(uint256(1)); }
}

/// @title CC-102 weighted-governance hardening — negative tests
/// @notice One test per fix delivered in this tag (F-W6 / F-W8 / F-W9 / F-W11). F-W5/F-W7
///         (guardian-set self-escalation) is a separate design decision, not covered here.
contract WeightedGovernanceHardeningCC102 is Test {
    using MessageHashUtils for bytes32;

    uint8 internal constant GUARDIAN_SIG_VERSION = 4;
    uint256 internal constant WEIGHT_CHANGE_TIMELOCK = 2 days;
    uint256 internal constant RECOVERY_TIMELOCK = 2 days;

    MockEP_CC102 ep;
    AAStarAirAccountV7 account;
    AAStarValidator router;

    Vm.Wallet ownerW;
    Vm.Wallet g0;
    Vm.Wallet g1;
    Vm.Wallet g2;

    AAStarAgentStorageLayout.WeightConfig safeConfig;

    function setUp() public {
        ownerW = vm.createWallet("owner");
        g0 = vm.createWallet("g0");
        g1 = vm.createWallet("g1");
        g2 = vm.createWallet("g2");

        ep = new MockEP_CC102();

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [g0.addr, g1.addr, g2.addr],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(address(ep), ownerW.addr, cfg, address(0), bytes32(0), bytes32(0));

        router = new AAStarValidator();
        router.registerAlgorithm(0x01, address(new MockBLSOk_CC102()));

        vm.startPrank(ownerW.addr);
        account.setValidator(address(router));
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();

        vm.etch(address(0x100), address(new MockP256Ok_CC102()).code);
        vm.deal(address(account), 100 ether);

        safeConfig = AAStarAgentStorageLayout.WeightConfig({
            passkeyWeight: 2, ecdsaWeight: 2, blsWeight: 2,
            guardian0Weight: 1, guardian1Weight: 1, guardian2Weight: 1,
            _padding: 0,
            tier1Threshold: 3, tier2Threshold: 4, tier3Threshold: 6
        });
    }

    function _cfg(address a) internal view returns (IAirAccountAgent) { return IAirAccountAgent(a); }

    // ── F-W6: enabling a previously-disabled tier (0 → N) must go through the guardian proposal flow ──

    function test_FW6_enableDisabledTier3_directSet_reverts() public {
        // Initialise with T3 DISABLED (tier3Threshold == 0, T2 still on).
        AAStarAgentStorageLayout.WeightConfig memory noT3 = safeConfig;
        noT3.tier3Threshold = 0;
        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(noT3);

        // Direct enable of T3 (0 → 6) is now a weakening → rejected without guardian consent.
        AAStarAgentStorageLayout.WeightConfig memory enableT3 = noT3;
        enableT3.tier3Threshold = 6;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeakeningRequiresProposal.selector);
        _cfg(address(account)).setWeightConfig(enableT3);
    }

    function test_FW6_enableDisabledTier3_viaProposal_succeeds() public {
        AAStarAgentStorageLayout.WeightConfig memory noT3 = safeConfig;
        noT3.tier3Threshold = 0;
        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(noT3);

        AAStarAgentStorageLayout.WeightConfig memory enableT3 = noT3;
        enableT3.tier3Threshold = 6;
        vm.prank(ownerW.addr);
        _cfg(address(account)).proposeWeightChange(enableT3);
        vm.prank(g0.addr); _cfg(address(account)).approveWeightChange();
        vm.prank(g1.addr); _cfg(address(account)).approveWeightChange();
        vm.warp(block.timestamp + WEIGHT_CHANGE_TIMELOCK + 1);
        _cfg(address(account)).executeWeightChange();

        (,,,,,,,,, uint8 t3) = account.weightConfig();
        assertEq(t3, 6);
    }

    function test_FW6_enableDisabledTier2_directSet_reverts() public {
        // T2 and T3 both disabled at init (tier3==0 requires tier2!=0, so disable T3 too).
        AAStarAgentStorageLayout.WeightConfig memory noT2 = safeConfig;
        noT2.tier2Threshold = 0;
        noT2.tier3Threshold = 0;
        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(noT2);

        AAStarAgentStorageLayout.WeightConfig memory enableT2 = noT2;
        enableT2.tier2Threshold = 4;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeakeningRequiresProposal.selector);
        _cfg(address(account)).setWeightConfig(enableT2);
    }

    // ── F-W11: the SUM of factor weights must fit the uint8 accumulator (no validation-phase Panic) ──

    function test_FW11_weightSumOverflowsUint8_reverts() public {
        // Each weight < tier1Threshold (255), but their sum (6*43 = 258) overflows the uint8 accumulator.
        AAStarAgentStorageLayout.WeightConfig memory bad;
        bad.passkeyWeight = 43; bad.ecdsaWeight = 43; bad.blsWeight = 43;
        bad.guardian0Weight = 43; bad.guardian1Weight = 43; bad.guardian2Weight = 43;
        bad.tier1Threshold = 255; bad.tier2Threshold = 0; bad.tier3Threshold = 0;

        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.InsecureWeightConfig.selector);
        _cfg(address(account)).setWeightConfig(bad);
    }

    function test_FW11_weightSumExactly255_ok() public {
        // Boundary: sum == 255 must PASS (the accumulator maxes at 255, no overflow).
        AAStarAgentStorageLayout.WeightConfig memory ok;
        ok.passkeyWeight = 50; ok.ecdsaWeight = 50; ok.blsWeight = 50;
        ok.guardian0Weight = 50; ok.guardian1Weight = 50; ok.guardian2Weight = 5; // sum = 255
        ok.tier1Threshold = 255; ok.tier2Threshold = 0; ok.tier3Threshold = 0;

        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(ok);

        (uint8 pk,,,,,,,,,) = account.weightConfig();
        assertEq(pk, 50);
    }

    // ── F-W8: recovery (owner change) clears any pending weakening weight-change proposal ──

    function test_FW8_executeRecovery_clearsPendingWeightChange() public {
        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(safeConfig);

        // Propose + approve a weakening (raise guardian0Weight 1 → 2) while the old owner is in control.
        AAStarAgentStorageLayout.WeightConfig memory weaker = safeConfig;
        weaker.guardian0Weight = 2;
        vm.prank(ownerW.addr);
        _cfg(address(account)).proposeWeightChange(weaker);
        vm.prank(g0.addr); _cfg(address(account)).approveWeightChange();
        vm.prank(g1.addr); _cfg(address(account)).approveWeightChange();

        // Guardians recover the account to a new owner.
        address newOwner = address(0xBEEF);
        vm.prank(g0.addr); IRecoveryCC102(address(account)).proposeRecovery(newOwner); // auto-approve
        vm.prank(g1.addr); IRecoveryCC102(address(account)).approveRecovery();
        vm.warp(block.timestamp + RECOVERY_TIMELOCK + 1);
        IRecoveryCC102(address(account)).executeRecovery();
        assertEq(account.owner(), newOwner);

        // The pending weakening did NOT survive: even past its own timelock it is gone.
        vm.warp(block.timestamp + WEIGHT_CHANGE_TIMELOCK + 1);
        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        _cfg(address(account)).executeWeightChange();
    }

    // ── F-W9: a guardian-set change (removeGuardian) invalidates in-flight weakening approvals ──

    function test_FW9_removeGuardian_clearsPendingWeightChange() public {
        vm.prank(ownerW.addr);
        _cfg(address(account)).setWeightConfig(safeConfig);

        AAStarAgentStorageLayout.WeightConfig memory weaker = safeConfig;
        weaker.guardian0Weight = 2;
        vm.prank(ownerW.addr);
        _cfg(address(account)).proposeWeightChange(weaker);
        vm.prank(g0.addr); _cfg(address(account)).approveWeightChange();
        vm.prank(g1.addr); _cfg(address(account)).approveWeightChange();

        // Remove a guardian (2-of-3 consensus). This must nuke the pending proposal so its slot-indexed
        // approval bits can never be re-counted against the compressed guardian set.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRemoval(g0.privateKey, g2.addr, 0, 2);
        sigs[1] = _signRemoval(g1.privateKey, g2.addr, 0, 2);
        vm.prank(ownerW.addr);
        account.removeGuardian(2, sigs);

        vm.warp(block.timestamp + WEIGHT_CHANGE_TIMELOCK + 1);
        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        _cfg(address(account)).executeWeightChange();
    }

    // ── F-W5/F-W7: the bootstrap add that REACHES RECOVERY_THRESHOLD (count 1 → 2) is timelocked ──

    /// @dev Fresh account with `n` ECDSA guardians (0..2 for these tests) — bypasses the 3-guardian setUp.
    function _accountWithGuardians(address gA, address gB) internal returns (AAStarAirAccountV7 a) {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [gA, gB, address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0, tier2Limit: 0
        });
        a = new AAStarAirAccountV7(address(0));
        a.initialize(address(ep), ownerW.addr, cfg, address(0), bytes32(0), bytes32(0));
    }

    function test_FW5_firstGuardian_instant() public {
        // count 0 → 1 stays instant (a lone guardian is below every quorum/threshold).
        AAStarAirAccountV7 a = _accountWithGuardians(address(0), address(0)); // 0 guardians
        address gA = makeAddr("gA");
        vm.prank(ownerW.addr);
        a.addGuardian(gA);
        assertEq(a.guardianCount(), 1);
    }

    function test_FW5_secondGuardian_instantAdd_reverts() public {
        AAStarAirAccountV7 a = _accountWithGuardians(makeAddr("gA"), address(0)); // 1 guardian
        address gB = makeAddr("gB");
        // count 1 → 2 without a proposal is rejected (this is the takeover-completing add).
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.GuardianAdditionNotProposed.selector);
        a.addGuardian(gB);
    }

    function test_FW5_secondGuardian_beforeTimelock_reverts() public {
        AAStarAirAccountV7 a = _accountWithGuardians(makeAddr("gA"), address(0));
        address gB = makeAddr("gB");
        vm.startPrank(ownerW.addr);
        a.proposeGuardianAddition(gB);
        vm.expectRevert(AAStarAirAccountBase.GuardianAdditionTimelockNotExpired.selector);
        a.addGuardian(gB); // timelock not elapsed
        vm.stopPrank();
    }

    function test_FW5_secondGuardian_afterTimelock_succeeds() public {
        AAStarAirAccountV7 a = _accountWithGuardians(makeAddr("gA"), address(0));
        address gB = makeAddr("gB");
        vm.startPrank(ownerW.addr);
        a.proposeGuardianAddition(gB);
        vm.warp(block.timestamp + 2 days + 1);
        a.addGuardian(gB);
        vm.stopPrank();
        assertEq(a.guardianCount(), 2);
        assertEq(a.guardians(1), gB);
    }

    function _signRemoval(uint256 privKey, address guardianAddr, uint256 nonce, uint8 index)
        internal view returns (bytes memory)
    {
        bytes32 removalHash = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "REMOVE_GUARDIAN",
            abi.encode(nonce, index, guardianAddr, bytes32(0), bytes32(0))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, MessageHashUtils.toEthSignedMessageHash(removalHash));
        return abi.encodePacked(r, s, v);
    }
}
