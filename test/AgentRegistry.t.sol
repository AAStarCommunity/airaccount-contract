// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AgentRegistry} from "../src/registries/AgentRegistry.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

// ─── Minimal mock EntryPoint ──────────────────────────────────────────────────

contract MockEntryPoint {
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function withdrawTo(address payable, uint256) external {}
    receive() external payable {}
}

/// @title AgentRegistryTest — Unit + integration tests for AgentRegistry (M8.1)
contract AgentRegistryTest is Test {
    using MessageHashUtils for bytes32;

    AgentRegistry public registry;

    // Named wallets with known private keys for signature tests
    Vm.Wallet public aliceWallet;
    Vm.Wallet public bobWallet;
    Vm.Wallet public agentAWallet;
    Vm.Wallet public agentBWallet;

    address public alice;
    address public bob;
    address public agentA;
    address public agentB;

    function setUp() public {
        registry = new AgentRegistry();

        aliceWallet  = vm.createWallet("alice");
        bobWallet    = vm.createWallet("bob");
        agentAWallet = vm.createWallet("agentA");
        agentBWallet = vm.createWallet("agentB");

        alice  = aliceWallet.addr;
        bob    = bobWallet.addr;
        agentA = agentAWallet.addr;
        agentB = agentBWallet.addr;
    }

    // ─── Signature helper ─────────────────────────────────────────────────────

    /// @dev Build the canonical REGISTER_AGENT signature for (humanOwner, agentWallet).
    function _buildRegSig(
        uint256 agentPrivKey,
        address humanOwner,
        address agentWallet
    ) internal view returns (bytes memory) {
        bytes32 regHash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(registry), humanOwner, agentWallet)
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPrivKey, regHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── registerAgent ────────────────────────────────────────────────────────

    function test_RegisterAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentRegistered(alice, agentA);
        registry.registerAgent(agentA, sig);

        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.getAgentCount(alice), 1);
        assertEq(registry.getAgentByIndex(alice, 0), agentA);
    }

    function test_RegisterAgent_validSig_succeeds() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);

        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        assertEq(registry.agentWalletOwner(agentA), alice);
        assertTrue(registry.isRegisteredAgent(agentA));
    }

    function test_RegisterAgent_invalidSig_reverts() public {
        // Bob's private key signs but agentA address is claimed — wrong signer
        bytes memory wrongSig = _buildRegSig(bobWallet.privateKey, alice, agentA);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        registry.registerAgent(agentA, wrongSig);
    }

    function test_RegisterAgent_frontRunPrevented() public {
        // Attacker Eve tries to register agentA before Alice does
        // Eve does not control agentA's key, so she cannot produce a valid signature
        address eve = makeAddr("eve");

        // Eve tries with her own key signing for agentA — should fail
        Vm.Wallet memory eveWallet = vm.createWallet("eve");
        bytes memory attackSig = _buildRegSig(eveWallet.privateKey, eve, agentA);

        vm.prank(eve);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        registry.registerAgent(agentA, attackSig);

        // Alice can still register legitimately
        bytes memory aliceSig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, aliceSig);
        assertEq(registry.agentWalletOwner(agentA), alice);
    }

    function test_RegisterAgent_zeroAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAddress.selector);
        registry.registerAgent(address(0), "");
    }

    function test_RegisterAgent_alreadyRegistered_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);

        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        // Same caller, same agent — should revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        registry.registerAgent(agentA, sig);
    }

    function test_RegisterAgent_alreadyRegistered_differentCaller_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        // Different caller but same agentWallet — should still revert (agent already has an owner)
        // Bob would need a sig from agentA authorizing bob, but agentA is already registered
        bytes memory bobSig = _buildRegSig(agentAWallet.privateKey, bob, agentA);
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        registry.registerAgent(agentA, bobSig);
    }

    function test_RegisterAgent_multipleAgents_success() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);

        vm.prank(alice);
        registry.registerAgent(agentA, sigA);

        vm.prank(alice);
        registry.registerAgent(agentB, sigB);

        assertEq(registry.getAgentCount(alice), 2);
        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.agentWalletOwner(agentB), alice);
    }

    // ─── deregisterAgent ─────────────────────────────────────────────────────

    function test_DeregisterAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(alice, agentA);
        registry.deregisterAgent(agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(alice), 0);
    }

    function test_DeregisterAgent_notOwner_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        // Bob tries to deregister Alice's agent — should revert
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.deregisterAgent(agentA);
    }

    function test_DeregisterAgent_unregistered_reverts() public {
        // agentA was never registered — owner is address(0), so msg.sender != address(0)
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.deregisterAgent(agentA);
    }

    function test_DeregisterAgent_swapAndPop_preservesOtherAgents() public {
        Vm.Wallet memory agentCWallet = vm.createWallet("agentC");
        address agentC = agentCWallet.addr;

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);
        bytes memory sigC = _buildRegSig(agentCWallet.privateKey, alice, agentC);

        vm.startPrank(alice);
        registry.registerAgent(agentA, sigA);
        registry.registerAgent(agentB, sigB);
        registry.registerAgent(agentC, sigC);
        vm.stopPrank();

        assertEq(registry.getAgentCount(alice), 3);

        // Deregister the middle agent (agentB)
        vm.prank(alice);
        registry.deregisterAgent(agentB);

        assertEq(registry.getAgentCount(alice), 2);
        assertEq(registry.agentWalletOwner(agentB), address(0));
        // agentA and agentC should still be registered
        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.agentWalletOwner(agentC), alice);
    }

    function test_DeregisterAgent_O1_multipleAgents() public {
        // Verify O(1) removal correctness with 3+ agents:
        // register [A, B, C], remove B (index 1), verify array is [A, C] with correct index tracking
        Vm.Wallet memory agentCWallet = vm.createWallet("agentC2");
        address agentC = agentCWallet.addr;

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);
        bytes memory sigC = _buildRegSig(agentCWallet.privateKey, alice, agentC);

        vm.startPrank(alice);
        registry.registerAgent(agentA, sigA); // index 0
        registry.registerAgent(agentB, sigB); // index 1
        registry.registerAgent(agentC, sigC); // index 2
        vm.stopPrank();

        // Remove B (index 1) — C should swap into position 1
        vm.prank(alice);
        registry.deregisterAgent(agentB);

        assertEq(registry.getAgentCount(alice), 2);
        assertEq(registry.agentWalletOwner(agentB), address(0));
        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.agentWalletOwner(agentC), alice);

        // Further: remove A — C should still be accessible
        vm.prank(alice);
        registry.deregisterAgent(agentA);

        assertEq(registry.getAgentCount(alice), 1);
        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.agentWalletOwner(agentC), alice);

        // Remove C — array should be empty
        vm.prank(alice);
        registry.deregisterAgent(agentC);

        assertEq(registry.getAgentCount(alice), 0);
        assertEq(registry.agentWalletOwner(agentC), address(0));
    }

    // ─── isRegisteredAgent ────────────────────────────────────────────────────

    function test_IsRegisteredAgent() public {
        assertFalse(registry.isRegisteredAgent(agentA));

        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        assertTrue(registry.isRegisteredAgent(agentA));

        vm.prank(alice);
        registry.deregisterAgent(agentA);

        assertFalse(registry.isRegisteredAgent(agentA));
    }

    // ─── balanceOf ────────────────────────────────────────────────────────────

    function test_BalanceOf() public {
        // Before registration: 0
        assertEq(registry.balanceOf(alice), 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sigA);

        // After first registration: 1
        assertEq(registry.balanceOf(alice), 1);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);
        vm.prank(alice);
        registry.registerAgent(agentB, sigB);

        // After second registration: 2 (actual count, not capped at 1)
        assertEq(registry.balanceOf(alice), 2);

        vm.prank(alice);
        registry.deregisterAgent(agentA);

        vm.prank(alice);
        registry.deregisterAgent(agentB);

        // After all deregistered: 0
        assertEq(registry.balanceOf(alice), 0);
    }

    function test_BalanceOf_returnsActualCount() public {
        assertEq(registry.balanceOf(alice), 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sigA);
        assertEq(registry.balanceOf(alice), 1);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);
        vm.prank(alice);
        registry.registerAgent(agentB, sigB);
        assertEq(registry.balanceOf(alice), 2);

        // Bob registering does not affect alice's count
        assertEq(registry.balanceOf(bob), 0);
    }

    // ─── ownerOf ──────────────────────────────────────────────────────────────

    function test_OwnerOf_returnsZero() public view {
        // ownerOf is an ERC-721 stub — always returns address(0) regardless of agentId
        assertEq(registry.ownerOf(0),         address(0));
        assertEq(registry.ownerOf(1),         address(0));
        assertEq(registry.ownerOf(999),       address(0));
        assertEq(registry.ownerOf(type(uint256).max), address(0));
    }

    // ─── revokeAgent ─────────────────────────────────────────────────────────

    function test_RevokeAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);
        assertEq(registry.agentWalletOwner(agentA), alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(alice, agentA);
        registry.revokeAgent(agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(alice), 0);
        assertFalse(registry.isRegisteredAgent(agentA));
    }

    function test_RevokeAgent_notOwner_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sig);

        vm.prank(bob);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.revokeAgent(agentA);
    }

    function test_RevokeAgent_unregistered_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.revokeAgent(agentA);
    }

    function test_RevokeAgent_twoAgents_preservesOther() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);

        vm.startPrank(alice);
        registry.registerAgent(agentA, sigA);
        registry.registerAgent(agentB, sigB);
        vm.stopPrank();

        assertEq(registry.getAgentCount(alice), 2);

        vm.prank(alice);
        registry.revokeAgent(agentA);

        assertEq(registry.getAgentCount(alice), 1);
        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.agentWalletOwner(agentB), alice);
    }

    // ─── getHumanOwner ────────────────────────────────────────────────────────

    function test_GetHumanOwner() public {
        // Unregistered returns address(0)
        assertEq(registry.getHumanOwner(agentA), address(0));

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        registry.registerAgent(agentA, sigA);

        assertEq(registry.getHumanOwner(agentA), alice);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, bob, agentB);
        vm.prank(bob);
        registry.registerAgent(agentB, sigB);

        assertEq(registry.getHumanOwner(agentB), bob);

        // After deregistration returns address(0)
        vm.prank(alice);
        registry.deregisterAgent(agentA);
        assertEq(registry.getHumanOwner(agentA), address(0));
    }

    // ─── getAgents ────────────────────────────────────────────────────────────

    function test_GetAgents() public {
        // Empty before registration
        address[] memory empty = registry.getAgents(alice);
        assertEq(empty.length, 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);

        vm.startPrank(alice);
        registry.registerAgent(agentA, sigA);
        registry.registerAgent(agentB, sigB);
        vm.stopPrank();

        address[] memory agents = registry.getAgents(alice);
        assertEq(agents.length, 2);
        // Both agentA and agentB are present (order may vary after swap-and-pop)
        bool foundA = (agents[0] == agentA || agents[1] == agentA);
        bool foundB = (agents[0] == agentB || agents[1] == agentB);
        assertTrue(foundA);
        assertTrue(foundB);

        // Bob's list is unaffected
        assertEq(registry.getAgents(bob).length, 0);
    }

    function test_GetAgents_afterRevoke() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, alice, agentB);

        vm.startPrank(alice);
        registry.registerAgent(agentA, sigA);
        registry.registerAgent(agentB, sigB);
        vm.stopPrank();

        vm.prank(alice);
        registry.revokeAgent(agentA);

        address[] memory agents = registry.getAgents(alice);
        assertEq(agents.length, 1);
        assertEq(agents[0], agentB);
    }

    // ─── setAgentWallet integration (account → registry) ─────────────────────

    /// @dev Build sig for setAgentWallet integration tests where humanOwner = address(account).
    function _buildRegSigForAccount(
        uint256 agentPrivKey,
        address humanOwner,
        address agentWallet
    ) internal view returns (bytes memory) {
        bytes32 regHash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(registry), humanOwner, agentWallet)
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPrivKey, regHash);
        return abi.encodePacked(r, s, v);
    }

    function test_SetAgentWalletCallsRegistry() public {
        MockEntryPoint ep = new MockEntryPoint();

        // Deploy a fresh AirAccount
        AAStarAirAccountV7 account = new AAStarAirAccountV7();
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
            })
        );

        // Build signature: humanOwner = address(account), agentWallet = agentAWallet.addr
        bytes memory sig = _buildRegSigForAccount(agentAWallet.privateKey, address(account), agentA);

        vm.prank(ownerAddr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(1, agentA);
        account.setAgentWallet(1, agentA, address(registry), sig);

        // Verify registry recorded account as owner of agentA
        assertEq(registry.agentWalletOwner(agentA), address(account));
        assertTrue(registry.isRegisteredAgent(agentA));
    }

    function test_SetAgentWalletCallsRegistry_notOwner_reverts() public {
        MockEntryPoint ep = new MockEntryPoint();

        AAStarAirAccountV7 account = new AAStarAirAccountV7();
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
            })
        );

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        account.setAgentWallet(1, agentA, address(registry), "");
    }

    function test_SetAgentWalletCallsRegistry_failingRegistry_reverts() public {
        MockEntryPoint ep = new MockEntryPoint();

        AAStarAirAccountV7 account = new AAStarAirAccountV7();
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
            })
        );

        address noCodeAddr  = makeAddr("noCodeAddr"); // EOA with no code

        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        account.setAgentWallet(1, agentA, noCodeAddr, "");
    }

    function test_SetAgentWalletCallsRegistry_duplicateRegistration_reverts() public {
        MockEntryPoint ep = new MockEntryPoint();

        AAStarAirAccountV7 account = new AAStarAirAccountV7();
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
            })
        );

        bytes memory sig = _buildRegSigForAccount(agentAWallet.privateKey, address(account), agentA);

        vm.prank(ownerAddr);
        account.setAgentWallet(1, agentA, address(registry), sig);

        // Second call with same agentWallet should revert (AgentAlreadyRegistered propagated as AgentRegistrationFailed)
        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        account.setAgentWallet(2, agentA, address(registry), sig);
    }
}
