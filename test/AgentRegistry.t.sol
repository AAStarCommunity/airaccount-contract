// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {IAirAccountAgent} from "../src/interfaces/IAirAccountAgent.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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
// "airaccount." prefixed string. Wraps registry calls so msg.sender = address(this).

/// @dev v0.17.2: AgentRegistry's H-2 check requires msg.sender to be an EIP-1167 clone
///      of the bound implementation. So this mock is used as the IMPLEMENTATION; per-test
///      "accounts" are real Clones.clone(impl) instances whose extcodehash matches the
///      hash AgentRegistry expects. The constructor is replaced with an initialize() since
///      clones don't run constructors.
contract MockAirAccount {
    address public owner;
    bool internal _initialized;

    function initialize(address _owner) external {
        require(!_initialized, "Already init");
        _initialized = true;
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NotOwner");
        _;
    }

    /// @dev Retained for backward compat with tests that check accountId; H-2 no longer reads it.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.17.2";
    }

    function registerAgent(AgentRegistry reg, address agentWallet, bytes calldata sig) external onlyOwner {
        reg.registerAgent(agentWallet, sig);
    }
    function deregisterAgent(AgentRegistry reg, address agentWallet) external onlyOwner {
        reg.deregisterAgent(agentWallet);
    }
    function revokeAgent(AgentRegistry reg, address agentWallet) external onlyOwner {
        reg.revokeAgent(agentWallet);
    }
}

// ─── MockERC1271Wallet ─────────────────────────────────────────────────────────

