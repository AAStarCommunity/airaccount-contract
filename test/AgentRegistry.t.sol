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

// ─── MockAirAccount ────────────────────────────────────────────────────────────
// Simulates an AirAccount contract that implements accountId() returning an
// "airaccount." prefixed string. Wraps registry.registerAgent calls as msg.sender.

contract MockAirAccount {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NotOwner");
        _;
    }

    /// @dev Implements the ERC-7579 accountId() selector required by AgentRegistry.HIGH-1 check.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.16.0";
    }

    /// @notice Calls registry.registerAgent on behalf of the owner.
    ///         msg.sender for the registry call will be address(this), which passes the
    ///         HIGH-1 AirAccount interface check.
    function registerAgent(AgentRegistry registry, address agentWallet, bytes calldata sig) external onlyOwner {
        registry.registerAgent(agentWallet, sig);
    }

    /// @notice Deregisters an agent wallet through the registry.
    function deregisterAgent(AgentRegistry registry, address agentWallet) external onlyOwner {
        registry.deregisterAgent(agentWallet);
    }

    /// @notice Revokes an agent wallet through the registry.
    function revokeAgent(AgentRegistry registry, address agentWallet) external onlyOwner {
        registry.revokeAgent(agentWallet);
    }
}

// ─── MockERC1271Wallet ─────────────────────────────────────────────────────────
// Smart-contract wallet that implements ERC-1271 isValidSignature.
// Controlled by a single EOA owner; validates signatures from that owner.

