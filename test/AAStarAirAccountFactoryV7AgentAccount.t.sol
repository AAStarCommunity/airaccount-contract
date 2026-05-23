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
    ///      The acceptance hash binds:
    ///        "ACCEPT_AGENT_GUARDIAN" + chainId + factory + agentKey + humanOwner + agentId + deadline
    ///      The distinct domain, explicit humanOwner + agentId, and deadline prevent signature reuse
    ///      across createAccountWithDefaults and after expiry.
    function _guardian2Sig(
        Vm.Wallet memory g2,
        address humanOwner,
        address agentKey,
        bytes32 agentId,
        uint48 deadline
    ) internal view returns (bytes memory) {
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_AGENT_GUARDIAN", block.chainid, address(factory), agentKey, humanOwner, agentId, deadline)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g2.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Computes the agentKey consent signature for createAgentAccount (MEDIUM-3 fix).
    ///      The acceptance hash binds:
    ///        "ACCEPT_AGENT_KEY" + chainId + factory + agentKey + humanOwner + agentId + deadline
    ///      Proves the KMS/agent key holder explicitly authorized this account creation.
    function _agentKeySig(
        uint256 agentPrivKey,
        address agentKey,
        address humanOwner,
        bytes32 agentId,
        uint48 deadline
    ) internal view returns (bytes memory) {
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_AGENT_KEY", block.chainid, address(factory), agentKey, humanOwner, agentId, deadline)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPrivKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Computes a guardian acceptance signature for createAccountWithDefaults.
    ///      Uses the OLD domain "ACCEPT_GUARDIAN" + chainId + factory + owner + uint256_salt.
    ///      Used in the front-run test to prove the two domains cannot collide.
    function _defaultGuardianSig(
        Vm.Wallet memory g,
        address owner,
        uint256 salt
    ) internal view returns (bytes memory) {
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(factory), owner, salt)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── Happy path ────────────────────────────────────────────────────────

    /// @notice Full happy path: deploy agent account, verify owner and guardians.
    function test_CreateAgentAccount_success() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address account = factory.createAgentAccount(
            agentWallet.addr,
            AGENT_ID_1,
            guardian2Wallet.addr,
            sig2,
            agentSig,
            deadline,
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
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );

        // Second call with same params — sig must be re-provided but result is deterministic
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );

        assertEq(a1, a2, "Second call must return same address");
    }

    // ─── Signature validation ──────────────────────────────────────────────

    /// @notice Wrong guardian2 signature must revert with GuardianDidNotAccept.
    function test_CreateAgentAccount_wrongGuardian2Sig_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, badSig, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice Acceptance sig signed for wrong agentKey must be rejected.
    function test_CreateAgentAccount_sigForWrongAgentKey_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        Vm.Wallet memory anotherAgent = vm.createWallet("anotherAgent");
        // Sign for anotherAgent, but pass agentWallet as the agentKey
        bytes memory wrongSig = _guardian2Sig(guardian2Wallet, humanWallet.addr, anotherAgent.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, wrongSig, agentSig, deadline, DAILY_LIMIT
        );
    }

    // ─── Require checks ────────────────────────────────────────────────────

    /// @notice Zero agentKey must revert.
    function test_CreateAgentAccount_zeroAgentKey_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, address(0), AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key required");
        factory.createAgentAccount(
            address(0), AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice Zero guardian2 must revert.
    function test_CreateAgentAccount_zeroGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian2 required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, address(0), sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice Zero daily limit must revert.
    function test_CreateAgentAccount_zeroDailyLimit_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Daily limit required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, 0
        );
    }

    /// @notice Caller (human) cannot also be guardian2.
    function test_CreateAgentAccount_callerEqualsGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        // Human tries to be guardian2 as well
        bytes memory sig2 = _guardian2Sig(humanWallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Caller cannot be guardian2");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, humanWallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice agentKey cannot equal guardian2.
    function test_CreateAgentAccount_agentKeyEqualsGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        // agentKey == guardian2Wallet.addr — agent's key is also the backup guardian
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, guardian2Wallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(guardian2Wallet.privateKey, guardian2Wallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key cannot be guardian2");
        factory.createAgentAccount(
            guardian2Wallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    // ─── Address prediction ────────────────────────────────────────────────

    /// @notice getAgentAddress must match the actual deployed address.
    function test_GetAgentAddress_matchesDeployed() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address deployed = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );

        assertEq(predicted, deployed, "Predicted address must match deployed");
    }

    // ─── Event emission ────────────────────────────────────────────────────

    /// @notice AgentAccountCreated event must be emitted with correct indexed and non-indexed fields.
    function test_AgentAccountCreated_event() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.expectEmit(true, true, true, true);
        emit AAStarAirAccountFactoryV7.AgentAccountCreated(
            predicted,
            agentWallet.addr,
            humanWallet.addr,
            AGENT_ID_1,
            guardian2Wallet.addr,
            DAILY_LIMIT
        );

        vm.prank(humanWallet.addr);
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    // ─── Determinism: different agentIds produce different addresses ───────

    /// @notice Same human + different agentId → different account addresses.
    function test_AgentAccount_differentAgentIds_differentAddresses() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2a = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSigA = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, agentSigA, deadline, DAILY_LIMIT
        );

        bytes memory sig2b = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_2, deadline);
        bytes memory agentSigB = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_2, deadline);
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_2, guardian2Wallet.addr, sig2b, agentSigB, deadline, DAILY_LIMIT
        );

        assertTrue(a1 != a2, "Different agentIds must produce different addresses");
    }

    /// @notice Same agentId but different humanOwner → different account addresses.
    function test_AgentAccount_differentHumans_differentAddresses() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        Vm.Wallet memory anotherHuman = vm.createWallet("anotherHuman");

        bytes memory sig2a = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSigA = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, agentSigA, deadline, DAILY_LIMIT
        );

        bytes memory sig2b = _guardian2Sig(guardian2Wallet, anotherHuman.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSigB = _agentKeySig(agentWallet.privateKey, agentWallet.addr, anotherHuman.addr, AGENT_ID_1, deadline);
        vm.prank(anotherHuman.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2b, agentSigB, deadline, DAILY_LIMIT
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
        uint48 deadline = uint48(block.timestamp + 1 days);
        // Human uses their own address as the agent signing key — will be rejected
        // because agentKey becomes the owner, and msg.sender (== agentKey) becomes guardian1,
        // violating the owner != guardian invariant in AAStarAirAccountBase.
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(humanWallet.privateKey, humanWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        // Revert due to InvalidGuardian() in account initialize() — owner == guardian1
        vm.expectRevert();
        factory.createAgentAccount(
            humanWallet.addr,   // agentKey == msg.sender — violates owner != guardian invariant
            AGENT_ID_1,
            guardian2Wallet.addr,
            sig2,
            agentSig,
            deadline,
            DAILY_LIMIT
        );
    }

    // ─── Front-run resistance: cross-namespace salt collision ──────────────

    /// @notice An attacker who intercepts a createAgentAccount mempool transaction CANNOT
    ///         pre-deploy the same address via createAccountWithDefaults.
    ///
    ///         Security proof:
    ///         - createAgentAccount clone salt = keccak256("AASTAR_AGENT_V1" || agentKey || humanOwner || agentId)
    ///         - createAccountWithDefaults clone salt = keccak256(owner || uint256_salt)
    ///         These two salt functions NEVER produce the same bytes32 value because the
    ///         "AASTAR_AGENT_V1" prefix cannot appear in the unprefixed (owner, salt) encoding.
    ///
    ///         Additionally, guardian2Sig cannot be reused across paths because:
    ///         - createAgentAccount domain: "ACCEPT_AGENT_GUARDIAN" || chainId || factory || agentKey || humanOwner || agentId
    ///         - createAccountWithDefaults domain: "ACCEPT_GUARDIAN" || chainId || factory || owner || uint256_salt
    ///         Different string prefixes produce different hashes even if all numeric fields overlap.
    function test_CreateAgentAccount_cannotBeFrontRunByCreateAccountWithDefaults() public {
        // Attacker observes: createAgentAccount(agentKey, agentId, guardian2, guardian2Sig, dailyLimit)
        // called by humanWallet.addr.

        // Step 1: Compute what createAgentAccount would use for its clone salt.
        address agentAddr = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        // Step 2: Compute the derived salt that the OLD code used (before the fix):
        //         uint256 salt = keccak256(msg.sender || agentId). An attacker who knows
        //         humanOwner and agentId can compute this.
        uint256 derivedSalt = uint256(keccak256(abi.encodePacked(humanWallet.addr, AGENT_ID_1)));

        // Step 3: Attacker attempts to use createAccountWithDefaults with agentKey as owner
        //         and derivedSalt, providing old-style guardian2Sig (ACCEPT_GUARDIAN domain).
        //         With the fix, this targets a DIFFERENT clone salt and therefore a
        //         DIFFERENT address, so it cannot occupy the agent account's address.
        Vm.Wallet memory attackerWallet = vm.createWallet("attacker");

        // Build ACCEPT_GUARDIAN-domain sigs for createAccountWithDefaults
        bytes memory g1Sig = _defaultGuardianSig(attackerWallet, agentWallet.addr, derivedSalt);
        bytes memory g2Sig = _defaultGuardianSig(guardian2Wallet, agentWallet.addr, derivedSalt);

        // Attacker deploys via createAccountWithDefaults
        address attackerDeployed = factory.createAccountWithDefaults(
            agentWallet.addr,
            derivedSalt,
            attackerWallet.addr,
            g1Sig,
            guardian2Wallet.addr,
            g2Sig,
            DAILY_LIMIT
        );

        // KEY ASSERTION: The address deployed by the attacker via createAccountWithDefaults
        // is DIFFERENT from the address getAgentAddress predicts. The fix ensures the two
        // creation paths use distinct salt namespaces.
        assertTrue(
            attackerDeployed != agentAddr,
            "Front-run must not collide: createAccountWithDefaults must land at a different address"
        );

        // Step 4: The legitimate createAgentAccount still succeeds and lands at the predicted address.
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address legitimateDeployed = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );

        assertEq(legitimateDeployed, agentAddr, "Legitimate createAgentAccount must land at predicted address");
    }

    // ─── Deadline expiry ───────────────────────────────────────────────────

    /// @notice A guardian2 signature with an already-expired deadline must be rejected.
    function test_CreateAgentAccount_expiredDeadline_reverts() public {
        // deadline is already in the past
        uint48 deadline = uint48(block.timestamp - 1);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian sig expired");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    // ─── Uniqueness prechecks ──────────────────────────────────────────────

    /// @notice Human owner (msg.sender) cannot be the community guardian.
    function test_CreateAgentAccount_humanIsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        // communityGuardian acts as the human caller
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, communityGuardian, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, communityGuardian, AGENT_ID_1, deadline);

        vm.prank(communityGuardian);
        vm.expectRevert("Human owner cannot be community guardian");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice guardian2 cannot be the community guardian.
    function test_CreateAgentAccount_guardian2IsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(
            vm.createWallet("communityGuardianWallet"),
            humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline
        );
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian2 cannot be community guardian");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, communityGuardian, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice agentKey cannot be the community guardian.
    function test_CreateAgentAccount_agentKeyIsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, communityGuardian, AGENT_ID_1, deadline);
        // We don't have communityGuardian's private key; pass a dummy sig — revert will happen before sig check
        bytes memory agentSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key cannot be community guardian");
        factory.createAgentAccount(
            communityGuardian, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }

    // ─── New tests: MEDIUM-3 and LOW-2 ────────────────────────────────────────

    /// @notice MEDIUM-3: agentKey signature with a wrong signer must revert with AgentKeyDidNotAccept.
    function test_CreateAgentAccount_agentKeyDidNotAccept_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        // Sign with a different key (guardian2Wallet) instead of agentWallet — simulates third-party setting arbitrary EOA
        bytes memory badAgentSig = _agentKeySig(guardian2Wallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert(AAStarAirAccountFactoryV7.AgentKeyDidNotAccept.selector);
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, badAgentSig, deadline, DAILY_LIMIT
        );
    }

    /// @notice LOW-2: deadline more than 30 days in the future must revert.
    function test_CreateAgentAccount_deadlineTooFar_reverts() public {
        uint48 deadline = uint48(block.timestamp + 31 days);
        bytes memory sig2 = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSig = _agentKeySig(agentWallet.privateKey, agentWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert("Deadline too far in future");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentSig, deadline, DAILY_LIMIT
        );
    }
}
