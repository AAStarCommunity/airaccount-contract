// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";

/// @title AAStarValidator M3 Tests - Governance timelock
contract AAStarValidatorM3Test is Test {
    AAStarValidator public router;
    address public owner = address(0xA1);
    address public algAddr = address(0xB1);
    address public algAddr2 = address(0xB2);

    function setUp() public {
        vm.prank(owner);
        router = new AAStarValidator();
    }

    // ─── Proposal Lifecycle ──────────────────────────────────────────

    function test_proposeAlgorithm_success() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        (address alg, uint256 proposedAt) = router.proposals(0x04);
        assertEq(alg, algAddr);
        assertEq(proposedAt, block.timestamp);
    }

    function test_proposeAlgorithm_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(AAStarValidator.OnlyOwner.selector);
        router.proposeAlgorithm(0x04, algAddr);
    }

    function test_proposeAlgorithm_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AAStarValidator.InvalidAlgorithmAddress.selector);
        router.proposeAlgorithm(0x04, address(0));
    }

    function test_proposeAlgorithm_alreadyRegistered() public {
        // Direct register first (existing M2 path)
        vm.prank(owner);
        router.registerAlgorithm(0x04, algAddr);

        vm.prank(owner);
        vm.expectRevert(AAStarValidator.AlgorithmAlreadyRegistered.selector);
        router.proposeAlgorithm(0x04, algAddr2);
    }

    function test_proposeAlgorithm_duplicateProposal() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        vm.prank(owner);
        vm.expectRevert(AAStarValidator.ProposalAlreadyPending.selector);
        router.proposeAlgorithm(0x04, algAddr2);
    }

    // ─── Execute Proposal ────────────────────────────────────────────

    function test_executeProposal_afterTimelock() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        // Warp past timelock
        vm.warp(block.timestamp + 7 days + 1);

        router.executeProposal(0x04);
        assertEq(router.algorithms(0x04), algAddr);

        // Proposal should be cleared
        (address alg,) = router.proposals(0x04);
        assertEq(alg, address(0));
    }

    function test_executeProposal_beforeTimelock() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        // Try before timelock
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert();
        router.executeProposal(0x04);
    }

    function test_executeProposal_noActiveProposal() public {
        vm.expectRevert(AAStarValidator.NoActiveProposal.selector);
        router.executeProposal(0x04);
    }

    function test_executeProposal_exactTimelock() public {
        uint256 start = block.timestamp;
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        // Exactly at timelock boundary
        vm.warp(start + 7 days);
        router.executeProposal(0x04);
        assertEq(router.algorithms(0x04), algAddr);
    }

    // ─── Cancel Proposal ─────────────────────────────────────────────

    function test_cancelProposal_success() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        vm.prank(owner);
        router.cancelProposal(0x04);

        (address alg,) = router.proposals(0x04);
        assertEq(alg, address(0));
    }

    function test_cancelProposal_onlyOwner() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        vm.prank(address(0xDEAD));
        vm.expectRevert(AAStarValidator.OnlyOwner.selector);
        router.cancelProposal(0x04);
    }

    function test_cancelProposal_noActive() public {
        vm.prank(owner);
        vm.expectRevert(AAStarValidator.NoActiveProposal.selector);
        router.cancelProposal(0x04);
    }

    // ─── Cancel then re-propose ──────────────────────────────────────

    function test_cancelAndRepropose() public {
        vm.startPrank(owner);
        router.proposeAlgorithm(0x04, algAddr);
        router.cancelProposal(0x04);
        router.proposeAlgorithm(0x04, algAddr2);
        vm.stopPrank();

        (address alg,) = router.proposals(0x04);
        assertEq(alg, algAddr2);
    }

    // ─── Anyone can execute ──────────────────────────────────────────

    function test_executeProposal_anyoneCanExecute() public {
        vm.prank(owner);
        router.proposeAlgorithm(0x04, algAddr);

        vm.warp(block.timestamp + 7 days);

        // Random address executes
        vm.prank(address(0xCAFE));
        router.executeProposal(0x04);
        assertEq(router.algorithms(0x04), algAddr);
    }

    // ─── Direct register still works (M2 compat) ────────────────────

    function test_directRegister_stillWorks() public {
        vm.prank(owner);
        router.registerAlgorithm(0x01, algAddr);
        assertEq(router.algorithms(0x01), algAddr);
    }

    // ─── TIMELOCK_DURATION constant ──────────────────────────────────

    function test_timelockDuration() public view {
        assertEq(router.TIMELOCK_DURATION(), 7 days);
    }
}
