// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title AAStarAirAccountFactoryV7AgentAccountTest
/// @notice Tests for createAgentAccount() and getAgentAddress() on AAStarAirAccountFactoryV7.
///         An agent account has:
///           - owner = agentKey (the AI agent's signing EOA)
///           - guardian1 = msg.sender (the human who creates the account, auto-accepted)
///           - guardian2 = provided separately, must sign acceptance message
///           - salt = uint256(keccak256(abi.encodePacked(humanOwner, agentId)))
contract AAStarAirAccountFactoryV7AgentAccountTest is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public communityGuardian;

    // Human owner wallet — the caller who creates agent accounts
    Vm.Wallet public humanWallet;
    // Agent key wallet — the AI agent's signing key, becomes the account owner
    Vm.Wallet public agentWallet;
    // Guardian2 wallet — the human's backup/trusted person
    Vm.Wallet public guardian2Wallet;

    bytes32 constant AGENT_ID_1 = keccak256("my-agent-v1");
    bytes32 constant AGENT_ID_2 = keccak256("my-agent-v2");
    uint256 constant DAILY_LIMIT = 0.5 ether;

    function setUp() public {
        entryPoint = makeAddr("entryPoint");
        communityGuardian = makeAddr("communityGuardian");

        humanWallet    = vm.createWallet("human");
        agentWallet    = vm.createWallet("agent");
        guardian2Wallet = vm.createWallet("guardian2");

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        factory = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(0), address(0)
        );
    }

    // ─── Helper: build guardian2 acceptance signature ──────────────────────

    /// @dev Computes the guardian2 acceptance signature for createAgentAccount.
    ///      The acceptance hash binds: "ACCEPT_GUARDIAN" + chainId + factory + agentKey + salt
    ///      where salt = uint256(keccak256(abi.encodePacked(humanOwner, agentId)))
    function _guardian2Sig(
        Vm.Wallet memory g2,
        address humanOwner,
        address agentKey,
        bytes32 agentId
    ) internal view returns (bytes memory) {
        uint256 salt = uint256(keccak256(abi.encodePacked(humanOwner, agentId)));
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(factory), agentKey, salt)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g2.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── Happy path ────────────────────────────────────────────────────────

    /// @notice Full happy path: deploy agent account, verify owner and guardians.
    function test_CreateAgentAccount_success() public {
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        address account = factory.createAgentAccount(
            agentWallet.addr,
            AGENT_ID_1,
            guardian2Wallet.addr,
            sig2,
            DAILY_LIMIT
        );

        assertTrue(account.code.length > 0, "Account not deployed");

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        // Owner must be the agent key, not the human
        assertEq(acc.owner(), agentWallet.addr, "Owner must be agentKey");

        // guardian1 = human (msg.sender), guardian2 = guardian2Wallet, guardian3 = communityGuardian
        assertEq(acc.guardianCount(), 3, "Should have 3 guardians");
        assertEq(acc.guardians(0), humanWallet.addr,     "guardian1 must be human");
        assertEq(acc.guardians(1), guardian2Wallet.addr, "guardian2 must be guardian2Wallet");
        assertEq(acc.guardians(2), communityGuardian,    "guardian3 must be communityGuardian");

        // Guard should be configured with the specified daily limit
        AAStarGlobalGuard g = acc.guard();
        assertEq(g.dailyLimit(), DAILY_LIMIT, "Daily limit mismatch");
        assertEq(g.account(), account, "Guard account mismatch");
        assertTrue(g.approvedAlgorithms(0x02), "ECDSA must be approved");
        assertTrue(g.approvedAlgorithms(0x01), "BLS must be approved");
        assertTrue(g.approvedAlgorithms(0x03), "P256 must be approved");
    }

    // ─── Idempotency ───────────────────────────────────────────────────────

    /// @notice Calling createAgentAccount twice with the same params returns the same address.
    function test_CreateAgentAccount_idempotent() public {
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );

        // Second call with same params — sig must be re-provided but result is deterministic
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );

        assertEq(a1, a2, "Second call must return same address");
    }

    // ─── Signature validation ──────────────────────────────────────────────

    /// @notice Wrong guardian2 signature must revert with GuardianDidNotAccept.
    function test_CreateAgentAccount_wrongGuardian2Sig_reverts() public {
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, badSig, DAILY_LIMIT
        );
    }

    /// @notice Acceptance sig signed for wrong agentKey must be rejected.
    function test_CreateAgentAccount_sigForWrongAgentKey_reverts() public {
        Vm.Wallet memory anotherAgent = vm.createWallet("anotherAgent");
        // Sign for anotherAgent, but pass agentWallet as the agentKey
        bytes memory wrongSig = _guardian2Sig(guardian2Wallet, humanWallet.addr, anotherAgent.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, wrongSig, DAILY_LIMIT
        );
    }

    // ─── Require checks ────────────────────────────────────────────────────

    /// @notice Zero agentKey must revert.
    function test_CreateAgentAccount_zeroAgentKey_reverts() public {
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, address(0), AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key required");
        factory.createAgentAccount(
            address(0), AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );
    }

    /// @notice Zero guardian2 must revert.
    function test_CreateAgentAccount_zeroGuardian2_reverts() public {
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian2 required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, address(0), sig2, DAILY_LIMIT
        );
    }

    /// @notice Zero daily limit must revert.
    function test_CreateAgentAccount_zeroDailyLimit_reverts() public {
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Daily limit required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, 0
        );
    }

    /// @notice Caller (human) cannot also be guardian2.
    function test_CreateAgentAccount_callerEqualsGuardian2_reverts() public {
        // Human tries to be guardian2 as well
        bytes memory sig2 = _guardian2Sig(humanWallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Caller cannot be guardian2");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, humanWallet.addr, sig2, DAILY_LIMIT
        );
    }

    /// @notice agentKey cannot equal guardian2.
    function test_CreateAgentAccount_agentKeyEqualsGuardian2_reverts() public {
        // agentKey == guardian2Wallet.addr — agent's key is also the backup guardian
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, guardian2Wallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key cannot be guardian2");
        factory.createAgentAccount(
            guardian2Wallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );
    }

    // ─── Address prediction ────────────────────────────────────────────────

    /// @notice getAgentAddress must match the actual deployed address.
    function test_GetAgentAddress_matchesDeployed() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        vm.prank(humanWallet.addr);
        address deployed = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );

        assertEq(predicted, deployed, "Predicted address must match deployed");
    }

    // ─── Event emission ────────────────────────────────────────────────────

    /// @notice AgentAccountCreated event must be emitted with correct indexed fields.
    function test_AgentAccountCreated_event() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        vm.expectEmit(true, true, true, true);
        emit AAStarAirAccountFactoryV7.AgentAccountCreated(
            predicted,
            agentWallet.addr,
            humanWallet.addr,
            AGENT_ID_1
        );

        vm.prank(humanWallet.addr);
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, DAILY_LIMIT
        );
    }

    // ─── Determinism: different agentIds produce different addresses ───────

    /// @notice Same human + different agentId → different account addresses.
    function test_AgentAccount_differentAgentIds_differentAddresses() public {
        bytes memory sig2a = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, DAILY_LIMIT
        );

        bytes memory sig2b = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_2);
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_2, guardian2Wallet.addr, sig2b, DAILY_LIMIT
        );

        assertTrue(a1 != a2, "Different agentIds must produce different addresses");
    }

    /// @notice Same agentId but different humanOwner → different account addresses.
    function test_AgentAccount_differentHumans_differentAddresses() public {
        Vm.Wallet memory anotherHuman = vm.createWallet("anotherHuman");

        bytes memory sig2a = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, DAILY_LIMIT
        );

        bytes memory sig2b = _guardian2Sig(guardian2Wallet, anotherHuman.addr, agentWallet.addr, AGENT_ID_1);
        vm.prank(anotherHuman.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2b, DAILY_LIMIT
        );

        assertTrue(a1 != a2, "Different humans must produce different addresses for same agentId");
    }

    // ─── Note: agentKey == msg.sender is NOT allowed due to owner!=guardian invariant ──

    /// @notice agentKey == msg.sender will fail at initialize() time because AirAccount
    ///         enforces that no guardian can equal the owner (InvalidGuardian error).
    ///         guardian1 = msg.sender and owner = agentKey — if they're the same address,
    ///         the account initialization reverts at line 344 of AAStarAirAccountBase.sol.
    ///         This is a security feature: the owner key cannot also be a guardian (prevents
    ///         a compromised owner key from short-circuiting 2-of-3 social recovery).
    function test_CreateAgentAccount_agentKeyEqualsCaller_reverts() public {
        // Human uses their own address as the agent signing key — will be rejected
        // because agentKey becomes the owner, and msg.sender (== agentKey) becomes guardian1,
        // violating the owner != guardian invariant in AAStarAirAccountBase.
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, humanWallet.addr, AGENT_ID_1);

        vm.prank(humanWallet.addr);
        // Revert due to InvalidGuardian() in account initialize() — owner == guardian1
        vm.expectRevert();
        factory.createAgentAccount(
            humanWallet.addr,   // agentKey == msg.sender — violates owner != guardian invariant
            AGENT_ID_1,
            guardian2Wallet.addr,
            sig2,
            DAILY_LIMIT
        );
    }
}
