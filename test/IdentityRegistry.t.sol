// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IdentityRegistry} from "../src/registries/IdentityRegistry.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry public registry;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        registry = new IdentityRegistry();
    }

    // ─── register ────────────────────────────────────────────────────────────

    function test_register_mintsNFTToCaller() public {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        assertEq(registry.ownerOf(agentId), alice);
    }

    function test_register_returnsIncrementingIds() public {
        vm.startPrank(alice);
        uint256 id1 = registry.register("ipfs://Qm1");
        uint256 id2 = registry.register("ipfs://Qm2");
        vm.stopPrank();
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_register_storesURI() public {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        assertEq(registry.tokenURI(agentId), "ipfs://Qm1");
    }

    function test_register_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IIdentityRegistry.AgentIdentityRegistered(1, alice, "ipfs://Qm1");
        registry.register("ipfs://Qm1");
    }

    function test_register_differentCallersDifferentOwners() public {
        vm.prank(alice);
        uint256 id1 = registry.register("ipfs://alice");
        vm.prank(bob);
        uint256 id2 = registry.register("ipfs://bob");
        assertEq(registry.ownerOf(id1), alice);
        assertEq(registry.ownerOf(id2), bob);
    }

    // ─── burn ────────────────────────────────────────────────────────────────

    function test_burn_byOwner_succeeds() public {
        vm.startPrank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        registry.burn(agentId);
        vm.stopPrank();
        vm.expectRevert();
        registry.ownerOf(agentId);
    }

    function test_burn_byNonOwner_reverts() public {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        vm.prank(bob);
        vm.expectRevert(IdentityRegistry.TransferNotAllowed.selector);
        registry.burn(agentId);
    }

    // ─── non-transferable ────────────────────────────────────────────────────

    function test_transferFrom_reverts() public {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        vm.prank(alice);
        vm.expectRevert(IdentityRegistry.TransferNotAllowed.selector);
        registry.transferFrom(alice, bob, agentId);
    }

    function test_safeTransferFrom_reverts() public {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://Qm1");
        vm.prank(alice);
        vm.expectRevert(IdentityRegistry.TransferNotAllowed.selector);
        registry.safeTransferFrom(alice, bob, agentId, "");
    }

    // ─── IIdentityRegistry interface ─────────────────────────────────────────

    function test_implementsIIdentityRegistry() public view {
        IIdentityRegistry ir = IIdentityRegistry(address(registry));
        assertEq(address(ir), address(registry));
    }

    function test_tokenURI_nonExistentToken_reverts() public {
        vm.expectRevert();
        registry.tokenURI(999);
    }
}