contract MockERC1271Wallet {
    address public signer;
    bool public returnValid;

    constructor(address _signer, bool _returnValid) {
        signer = _signer;
        returnValid = _returnValid;
    }

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

    Vm.Wallet public aliceWallet;
    Vm.Wallet public bobWallet;
    Vm.Wallet public agentAWallet;
    Vm.Wallet public agentBWallet;

    // MockAirAccount wrappers — all registerAgent calls go through these,
    // so msg.sender to the registry is address(aliceAccount) / address(bobAccount).
    MockAirAccount public aliceAccount;
    MockAirAccount public bobAccount;

    address public alice;
    address public bob;
    address public agentA;
    address public agentB;

    /// @dev Implementation template — clones of this match AgentRegistry's H-2 extcodehash check.
    MockAirAccount internal mockImpl;

    function setUp() public {
        mockImpl = new MockAirAccount();
        registry = new AgentRegistry();
        // v0.17.2 Codex P1 round 2: AgentRegistry uses factory-provenance whitelist.
        // The test contract impersonates the factory: bind it, then mark each test "account" valid.
        registry.bindFactory(address(this));

        aliceWallet  = vm.createWallet("alice");
        bobWallet    = vm.createWallet("bob");
        agentAWallet = vm.createWallet("agentA");
        agentBWallet = vm.createWallet("agentB");

        alice  = aliceWallet.addr;
        bob    = bobWallet.addr;
        agentA = agentAWallet.addr;
        agentB = agentBWallet.addr;

        // Real EIP-1167 clones to look-and-feel like factory output (extcodehash not relied on
        // anymore, but kept for behavioural realism).
        aliceAccount = MockAirAccount(Clones.clone(address(mockImpl)));
        aliceAccount.initialize(alice);
        registry.markValid(address(aliceAccount));
        bobAccount = MockAirAccount(Clones.clone(address(mockImpl)));
        bobAccount.initialize(bob);
        registry.markValid(address(bobAccount));
    }

    /// @dev Create a new clone owned by `_owner` for tests that need extra mock accounts.
    ///      Also marks the clone valid in the registry so it can call registerAgent.
    function _newMockClone(address _owner) internal returns (MockAirAccount) {
        MockAirAccount c = MockAirAccount(Clones.clone(address(mockImpl)));
        c.initialize(_owner);
        registry.markValid(address(c));
        return c;
    }

    // ─── Signature helpers ────────────────────────────────────────────────────

    /// @dev Build the REGISTER_AGENT sig where humanOwner is the AirAccount address (msg.sender).
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

    /// @dev Register agentWallet for aliceAccount (alice owns aliceAccount).
    function _aliceRegister(uint256 agentPrivKey, address agentWallet) internal {
        bytes memory sig = _buildRegSig(agentPrivKey, address(aliceAccount), agentWallet);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentWallet, sig);
    }

    /// @dev Register agentWallet for bobAccount (bob owns bobAccount).
    function _bobRegister(uint256 agentPrivKey, address agentWallet) internal {
        bytes memory sig = _buildRegSig(agentPrivKey, address(bobAccount), agentWallet);
        vm.prank(bob);
        bobAccount.registerAgent(registry, agentWallet, sig);
    }

    /// @dev Register wallet w for a specific MockAirAccount (accOwner is the EOA owner of acc).
    function _registerFor(Vm.Wallet memory w, MockAirAccount acc, address accOwner) internal {
        bytes memory sig = _buildRegSig(w.privateKey, address(acc), w.addr);
        vm.prank(accOwner);
        acc.registerAgent(registry, w.addr, sig);
    }

    // ─── HIGH-1: EOA caller reverts ───────────────────────────────────────────

    function test_RegisterAgent_eoaCaller_reverts() public {
        bytes memory sig = _buildRegSig(agentAWallet.privateKey, alice, agentA);
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.CallerNotAirAccount.selector);
        registry.registerAgent(agentA, sig);
    }

    function test_BindFactory_nonDeployer_reverts() public {
        AgentRegistry fresh = new AgentRegistry();
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotDeployer.selector);
        fresh.bindFactory(address(this));
    }

    function test_RegisterAgent_contractWithoutAccountId_reverts() public {
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
        _aliceRegister(agentAWallet.privateKey, agentA);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertTrue(registry.isRegisteredAgent(agentA));
    }

    function test_RegisterAgent_invalidSig_reverts() public {
        // Bob's key signs but agentA is claimed — wrong signer
        bytes memory wrongSig = _buildRegSig(bobWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        aliceAccount.registerAgent(registry, agentA, wrongSig);
    }

    function test_RegisterAgent_frontRunPrevented() public {
        // Attacker Eve tries to register agentA but doesn't control agentA's key
        address eve = makeAddr("eve");
        MockAirAccount eveAccount = _newMockClone(eve);
        Vm.Wallet memory eveWallet = vm.createWallet("eveKey");

        bytes memory attackSig = _buildRegSig(eveWallet.privateKey, address(eveAccount), agentA);
        vm.prank(eve);
        vm.expectRevert(AgentRegistry.InvalidAgentSignature.selector);
        eveAccount.registerAgent(registry, agentA, attackSig);

        // Alice can still register legitimately
        _aliceRegister(agentAWallet.privateKey, agentA);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
    }

    function test_RegisterAgent_zeroAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidAddress.selector);
        aliceAccount.registerAgent(registry, address(0), "");
    }

    function test_RegisterAgent_alreadyRegistered_reverts() public {
        _aliceRegister(agentAWallet.privateKey, agentA);

        bytes memory sig2 = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        aliceAccount.registerAgent(registry, agentA, sig2);
    }

    function test_RegisterAgent_alreadyRegistered_differentCaller_reverts() public {
        _aliceRegister(agentAWallet.privateKey, agentA);

        // Different AirAccount, same agentWallet — still reverts
        bytes memory bobSig = _buildRegSig(agentAWallet.privateKey, address(bobAccount), agentA);
        vm.prank(bob);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        bobAccount.registerAgent(registry, agentA, bobSig);
    }

    function test_RegisterAgent_multipleAgents_success() public {
        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.agentWalletOwner(agentB), address(aliceAccount));
    }

    // ─── deregisterAgent ─────────────────────────────────────────────────────

    function test_DeregisterAgent_success() public {
        _aliceRegister(agentAWallet.privateKey, agentA);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.AgentDeregistered(address(aliceAccount), agentA);
        aliceAccount.deregisterAgent(registry, agentA);

        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.getAgentCount(address(aliceAccount)), 0);
    }

    function test_DeregisterAgent_notOwner_reverts() public {
        _aliceRegister(agentAWallet.privateKey, agentA);

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

        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);
        _aliceRegister(agentCWallet.privateKey, agentC);

        assertEq(registry.getAgentCount(address(aliceAccount)), 3);

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);
        assertEq(registry.agentWalletOwner(agentB), address(0));
        assertEq(registry.agentWalletOwner(agentA), address(aliceAccount));
        assertEq(registry.agentWalletOwner(agentC), address(aliceAccount));
    }

    function test_DeregisterAgent_O1_multipleAgents() public {
        // Verify O(1) removal correctness with 3+ agents
        Vm.Wallet memory agentCWallet = vm.createWallet("agentC2");
        address agentC = agentCWallet.addr;

        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);
        _aliceRegister(agentCWallet.privateKey, agentC);

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

        _aliceRegister(agentAWallet.privateKey, agentA);
        assertTrue(registry.isRegisteredAgent(agentA));

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        assertFalse(registry.isRegisteredAgent(agentA));
    }

    // ─── balanceOf ────────────────────────────────────────────────────────────

    function test_BalanceOf() public {
        // Before registration: 0
        assertEq(registry.balanceOf(address(aliceAccount)), 0);

        bytes memory sigA = _buildRegSig(agentAWallet.privateKey, address(aliceAccount), agentA);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentA, sigA);

        // After first registration: 1
        assertEq(registry.balanceOf(address(aliceAccount)), 1);

        bytes memory sigB = _buildRegSig(agentBWallet.privateKey, address(aliceAccount), agentB);
        vm.prank(alice);
        aliceAccount.registerAgent(registry, agentB, sigB);

        // After second registration: 2 (actual count, not capped at 1)
        assertEq(registry.balanceOf(address(aliceAccount)), 2);

        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentB);

        // After all deregistered: 0
        assertEq(registry.balanceOf(address(aliceAccount)), 0);
    }

    function test_BalanceOf_returnsActualCount() public {
        assertEq(registry.balanceOf(address(aliceAccount)), 0);

        _aliceRegister(agentAWallet.privateKey, agentA);
        assertEq(registry.balanceOf(address(aliceAccount)), 1);

        _aliceRegister(agentBWallet.privateKey, agentB);
        assertEq(registry.balanceOf(address(aliceAccount)), 2);

        assertEq(registry.balanceOf(address(bobAccount)), 0);
    }

    // ─── ownerOf ──────────────────────────────────────────────────────────────

    function test_OwnerOf_alwaysReverts_existing() public {
        // ownerOf is not supported — always reverts with NotSupported
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(0);
    }

    // ─── revokeAgent ─────────────────────────────────────────────────────────

    function test_RevokeAgent_success() public {
        _aliceRegister(agentAWallet.privateKey, agentA);
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
        _aliceRegister(agentAWallet.privateKey, agentA);

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
        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);

        assertEq(registry.getAgentCount(address(aliceAccount)), 2);

        vm.prank(alice);
        aliceAccount.revokeAgent(registry, agentA);

        assertEq(registry.getAgentCount(address(aliceAccount)), 1);
        assertEq(registry.agentWalletOwner(agentA), address(0));
        assertEq(registry.agentWalletOwner(agentB), address(aliceAccount));
    }

    // ─── getHumanOwner ────────────────────────────────────────────────────────

    function test_GetHumanOwner() public {
        // Unregistered returns address(0)
        assertEq(registry.getHumanOwner(agentA), address(0));

        _aliceRegister(agentAWallet.privateKey, agentA);
        assertEq(registry.getHumanOwner(agentA), address(aliceAccount));

        _bobRegister(agentBWallet.privateKey, agentB);
        assertEq(registry.getHumanOwner(agentB), address(bobAccount));

        // After deregistration returns address(0)
        vm.prank(alice);
        aliceAccount.deregisterAgent(registry, agentA);
        assertEq(registry.getHumanOwner(agentA), address(0));
    }

    // ─── getAgents ────────────────────────────────────────────────────────────

    function test_GetAgents() public {
        // Empty before registration
        address[] memory empty = registry.getAgents(address(aliceAccount));
        assertEq(empty.length, 0);

        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);

        address[] memory agents = registry.getAgents(address(aliceAccount));
        assertEq(agents.length, 2);
        // Both agentA and agentB are present (order may vary after swap-and-pop)
        bool foundA = (agents[0] == agentA || agents[1] == agentA);
        bool foundB = (agents[0] == agentB || agents[1] == agentB);
        assertTrue(foundA);
        assertTrue(foundB);

        // Bob's list is unaffected
        assertEq(registry.getAgents(address(bobAccount)).length, 0);
    }

    function test_GetAgents_afterRevoke() public {
        _aliceRegister(agentAWallet.privateKey, agentA);
        _aliceRegister(agentBWallet.privateKey, agentB);

        vm.prank(alice);
        aliceAccount.revokeAgent(registry, agentA);

        address[] memory agents = registry.getAgents(address(aliceAccount));
        assertEq(agents.length, 1);
        assertEq(agents[0], agentB);
    }

    // ─── MEDIUM: self-registration forbidden ─────────────────────────────────

    function test_RegisterAgent_selfRegistration_reverts() public {
        // aliceAccount tries to register its own address as an agent — must revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.SelfRegistrationForbidden.selector);
        aliceAccount.registerAgent(registry, address(aliceAccount), "");
    }

    // ─── MEDIUM: ownerOf always reverts ──────────────────────────────────────

    function test_OwnerOf_alwaysReverts() public {
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(0);
        vm.expectRevert(AgentRegistry.NotSupported.selector);
        registry.ownerOf(type(uint256).max);
    }

    // ─── LOW: getAgentsPage pagination ───────────────────────────────────────

    function test_GetAgentsPage_emptyOwner() public view {
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 0, 10);
        assertEq(page.length, 0);
    }

    function test_GetAgentsPage_startBeyondEnd_returnsEmpty() public {
        _aliceRegister(agentAWallet.privateKey, agentA);
        address[] memory page = registry.getAgentsPage(address(aliceAccount), 5, 10);
        assertEq(page.length, 0);
    }

    function test_GetAgentsPage_slicedCorrectly() public {
        Vm.Wallet memory w1 = vm.createWallet("w1");
        Vm.Wallet memory w2 = vm.createWallet("w2");
        Vm.Wallet memory w3 = vm.createWallet("w3");
        _registerFor(w1, aliceAccount, alice);
        _registerFor(w2, aliceAccount, alice);
        _registerFor(w3, aliceAccount, alice);

        address[] memory all = registry.getAgents(address(aliceAccount));
        assertEq(all.length, 3);

        address[] memory page = registry.getAgentsPage(address(aliceAccount), 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], all[1]);

        address[] memory page2 = registry.getAgentsPage(address(aliceAccount), 0, 2);
        assertEq(page2.length, 2);
        assertEq(page2[0], all[0]);
        assertEq(page2[1], all[1]);

        address[] memory page3 = registry.getAgentsPage(address(aliceAccount), 2, 100);
        assertEq(page3.length, 1);
        assertEq(page3[0], all[2]);
    }

    // ─── setAgentWallet integration (account → registry) ─────────────────────

    /// @dev Helper: deploy a V7 impl + an AgentRegistry + a V7 clone + bind & markValid.
    ///      Returns (account-clone, registry).
    function _setupV7CloneAndRegistry(address ownerAddr) internal returns (AAStarAirAccountV7, AgentRegistry) {
        AAStarAirAccountV7 v7Impl = new AAStarAirAccountV7(address(0));
        AgentRegistry v7Registry = new AgentRegistry();
        // Bind THIS test contract as the registry's "factory" so we can call markValid below.
        v7Registry.bindFactory(address(this));
        AAStarAirAccountV7 clone = AAStarAirAccountV7(payable(Clones.clone(address(v7Impl))));
        MockEntryPoint ep = new MockEntryPoint();
        uint8[] memory algs = new uint8[](0);
        clone.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
                guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
                tier1Limit: 0,
                tier2Limit: 0
            }), address(0), bytes32(0), bytes32(0)
        );
        v7Registry.markValid(address(clone));
        return (clone, v7Registry);
    }

    function test_SetAgentWalletCallsRegistry() public {
        address ownerAddr = makeAddr("accountOwner");
        (AAStarAirAccountV7 account, AgentRegistry v7Registry) = _setupV7CloneAndRegistry(ownerAddr);

        bytes memory sig = _buildRegSig_(agentAWallet.privateKey, address(account), agentA, address(v7Registry));

        vm.prank(ownerAddr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(1, agentA, address(v7Registry));
        IAirAccountAgent(address(account)).setAgentWallet(1, agentA, address(v7Registry), sig);

        assertEq(v7Registry.agentWalletOwner(agentA), address(account));
        assertTrue(v7Registry.isRegisteredAgent(agentA));
    }

    /// @dev Variant of _buildRegSig that uses a specific registry address (not the global `registry`).
    function _buildRegSig_(uint256 agentPrivKey, address humanOwner, address agentWallet, address registryAddr)
        internal view returns (bytes memory)
    {
        bytes32 regHash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, registryAddr, humanOwner, agentWallet)
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPrivKey, regHash);
        return abi.encodePacked(r, s, v);
    }

    function test_SetAgentWalletCallsRegistry_notOwner_reverts() public {
        MockEntryPoint ep = new MockEntryPoint();
        AAStarAirAccountV7 account = new AAStarAirAccountV7(address(0));
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
                guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
                tier1Limit: 0,
                tier2Limit: 0
            }), address(0), bytes32(0), bytes32(0)
        );

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        IAirAccountAgent(address(account)).setAgentWallet(1, agentA, address(registry), "");
    }

    function test_SetAgentWalletCallsRegistry_failingRegistry_reverts() public {
        MockEntryPoint ep = new MockEntryPoint();
        AAStarAirAccountV7 account = new AAStarAirAccountV7(address(0));
        address ownerAddr = makeAddr("accountOwner");

        uint8[] memory algs = new uint8[](0);
        account.initialize(
            address(ep),
            ownerAddr,
            AAStarAirAccountBase.InitConfig({
                guardians: [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")],
                guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
                guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
                dailyLimit: 0,
                approvedAlgIds: algs,
                minDailyLimit: 0,
                initialTokens: new address[](0),
                initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
                tier1Limit: 0,
                tier2Limit: 0
            }), address(0), bytes32(0), bytes32(0)
        );

        address noCodeAddr = makeAddr("noCodeAddr");

        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        IAirAccountAgent(address(account)).setAgentWallet(1, agentA, noCodeAddr, "");
    }

    function test_SetAgentWalletCallsRegistry_duplicateRegistration_reverts() public {
        address ownerAddr = makeAddr("accountOwner");
        (AAStarAirAccountV7 account, AgentRegistry v7Registry) = _setupV7CloneAndRegistry(ownerAddr);

        bytes memory sig = _buildRegSig_(agentAWallet.privateKey, address(account), agentA, address(v7Registry));

        vm.prank(ownerAddr);
        IAirAccountAgent(address(account)).setAgentWallet(1, agentA, address(v7Registry), sig);

        vm.prank(ownerAddr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        IAirAccountAgent(address(account)).setAgentWallet(2, agentA, address(v7Registry), sig);
    }
}
