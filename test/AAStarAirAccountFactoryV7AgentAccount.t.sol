// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AgentSessionKeyValidator} from "../src/validators/AgentSessionKeyValidator.sol";

/// @title AAStarAirAccountFactoryV7AgentAccountTest
/// @notice Tests for createAgentAccount() and getAgentAddress() on AAStarAirAccountFactoryV7.
///         An agent account has:
///           - owner = humanAirAccount (msg.sender — the human who creates the account)
///           - guardian1 = guardian2 (the human's backup/trusted person, must sign acceptance)
///           - guardian2 = communityGuardian (AAstar Safe multisig)
///           - agentKey = the AI agent's signing key, authorized separately via grantAgentSession()
///           - salt = keccak256("AASTAR_AGENT_V1" || agentKey || humanOwner || agentId)
contract AAStarAirAccountFactoryV7AgentAccountTest is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public communityGuardian;

    // Human owner wallet — the caller who creates agent accounts; becomes the account owner
    Vm.Wallet public humanWallet;
    // Agent key wallet — the AI agent's signing key; authorized as session key post-deployment
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

    // ─── Helpers: build acceptance signatures ─────────────────────────────

    /// @dev guardian2 acceptance signature for createAgentAccount.
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

    /// @dev agentKey consent signature for createAgentAccount.
    function _agentKeySig(
        Vm.Wallet memory agent,
        address humanOwner,
        bytes32 agentId,
        uint48 deadline
    ) internal view returns (bytes memory) {
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_AGENT_KEY", block.chainid, address(factory), agent.addr, humanOwner, agentId, deadline)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agent.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build guardian acceptance signature for createAccountWithDefaults (cross-namespace test).
    function _defaultGuardianSig(
        Vm.Wallet memory g,
        address owner,
        uint256 salt
    ) internal view returns (bytes memory) {
        bytes32 raw = keccak256(
            abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(factory), owner, salt, DAILY_LIMIT)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── Happy path ────────────────────────────────────────────────────────

    /// @notice Full happy path: deploy agent account, verify owner and guardians.
    function test_CreateAgentAccount_success() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address account = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        assertTrue(account.code.length > 0, "Account not deployed");

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        // Owner must be the humanAirAccount (msg.sender), not agentKey
        assertEq(acc.owner(), humanWallet.addr, "Owner must be humanAirAccount");

        // Guardians: [guardian2Wallet, communityGuardian] — 2-of-2 (human is owner, not guardian)
        assertEq(acc.guardianCount(), 2, "Should have 2 guardians");
        assertEq(acc.guardians(0), guardian2Wallet.addr, "guardian1 must be guardian2Wallet");
        assertEq(acc.guardians(1), communityGuardian,    "guardian2 must be communityGuardian");

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
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        // Second call with same params — sigs must be re-provided but result is deterministic
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        assertEq(a1, a2, "Second call must return same address");
    }

    // ─── Signature validation ──────────────────────────────────────────────

    /// @notice Wrong guardian2 signature must revert with GuardianDidNotAccept.
    function test_CreateAgentAccount_wrongGuardian2Sig_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, badSig, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice Acceptance sig signed for wrong agentKey must be rejected.
    function test_CreateAgentAccount_sigForWrongAgentKey_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        Vm.Wallet memory anotherAgent = vm.createWallet("anotherAgent");
        // guardian2 signed for anotherAgent, but we pass agentWallet as the agentKey
        bytes memory wrongSig = _guardian2Sig(guardian2Wallet, humanWallet.addr, anotherAgent.addr, AGENT_ID_1, deadline);
        bytes memory agentS   = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, guardian2Wallet.addr)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, wrongSig, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice Wrong agentKey consent signature must revert with AgentKeyDidNotAccept.
    function test_CreateAgentAccount_wrongAgentKeySig_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2    = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory badSig  = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(humanWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountFactoryV7.AgentKeyDidNotAccept.selector)
        );
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, badSig, deadline, DAILY_LIMIT
        );
    }

    // ─── Require checks ────────────────────────────────────────────────────

    /// @notice Zero agentKey must revert before sig checks.
    function test_CreateAgentAccount_zeroAgentKey_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, address(0), AGENT_ID_1, deadline);
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key required");
        factory.createAgentAccount(
            address(0), AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice Zero guardian2 must revert before sig checks.
    function test_CreateAgentAccount_zeroGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian2 required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, address(0), sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice Zero daily limit must revert before sig checks.
    function test_CreateAgentAccount_zeroDailyLimit_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Daily limit required");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, 0
        );
    }

    /// @notice Caller (human) cannot also be guardian2.
    function test_CreateAgentAccount_callerEqualsGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Caller cannot be guardian2");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, humanWallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice agentKey cannot equal guardian2.
    function test_CreateAgentAccount_agentKeyEqualsGuardian2_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key cannot be guardian2");
        factory.createAgentAccount(
            guardian2Wallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    // ─── Address prediction ────────────────────────────────────────────────

    /// @notice getAgentAddress must match the actual deployed address.
    function test_GetAgentAddress_matchesDeployed() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address deployed = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        assertEq(predicted, deployed, "Predicted address must match deployed");
    }

    // ─── Event emission ────────────────────────────────────────────────────

    /// @notice AgentAccountCreated event must be emitted with correct indexed and non-indexed fields.
    function test_AgentAccountCreated_event() public {
        address predicted = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);

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
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    // ─── Determinism: different agentIds produce different addresses ───────

    /// @notice Same human + different agentId → different account addresses.
    function test_AgentAccount_differentAgentIds_differentAddresses() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2a  = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSa = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, agentSa, deadline, DAILY_LIMIT
        );

        bytes memory sig2b  = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_2, deadline);
        bytes memory agentSb = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_2, deadline);
        vm.prank(humanWallet.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_2, guardian2Wallet.addr, sig2b, agentSb, deadline, DAILY_LIMIT
        );

        assertTrue(a1 != a2, "Different agentIds must produce different addresses");
    }

    /// @notice Same agentId but different humanOwner → different account addresses.
    function test_AgentAccount_differentHumans_differentAddresses() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        Vm.Wallet memory anotherHuman = vm.createWallet("anotherHuman");

        bytes memory sig2a  = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSa = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address a1 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2a, agentSa, deadline, DAILY_LIMIT
        );

        bytes memory sig2b  = _guardian2Sig(guardian2Wallet, anotherHuman.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentSb = _agentKeySig(agentWallet, anotherHuman.addr, AGENT_ID_1, deadline);
        vm.prank(anotherHuman.addr);
        address a2 = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2b, agentSb, deadline, DAILY_LIMIT
        );

        assertTrue(a1 != a2, "Different humans must produce different addresses for same agentId");
    }

    // ─── agentKey == msg.sender is allowed (owner != guardian invariant) ───

    /// @notice agentKey == msg.sender succeeds with the new owner model.
    ///         owner = humanAirAccount (msg.sender), guardians = [guardian2, community].
    ///         agentKey is authorized separately as session key; it is NOT a guardian.
    ///         So agentKey == msg.sender is legal (no owner==guardian conflict).
    function test_CreateAgentAccount_agentKeyEqualsCaller_succeeds() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        // Human uses their own address as the agent signing key — now legal
        // because human = owner, and guardians are [guardian2, community] (not human)
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, humanWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(humanWallet, humanWallet.addr, AGENT_ID_1, deadline);

        vm.prank(humanWallet.addr);
        address account = factory.createAgentAccount(
            humanWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        assertTrue(account.code.length > 0, "Account must be deployed when agentKey == caller");
        assertEq(AAStarAirAccountV7(payable(account)).owner(), humanWallet.addr, "Owner must be human");
    }

    // ─── Front-run resistance: cross-namespace salt collision ──────────────

    /// @notice An attacker who intercepts a createAgentAccount mempool transaction CANNOT
    ///         pre-deploy the same address via createAccountWithDefaults.
    function test_CreateAgentAccount_cannotBeFrontRunByCreateAccountWithDefaults() public {
        address agentAddr = factory.getAgentAddress(humanWallet.addr, agentWallet.addr, AGENT_ID_1);

        uint256 derivedSalt = uint256(keccak256(abi.encodePacked(humanWallet.addr, AGENT_ID_1)));

        Vm.Wallet memory attackerWallet = vm.createWallet("attacker");
        bytes memory g1Sig = _defaultGuardianSig(attackerWallet, agentWallet.addr, derivedSalt);
        bytes memory g2Sig = _defaultGuardianSig(guardian2Wallet, agentWallet.addr, derivedSalt);

        address attackerDeployed = factory.createAccountWithDefaults(
            agentWallet.addr, derivedSalt, attackerWallet.addr, g1Sig, guardian2Wallet.addr, g2Sig, DAILY_LIMIT
        );

        assertTrue(
            attackerDeployed != agentAddr,
            "Front-run must not collide: createAccountWithDefaults must land at a different address"
        );

        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, AGENT_ID_1, deadline);
        vm.prank(humanWallet.addr);
        address legitimateDeployed = factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );

        assertEq(legitimateDeployed, agentAddr, "Legitimate createAgentAccount must land at predicted address");
    }

    // ─── Deadline expiry ───────────────────────────────────────────────────

    /// @notice A guardian2 signature with an already-expired deadline must be rejected.
    function test_CreateAgentAccount_expiredDeadline_reverts() public {
        uint48 deadline = uint48(block.timestamp - 1);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, AGENT_ID_1, deadline);
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian sig expired");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    // ─── Uniqueness prechecks ──────────────────────────────────────────────

    /// @notice Human owner (msg.sender) cannot be the community guardian.
    function test_CreateAgentAccount_humanIsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(communityGuardian);
        vm.expectRevert("Human owner cannot be community guardian");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice guardian2 cannot be the community guardian.
    function test_CreateAgentAccount_guardian2IsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Guardian2 cannot be community guardian");
        factory.createAgentAccount(
            agentWallet.addr, AGENT_ID_1, communityGuardian, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice agentKey cannot be the community guardian.
    function test_CreateAgentAccount_agentKeyIsCommunityGuardian_reverts() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = hex"";
        bytes memory agentS = hex"";

        vm.prank(humanWallet.addr);
        vm.expectRevert("Agent key cannot be community guardian");
        factory.createAgentAccount(
            communityGuardian, AGENT_ID_1, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    // ─── #21: hybrid default-install of AgentSessionKeyValidator on agent accounts ──────

    /// @dev Create an agent account with default sigs (helper for the install tests).
    function _createAgent(bytes32 agentId) internal returns (address) {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig2   = _guardian2Sig(guardian2Wallet, humanWallet.addr, agentWallet.addr, agentId, deadline);
        bytes memory agentS = _agentKeySig(agentWallet, humanWallet.addr, agentId, deadline);
        vm.prank(humanWallet.addr);
        return factory.createAgentAccount(
            agentWallet.addr, agentId, guardian2Wallet.addr, sig2, agentS, deadline, DAILY_LIMIT
        );
    }

    /// @notice When configured, agent accounts default-install the AgentSessionKeyValidator (validator
    ///         module installed + onInstall called); installing is inert until a session is granted.
    function test_AgentAccount_defaultInstalls_validator_whenConfigured() public {
        AgentSessionKeyValidator validator = new AgentSessionKeyValidator();
        factory.setAgentSessionKeyValidator(address(validator)); // deployer (this test) is factoryAdmin

        address account = _createAgent(AGENT_ID_1);
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        // Module registered on the account (ERC-7579 validator type = 1)
        assertTrue(acc.isModuleInstalled(1, address(validator), ""), "validator must be installed");
        // onInstall was called → validator marks the account initialized
        assertTrue(validator.isInitialized(account), "onInstall must have run");
        // Inert: no session granted yet → expiry == 0 for any key
        (uint48 expiry,,,) = validator.agentSessions(account, agentWallet.addr);
        assertEq(expiry, 0, "no session should be granted by default (install is inert)");
    }

    /// @notice When NOT configured (address(0)), createAgentAccount still works — no default install.
    function test_AgentAccount_noValidator_gracefulNoInstall() public {
        // factory.agentSessionKeyValidator == address(0) (never set)
        address account = _createAgent(AGENT_ID_2);
        assertTrue(account.code.length > 0, "account still created");
        // Nothing installed under a zero address (sanity: a random module is not installed)
        assertFalse(AAStarAirAccountV7(payable(account)).isModuleInstalled(1, address(0xBEEF), ""), "no default install");
    }

    /// @notice Regular (non-agent) accounts do NOT get the validator (hybrid = opt-in for them).
    function test_RegularAccount_doesNotInstall_validator() public {
        AgentSessionKeyValidator validator = new AgentSessionKeyValidator();
        factory.setAgentSessionKeyValidator(address(validator));

        // Plain account via createAccount (no default install path)
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0), initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        vm.prank(humanWallet.addr);
        address account = factory.createAccount(humanWallet.addr, 1, cfg);
        assertFalse(AAStarAirAccountV7(payable(account)).isModuleInstalled(1, address(validator), ""),
            "regular account must NOT default-install the agent validator");
    }

    // ─── setter security (deployer-only, set-once, contract-only) ──────────

    function test_setAgentSessionKeyValidator_onlyFactoryAdmin() public {
        AgentSessionKeyValidator validator = new AgentSessionKeyValidator();
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(AAStarAirAccountFactoryV7.NotFactoryAdmin.selector);
        factory.setAgentSessionKeyValidator(address(validator));
    }

    function test_setAgentSessionKeyValidator_setOnce() public {
        AgentSessionKeyValidator v1 = new AgentSessionKeyValidator();
        AgentSessionKeyValidator v2 = new AgentSessionKeyValidator();
        factory.setAgentSessionKeyValidator(address(v1));
        vm.expectRevert(AAStarAirAccountFactoryV7.AgentValidatorAlreadySet.selector);
        factory.setAgentSessionKeyValidator(address(v2));
        assertEq(factory.agentSessionKeyValidator(), address(v1), "set-once: first value sticks");
    }

    function test_setAgentSessionKeyValidator_mustBeContract() public {
        vm.expectRevert(AAStarAirAccountFactoryV7.AgentValidatorNotContract.selector);
        factory.setAgentSessionKeyValidator(makeAddr("eoa")); // EOA, no code
    }
}
