// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
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
    AgentRegistry public registry;

    address public alice;
    address public bob;
    address public agentA;
    address public agentB;

    function setUp() public {
        registry = new AgentRegistry();

        alice  = makeAddr("alice");
        bob    = makeAddr("bob");
        agentA = makeAddr("agentA");
        agentB = makeAddr("agentB");
    }

    // ─── registerAgent ────────────────────────────────────────────────────────

    function test_RegisterAgent_success() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentRegistered(alice, agentA);
        registry.registerAgent(agentA);

        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.getAgentCount(alice), 1);
        assertEq(registry.getAgentByIndex(alice, 0), agentA);
    }

    function test_RegisterAgent_zeroAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAddress.selector);
        registry.registerAgent(address(0));
    }

    function test_RegisterAgent_alreadyRegistered_reverts() public {
        vm.prank(alice);
        registry.registerAgent(agentA);

        // Same caller, same agent — should revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        registry.registerAgent(agentA);
    }

    function test_RegisterAgent_alreadyRegistered_differentCaller_reverts() public {
        vm.prank(alice);
        registry.registerAgent(agentA);

        // Different caller but same agentWallet — should still revert (agent already has an owner)
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        registry.registerAgent(agentA);
    }

    function test_RegisterAgent_multipleAgents_success() public {
        vm.prank(alice);
        registry.registerAgent(agentA);

        vm.prank(alice);
        registry.registerAgent(agentB);

        assertEq(registry.getAgentCount(alice), 2);
        assertEq(registry.agentWalletOwner(agentA), alice);
        assertEq(registry.agentWalletOwner(agentB), alice);
    }

    // ─── deregisterAgent ─────────────────────────────────────────────────────

    function test_DeregisterAgent_success() public {
        vm.prank(alice);
        registry.registerAgent(agentA);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(alice, agentA);
        registry.deregisterAgent(agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(alice), 0);
    }

    function test_DeregisterAgent_notOwner_reverts() public {
        vm.prank(alice);
        registry.registerAgent(agentA);

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
        address agentC = makeAddr("agentC");

        vm.startPrank(alice);
        registry.registerAgent(agentA);
        registry.registerAgent(agentB);
        registry.registerAgent(agentC);
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

    // ─── isRegisteredAgent ────────────────────────────────────────────────────

    function test_IsRegisteredAgent() public {
        assertFalse(registry.isRegisteredAgent(agentA));

        vm.prank(alice);
        registry.registerAgent(agentA);

        assertTrue(registry.isRegisteredAgent(agentA));

        vm.prank(alice);
        registry.deregisterAgent(agentA);

        assertFalse(registry.isRegisteredAgent(agentA));
    }

    // ─── balanceOf ────────────────────────────────────────────────────────────

    function test_BalanceOf() public {
        // Before registration: 0
        assertEq(registry.balanceOf(alice), 0);

        vm.prank(alice);
        registry.registerAgent(agentA);

        // After first registration: 1
        assertEq(registry.balanceOf(alice), 1);

        vm.prank(alice);
        registry.registerAgent(agentB);

        // Still 1 (balanceOf returns 1 if ANY agents registered, not the count)
        assertEq(registry.balanceOf(alice), 1);

        vm.prank(alice);
        registry.deregisterAgent(agentA);

        vm.prank(alice);
        registry.deregisterAgent(agentB);

        // After all deregistered: 0
        assertEq(registry.balanceOf(alice), 0);
    }

    // ─── setAgentWallet integration (account → registry) ─────────────────────

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

        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerAddr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(1, agentWallet);
        account.setAgentWallet(1, agentWallet, address(registry));

        // Verify registry recorded account as owner of agentWallet
        assertEq(registry.agentWalletOwner(agentWallet), address(account));
        assertTrue(registry.isRegisteredAgent(agentWallet));
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
        account.setAgentWallet(1, makeAddr("agentWallet"), address(registry));
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

        address agentWallet = makeAddr("agentWallet");
        address noCodeAddr  = makeAddr("noCodeAddr"); // EOA with no code

        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        account.setAgentWallet(1, agentWallet, noCodeAddr);
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

        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerAddr);
        account.setAgentWallet(1, agentWallet, address(registry));

        // Second call with same agentWallet should revert (AgentAlreadyRegistered propagated as AgentRegistrationFailed)
        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        account.setAgentWallet(2, agentWallet, address(registry));
    }
}