contract MockERC1271Wallet {
    address public signer;
    bool public returnValid; // if false, returns wrong magic value

    constructor(address _signer, bool _returnValid) {
        signer = _signer;
        returnValid = _returnValid;
    }

    /// @notice ERC-1271: return 0x1626ba7e if sig is valid for signer; otherwise return 0xffffffff.
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (returnValid) {
            address recovered = ECDSA.recover(hash, sig);
            if (recovered == signer) return bytes4(0x1626ba7e);
        }
        return bytes4(0xffffffff);
    }
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

    // MockAirAccount wrappers owned by alice / bob
    MockAirAccount public aliceAccount;
    MockAirAccount public bobAccount;

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

        // Deploy MockAirAccount instances for alice and bob.
        // These pass the HIGH-1 AirAccount interface check in registerAgent().
        aliceAccount = new MockAirAccount(alice);
        bobAccount   = new MockAirAccount(bob);
    }

    // ─── Signature helper ─────────────────────────────────────────────────────

    /// @dev Build the canonical REGISTER_AGENT signature for (humanOwner=account, agentWallet).
    ///      humanOwner must be address(account) since that is msg.sender when the registry call happens.
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

    // ─── HIGH-1: EOA caller reverts ───────────────────────────────────────────

    /// @notice Calling registerAgent directly from an EOA must revert with CallerNotAirAccount.
    ///         EOAs have no code so accountId() staticcall returns ok=false.
    function test_RegisterAgent_eoaCaller_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.CallerNotAirAccount.selector);
        registry.registerAgent(agentA, sig);
    }

    /// @notice Calling registerAgent from a contract that has no accountId() must revert.
    function test_RegisterAgent_contractWithoutAccountId_reverts() public {
        // MockEntryPoint has no accountId() function
        MockEntryPoint ep = new MockEntryPoint();
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(ep), agentA);

        vm.prank(address(ep));
        vm.expectRevert(AgentRegistry.CallerNotAirAccount.selector);
        registry.registerAgent(agentA, sig);
    }

    // ─── registerAgent ────────────────────────────────────────────────────────

    function test_RegisterAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentRegistered(address(aliceAccount), agentA);
        aliceAccount.registerAgent(registry, agentA, sig);

        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.getAgentCount(address(aliceAccount)), 1);
        assertEq(registry.getAgentByIndex(address(aliceAccount), 0), agentA);
    }

    function test_RegisterAgent_validSig_succeeds() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertTrue(registry.isRegisteredAgent(agentA));
    }

    function test_RegisterAgent_invalidSig_reverts() public {
        // Bob's private key signs but agentA address is claimed — wrong signer
        bytes memory wrongSig = _buildRegSig(bobWallet.privateKey, address(aliceAccount), agentA);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        aliceAccount.registerAgent(registry, agentA, wrongSig);
    }

    function test_RegisterAgent_frontRunPrevented() public {
        // Attacker Eve tries to register agentA before Alice does.
        // Eve does not control agentA's key, so she cannot produce a valid signature.
        MockAirAccount eveAccount = new MockAirAccount(makeAddr("eve"));
        Vm.Wallet memory eveWallet = vm.createWallet("eve");
        bytes memory attackSig = _buildRegSig(eveWallet.privateKey, address(eveAccount), agentA);

        vm.prank(eveWallet.addr);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        eveAccount.registerAgent(registry, agentA, attackSig);

        // Alice can still register legitimately
        bytes memory aliceSig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, aliceSig);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
    }

    function test_RegisterAgent_zeroAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAddress.selector);
        aliceAccount.registerAgent(registry, address(0), "");
    }

    function test_RegisterAgent_alreadyRegistered_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        // Same caller, same agent — should revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        aliceAccount.registerAgent(registry, agentA, sig);
    }

    function test_RegisterAgent_alreadyRegistered_differentCaller_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        // Different account but same agentWallet — still reverts (agent already has an owner)
        bytes memory bobSig = _buildRegSig(agentAWallet.privateKey, address(bobAccount), agentA);
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        bobAccount.registerAgent(registry, agentA, bobSig);
    }

    function test_RegisterAgent_multipleAgents_success() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.agentWalletOwner(agentB), address(aliceAccount));
    }

    // ─── HIGH-2: ERC-1271 smart contract agent wallets ────────────────────────

    /// @notice Register with a smart-contract agentWallet that returns valid ERC-1271 magic.
    function test_RegisterAgent_erc1271AgentWallet_succeeds() public {
        // Deploy an ERC-1271 wallet controlled by agentAWallet.addr
        MockERC1271Wallet smartAgent = new MockERC1271Wallet(agentA, true);

        // Build the sig as the EOA signer of the smart wallet
        bytes32 hash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(registry), address(aliceAccount), address(smartAgent))
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentAWallet.privateKey, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, address(smartAgent), sig);

        assertEq(registry.agentWalletOwner(address(smartAgent)), address(aliceAccount));
        assertTrue(registry.isRegisteredAgent(address(smartAgent)));
    }

    /// @notice Register with a smart-contract agentWallet returning wrong magic → InvalidAgentSignature.
    function test_RegisterAgent_erc1271AgentWallet_wrongMagic_reverts() public {
        // Deploy an ERC-1271 wallet that always returns the wrong magic value
        MockERC1271Wallet badAgent = new MockERC1271Wallet(agentA, false);

        bytes32 hash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(registry), address(aliceAccount), address(badAgent))
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentAWallet.privateKey, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        aliceAccount.registerAgent(registry, address(badAgent), sig);
    }

    // ─── deregisterAgent ─────────────────────────────────────────────────────

    function test_DeregisterAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(address(aliceAccount), agentA);
        aliceAccount.deregisterAgent(registry, agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(address(aliceAccount)), 0);
    }

    function test_DeregisterAgent_notOwner_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        // Bob tries to deregister Alice's agent — should revert
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        bobAccount.deregisterAgent(registry, agentA);
    }

    function test_DeregisterAgent_unregistered_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        aliceAccount.deregisterAgent(registry, agentA);
    }

    function test_DeregisterAgent_swapAndPop_preservesOtherAgents() public {
        Vm.Wallet memory agentCWallet = vm.createWallet("agentC");
        address agentC = agentCWallet.addr;

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);
        bytes memory sigC = _buildRegSig(agentCWallet.privateKey, address(aliceAccount), agentC);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentC, sigC);

        assertEq(registry.getAgentCount(address(aliceAccount)), 3);

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);
        assertEq(registry.agentWalletOwner(agentB), address(0));
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.agentWalletOwner(agentC), address(aliceAccount));
    }

    function test_DeregisterAgent_O1_multipleAgents() public {
        Vm.Wallet memory agentCWallet = vm.createWallet("agentC2");
        address agentC = agentCWallet.addr;

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);
        bytes memory sigC = _buildRegSig(agentCWallet.privateKey, address(aliceAccount), agentC);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentC, sigC);

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);
        assertEq(registry.agentWalletOwner(agentB), address(0));
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.agentWalletOwner(agentC), address(aliceAccount));

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        assertEq(registry.getAgentCount(address(aliceAccount)), 1);
        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.agentWalletOwner(agentC), address(aliceAccount));

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentC);
        assertEq(registry.getAgentCount(address(aliceAccount)), 0);
        assertEq(registry.agentWalletOwner(agentC), address(0));
    }

    // ─── isRegisteredAgent ────────────────────────────────────────────────────

    function test_IsRegisteredAgent() public {
        assertFalse(registry.isRegisteredAgent(agentA));

        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        assertTrue(registry.isRegisteredAgent(agentA));

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);

        assertFalse(registry.isRegisteredAgent(agentA));
    }

    // ─── balanceOf ────────────────────────────────────────────────────────────

    function test_BalanceOf() public {
        assertEq(registry.balanceOf(address(aliceAccount)), 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);

        assertEq(registry.balanceOf(address(aliceAccount)), 1);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        assertEq(registry.balanceOf(address(aliceAccount)), 2);

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentB);

        assertEq(registry.balanceOf(address(aliceAccount)), 0);
    }

    function test_BalanceOf_returnsActualCount() public {
        assertEq(registry.balanceOf(address(aliceAccount)), 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        assertEq(registry.balanceOf(address(aliceAccount)), 1);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);
        assertEq(registry.balanceOf(address(aliceAccount)), 2);

        // Bob registering does not affect alice's count
        assertEq(registry.balanceOf(address(bobAccount)), 0);
    }

    // ─── ownerOf ──────────────────────────────────────────────────────────────

    function test_OwnerOf_alwaysReverts_existing() public {
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(0);
    }

    // ─── revokeAgent ─────────────────────────────────────────────────────────

    function test_RevokeAgent_success() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(address(aliceAccount), agentA);
        aliceAccount.revokeAgent(registry, agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(address(aliceAccount)), 0);
        assertFalse(registry.isRegisteredAgent(agentA));
    }

    function test_RevokeAgent_notOwner_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);

        vm.prank(bob);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        bobAccount.revokeAgent(registry, agentA);
    }

    function test_RevokeAgent_unregistered_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        aliceAccount.revokeAgent(registry, agentA);
    }

    function test_RevokeAgent_twoAgents_preservesOther() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);

        vm.prank(alice);
        aliceAccount.revokeAgent(registry, agentA);

        assertEq(registry.getAgentCount(address(aliceAccount)), 1);
        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.agentWalletOwner(agentB), address(aliceAccount));
    }

    // ─── getHumanOwner ────────────────────────────────────────────────────────

    function test_GetHumanOwner() public {
        assertEq(registry.getHumanOwner(agentA), address(0));

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        assertEq(registry.getHumanOwner(agentA), address(aliceAccount));

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(bobAccount), agentB);
        vm.prank(bob);
        bobAccount.registerAgent(registry, agentB, sigB);
        assertEq(registry.getHumanOwner(agentB), address(bobAccount));

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        assertEq(registry.getHumanOwner(agentA), address(0));
    }

    // ─── getAgents ────────────────────────────────────────────────────────────

    function test_GetAgents() public {
        address[] memory empty = registry.getAgents(address(aliceAccount));
        assertEq(empty.length, 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        address[] memory agents = registry.getAgents(address(aliceAccount));
        assertEq(agents.length, 2);
        bool foundA = (agents[0] == agentA || agents[1] == agentA);
        bool foundB = (agents[0] == agentB || agents[1] == agentB);
        assertTrue(foundA);
        assertTrue(foundB);

        assertEq(registry.getAgents(address(bobAccount)).length, 0);
    }

    function test_GetAgents_afterRevoke() public {
        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);

        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        vm.prank(alice);
        aliceAccount.revokeAgent(registry, agentA);

        address[] memory agents = registry.getAgents(address(aliceAccount));
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
        vm.expectEmit(true, true, true, false);
        emit AAStarAirAccountBase.AgentWalletSet(1, agentA, address(registry));
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

        address noCodeAddr = makeAddr("noCodeAddr"); // EOA with no code

        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        account.setAgentWallet(1, agentA, noCodeAddr, "");
    }

    // ─── MEDIUM: self-registration forbidden ─────────────────────────────────

    function test_RegisterAgent_selfRegistration_reverts() public {
        // aliceAccount tries to register its own address as the agentWallet
        bytes memory sig = _buildRegSig(aliceWallet.privateKey, address(aliceAccount), address(aliceAccount));
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.SelfRegistrationForbidden.selector);
        aliceAccount.registerAgent(registry, address(aliceAccount), sig);
    }

    // ─── MEDIUM: ownerOf always reverts ──────────────────────────────────────

    function test_OwnerOf_alwaysReverts() public {
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(0);
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(type(uint256).max);
    }

    // ─── LOW-1: getAgentsPage pagination ─────────────────────────────────────

    function test_GetAgentsPage_emptyOwner() public view {
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 0, 10);
        assertEq(page.length, 0);
    }

    function test_GetAgentsPage_startBeyondEnd_returnsEmpty() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 5, 10);
        assertEq(page.length, 0);
    }

    function test_GetAgentsPage_countZero_returnsEmpty() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 0, 0);
        assertEq(page.length, 0);
    }

    function test_GetAgentsPage_overflowSafe() public {
        // count = type(uint256).max — must not overflow, just return the available elements.
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sig);
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 0, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], agentA);
    }

    function test_GetAgentsPage_slicedCorrectly() public {
        // Register 3 agents for aliceAccount
        Vm.Wallet memory w1 = vm.createWallet("w1");
        Vm.Wallet memory w2 = vm.createWallet("w2");
        Vm.Wallet memory w3 = vm.createWallet("w3");
        _registerAgentViaAccount(w1, aliceAccount, alice);
        _registerAgentViaAccount(w2, aliceAccount, alice);
        _registerAgentViaAccount(w3, aliceAccount, alice);

        address[] memory all = registry.getAgents(address(aliceAccount));
        assertEq(all.length, 3);

        // Page [1, 2) — one element at index 1
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], all[1]);

        // Page [0, 2) — first two
        address[] memory page2 = registry.getAgentsPage(address(aliceAccount), 0, 2);
        assertEq(page2.length, 2);
        assertEq(page2[0], all[0]);
        assertEq(page2[1], all[1]);

        // Page [2, 100) — only one element remains
        address[] memory page3 = registry.getAgentsPage(address(aliceAccount), 2, 100);
        assertEq(page3.length, 1);
        assertEq(page3[0], all[2]);
    }

    function _registerAgentViaAccount(Vm.Wallet memory w, MockAirAccount account, address accountOwner) internal {
        bytes32 regHash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(registry), address(account), w.addr)
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, regHash);
        vm.prank(accountOwner);
        account.registerAgent(registry, w.addr, abi.encodePacked(r, s, v));
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
