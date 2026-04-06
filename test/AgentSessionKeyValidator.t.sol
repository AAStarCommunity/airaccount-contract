// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AgentSessionKeyValidator} from "../src/validators/AgentSessionKeyValidator.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @title AgentSessionKeyValidatorTest — Unit tests for M7.14 AgentSessionKeyValidator
contract AgentSessionKeyValidatorTest is Test {
    using MessageHashUtils for bytes32;

    AgentSessionKeyValidator public validator;

    // Wallets
    address public account;
    Vm.Wallet public sessionWallet;
    Vm.Wallet public otherWallet;

    bytes32 public constant USER_OP_HASH = keccak256("test-agent-userop");

    // ─── Helpers ──────────────────────────────────────────────────────

    /// @dev Build a minimal PackedUserOperation with sender and signature
    function _buildUserOp(
        address sender,
        bytes memory sig
    ) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: bytes(""),
            callData: bytes(""),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: bytes(""),
            signature: sig
        });
    }

    /// @dev Sign userOpHash with a wallet and return the 65-byte ECDSA signature
    function _sign(Vm.Wallet memory w, bytes32 opHash) internal returns (bytes memory) {
        bytes32 ethHash = opHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build a default AgentSessionConfig with expiry in the future and no restrictions
    function _defaultConfig(uint48 expiry) internal pure returns (AgentSessionKeyValidator.AgentSessionConfig memory) {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        return AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: selectors
        });
    }

    // ─── Setup ────────────────────────────────────────────────────────

    function setUp() public {
        validator = new AgentSessionKeyValidator();

        sessionWallet = vm.createWallet("session");
        otherWallet   = vm.createWallet("other");

        // Use a distinct address as the "account" — not a wallet, just an address
        account = address(0xA0C0111);

        // Advance time past block.timestamp = 0 to avoid timestamp edge cases
        vm.warp(1_000_000);
    }

    // ─── A. onInstall / onUninstall / isInitialized ───────────────────

    function test_onInstall_setsInitialized() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        assertTrue(validator.isInitialized(account));
    }

    function test_onUninstall_clearsInitialized() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        vm.prank(account);
        validator.onUninstall(bytes(""));

        assertFalse(validator.isInitialized(account));
    }

    function test_isInitialized_beforeInstall_false() public view {
        assertFalse(validator.isInitialized(account));
    }

    // ─── B. grantAgentSession ─────────────────────────────────────────

    function test_grantAgentSession_succeeds() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );

        vm.expectEmit(true, true, false, true);
        emit AgentSessionKeyValidator.AgentSessionGranted(account, sessionWallet.addr, cfg.expiry);

        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_grantAgentSession_expiredTimestamp_reverts() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = _defaultConfig(
            uint48(block.timestamp - 1)
        );

        vm.prank(account);
        vm.expectRevert(AgentSessionKeyValidator.InvalidExpiry.selector);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_grantAgentSession_storesConfig() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        uint48 expiry = uint48(block.timestamp + 2 hours);
        uint16 velLimit = 10;
        uint32 velWindow = 3600;
        uint256 cap = 500 ether;

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: velLimit,
            velocityWindow: velWindow,
            spendToken: address(0),
            spendCap: cap,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });

        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);

        // Read stored config via public getter
        (
            uint48 storedExpiry,
            uint16 storedVelLimit,
            uint32 storedVelWindow,
            address storedToken,
            uint256 storedCap,
            bool storedRevoked,
            ,

        ) = _readConfig(account, sessionWallet.addr);

        assertEq(storedExpiry,   expiry);
        assertEq(storedVelLimit, velLimit);
        assertEq(storedVelWindow, velWindow);
        assertEq(storedToken,    address(0));
        assertEq(storedCap,      cap);
        assertFalse(storedRevoked);
    }

    /// @dev Helper to read the packed config from public mapping.
    ///      Solidity auto-generated getters for structs with dynamic arrays return only non-array fields.
    ///      The getter returns (expiry, velocityLimit, velocityWindow, spendToken, spendCap, revoked).
    function _readConfig(address acct, address key)
        internal
        view
        returns (
            uint48 expiry,
            uint16 velocityLimit,
            uint32 velocityWindow,
            address spendToken,
            uint256 spendCap,
            bool revoked,
            address[] memory callTargets,
            bytes4[]  memory selectorAllowlist
        )
    {
        // Note: auto-generated getter for struct with dynamic array fields only returns
        // the non-array fields (Solidity strips dynamic arrays from public getters).
        (expiry, velocityLimit, velocityWindow, spendToken, spendCap, revoked) =
            validator.agentSessions(acct, key);
        callTargets = new address[](0);
        selectorAllowlist = new bytes4[](0);
    }

    // ─── C. revokeAgentSession ────────────────────────────────────────

    function test_revokeAgentSession_setsRevoked() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);

        vm.prank(account);
        validator.revokeAgentSession(sessionWallet.addr);

        (, , , , , bool revoked, ,) = _readConfig(account, sessionWallet.addr);
        assertTrue(revoked);
    }

    function test_revokeAgentSession_emitsEvent() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);

        vm.expectEmit(true, true, false, false);
        emit AgentSessionKeyValidator.AgentSessionRevoked(account, sessionWallet.addr);

        vm.prank(account);
        validator.revokeAgentSession(sessionWallet.addr);
    }

    // ─── D. validateUserOp ────────────────────────────────────────────

    function _setupSession(uint48 expiry, uint16 velLimit, uint32 velWindow) internal {
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: velLimit,
            velocityWindow: velWindow,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_validateUserOp_validSig_passes() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _setupSession(expiry, 0, 0);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);

        // result == 0 in low 160 bits, high 48 bits = expiry
        assertEq(result & type(uint160).max, 0);
        assertEq(uint48(result >> 160), expiry);
    }

    function test_validateUserOp_wrongSig_fails() public {
        _setupSession(uint48(block.timestamp + 1 hours), 0, 0);

        bytes memory sig = _sign(otherWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result, 1);
    }

    function test_validateUserOp_expiredSession_fails() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _setupSession(expiry, 0, 0);

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result, 1);
    }

    function test_validateUserOp_revokedSession_fails() public {
        _setupSession(uint48(block.timestamp + 1 hours), 0, 0);

        vm.prank(account);
        validator.revokeAgentSession(sessionWallet.addr);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result, 1);
    }

    function test_validateUserOp_sessionNotFound_fails() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        // Sign with a key that was never granted
        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result, 1);
    }

    function test_validateUserOp_notInitialized_fails() public {
        // Do NOT call onInstall

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result, 1);
    }

    function test_validateUserOp_velocityLimit_exceeded_reverts() public {
        uint16 limit = 2;
        uint32 window = 3600;
        _setupSession(uint48(block.timestamp + 1 hours), limit, window);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        // First call — OK
        validator.validateUserOp(op, USER_OP_HASH);
        // Second call — OK
        validator.validateUserOp(op, USER_OP_HASH);
        // Third call — exceeds limit=2, should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSessionKeyValidator.VelocityLimitExceeded.selector,
                limit,
                uint256(limit)
            )
        );
        validator.validateUserOp(op, USER_OP_HASH);
    }

    function test_validateUserOp_velocityWindow_resets() public {
        uint16 limit = 2;
        uint32 window = 3600;
        _setupSession(uint48(block.timestamp + 24 hours), limit, window);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        // Use up the limit
        validator.validateUserOp(op, USER_OP_HASH);
        validator.validateUserOp(op, USER_OP_HASH);

        // Warp past velocity window — counter should reset
        vm.warp(block.timestamp + window + 1);

        // Should succeed again (new window)
        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        assertEq(result & type(uint160).max, 0);
    }

    function test_validateUserOp_expiryPackedInResult() public {
        uint48 expiry = uint48(block.timestamp + 7 hours);
        _setupSession(expiry, 0, 0);

        bytes memory sig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);

        // High 48 bits (bits 160..207) must equal expiry
        uint48 packedExpiry = uint48(result >> 160);
        assertEq(packedExpiry, expiry);
        // Low part must be 0 (success)
        assertEq(result & type(uint160).max, 0);
    }

    // ─── E. enforceSessionScope ────────────────────────────────────────

    function _grantSessionWithTargets(
        address[] memory targets,
        bytes4[] memory sels,
        uint48 expiry
    ) internal {
        vm.prank(account);
        validator.onInstall(bytes(""));

        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_enforceSessionScope_emptyAllowlist_passes() public {
        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        _grantSessionWithTargets(targets, sels, uint48(block.timestamp + 1 hours));

        // Any target and selector should pass when allowlist is empty
        address anyTarget = address(0x1234);
        bytes4 anySelector = bytes4(0xDEADBEEF);
        // Should not revert
        validator.enforceSessionScope(account, sessionWallet.addr, anyTarget, anySelector);
    }

    function test_enforceSessionScope_targetAllowed_passes() public {
        address allowedTarget = address(0xAABBCC);
        address[] memory targets = new address[](1);
        targets[0] = allowedTarget;
        bytes4[] memory sels = new bytes4[](0);
        _grantSessionWithTargets(targets, sels, uint48(block.timestamp + 1 hours));

        // Should not revert
        validator.enforceSessionScope(account, sessionWallet.addr, allowedTarget, bytes4(0));
    }

    function test_enforceSessionScope_targetForbidden_reverts() public {
        address allowedTarget = address(0xAABBCC);
        address[] memory targets = new address[](1);
        targets[0] = allowedTarget;
        bytes4[] memory sels = new bytes4[](0);
        _grantSessionWithTargets(targets, sels, uint48(block.timestamp + 1 hours));

        address forbiddenTarget = address(0x999999);
        vm.expectRevert(
            abi.encodeWithSelector(AgentSessionKeyValidator.CallTargetForbidden.selector, forbiddenTarget)
        );
        validator.enforceSessionScope(account, sessionWallet.addr, forbiddenTarget, bytes4(0));
    }

    function test_enforceSessionScope_selectorAllowlist_passes() public {
        address[] memory targets = new address[](0);
        bytes4 allowedSel = bytes4(0xAABBCCDD);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = allowedSel;
        _grantSessionWithTargets(targets, sels, uint48(block.timestamp + 1 hours));

        // Should not revert — selector is in allowlist
        validator.enforceSessionScope(account, sessionWallet.addr, address(0x1234), allowedSel);
    }

    function test_enforceSessionScope_selectorForbidden_reverts() public {
        address[] memory targets = new address[](0);
        bytes4 allowedSel = bytes4(0xAABBCCDD);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = allowedSel;
        _grantSessionWithTargets(targets, sels, uint48(block.timestamp + 1 hours));

        bytes4 forbiddenSel = bytes4(0xDEADBEEF);
        address target = address(0x1234);
        vm.expectRevert(
            abi.encodeWithSelector(AgentSessionKeyValidator.SelectorForbidden.selector, target, forbiddenSel)
        );
        validator.enforceSessionScope(account, sessionWallet.addr, target, forbiddenSel);
    }

    // ─── F. recordSpend ────────────────────────────────────────────────

    function _grantSessionWithCap(uint256 cap) internal {
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: uint48(block.timestamp + 1 hours),
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0x1111),
            spendCap: cap,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_recordSpend_belowCap_passes() public {
        uint256 cap = 1000 ether;
        _grantSessionWithCap(cap);

        // Only account may call recordSpend
        vm.prank(account);
        validator.recordSpend(account, sessionWallet.addr, 500 ether);
    }

    function test_recordSpend_exactCap_passes() public {
        uint256 cap = 1000 ether;
        _grantSessionWithCap(cap);

        vm.prank(account);
        validator.recordSpend(account, sessionWallet.addr, 1000 ether);
    }

    function test_recordSpend_exceedsCap_reverts() public {
        uint256 cap = 1000 ether;
        _grantSessionWithCap(cap);

        vm.prank(account);
        validator.recordSpend(account, sessionWallet.addr, 600 ether);
        // Spend another 500 → cumulative 1100 > cap 1000
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSessionKeyValidator.SpendCapExceeded.selector,
                cap,
                uint256(1100 ether)
            )
        );
        validator.recordSpend(account, sessionWallet.addr, 500 ether);
    }

    function test_recordSpend_noCap_passes() public {
        // spendCap = 0 means unlimited
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: uint48(block.timestamp + 1 hours),
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0, // no cap
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);

        // Spend any amount — should not revert (skips tracking entirely)
        vm.startPrank(account);
        validator.recordSpend(account, sessionWallet.addr, type(uint256).max / 2);
        validator.recordSpend(account, sessionWallet.addr, type(uint256).max / 2);
        vm.stopPrank();
    }

    function test_recordSpend_nonAccount_reverts() public {
        uint256 cap = 1000 ether;
        _grantSessionWithCap(cap);

        // Attacker (address(this)) tries to grief by exhausting spend cap
        vm.expectRevert(AgentSessionKeyValidator.OnlyAccountOwner.selector);
        validator.recordSpend(account, sessionWallet.addr, cap);
    }

    // ─── G. delegateSession ────────────────────────────────────────────

    /// @dev Grant a parent session from `account` to `sessionWallet`, then return a sub-key wallet
    function _setupParentSession(uint48 expiry) internal {
        vm.prank(account);
        validator.onInstall(bytes(""));
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = _defaultConfig(expiry);
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_delegateSession_success() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        // Sub-session should exist in storage
        (uint48 storedExpiry, , , , , bool revoked, ,) = _readConfig(account, subWallet.addr);
        assertEq(storedExpiry, parentExpiry);
        assertFalse(revoked);
    }

    function test_delegateSession_narrowerExpiry_allowed() public {
        uint48 parentExpiry = uint48(block.timestamp + 4 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent2");
        // Sub expiry is strictly less than parent expiry
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        (uint48 storedExpiry, , , , , , ,) = _readConfig(account, subWallet.addr);
        assertEq(storedExpiry, uint48(block.timestamp + 1 hours));
    }

    function test_delegateSession_equalExpiry_allowed() public {
        uint48 parentExpiry = uint48(block.timestamp + 3 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent3");
        // Sub expiry exactly equals parent expiry
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        (uint48 storedExpiry, , , , , , ,) = _readConfig(account, subWallet.addr);
        assertEq(storedExpiry, parentExpiry);
    }

    function test_delegateSession_expiredParent_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 1 hours);
        _setupParentSession(parentExpiry);

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent4");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ParentSessionExpired.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_revokedParent_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry);

        // Revoke the parent session
        vm.prank(account);
        validator.revokeAgentSession(sessionWallet.addr);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent5");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ParentSessionExpired.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_noParentSession_reverts() public {
        // Create a wallet that was never granted a session
        Vm.Wallet memory unknownWallet = vm.createWallet("unknown");
        Vm.Wallet memory subWallet    = vm.createWallet("subAgentX");

        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(unknownWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.CallerNotSessionKey.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_expiryEscalation_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 1 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent6");
        // Sub expiry > parent expiry — escalation
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(
            uint48(block.timestamp + 10 hours)
        );

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_spendCapEscalation_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);

        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        // Parent has a spend cap of 100 ether
        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 100 ether,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent7");
        // Sub spend cap > parent spend cap — escalation
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 200 ether,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_velocityEscalation_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);

        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[]  memory sels    = new bytes4[](0);
        // Parent has velocity limit of 5 calls per hour
        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 5,
            velocityWindow: 3600,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent8");
        // Sub velocity limit > parent velocity limit — escalation
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 10,
            velocityWindow: 3600,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: sels
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_callTargetEscalation_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);

        vm.prank(account);
        validator.onInstall(bytes(""));

        address allowedTarget = address(0xABCDEF);
        address[] memory parentTargets = new address[](1);
        parentTargets[0] = allowedTarget;
        bytes4[] memory sels = new bytes4[](0);

        // Parent only allows one target
        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: parentTargets,
            selectorAllowlist: sels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent9");
        // Sub tries to add a new target not in parent's list — escalation
        address extraTarget = address(0x999999);
        address[] memory subTargets = new address[](2);
        subTargets[0] = allowedTarget;
        subTargets[1] = extraTarget;

        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: subTargets,
            selectorAllowlist: sels
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    function test_delegateSession_subSessionIsValidatable() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent10");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        // Sub-agent should be able to pass validateUserOp
        bytes memory sig = _sign(subWallet, USER_OP_HASH);
        PackedUserOperation memory op = _buildUserOp(account, sig);

        uint256 result = validator.validateUserOp(op, USER_OP_HASH);
        // Low 160 bits = 0 (success), high 48 bits = expiry
        assertEq(result & type(uint160).max, 0);
        assertEq(uint48(result >> 160), parentExpiry);
    }

    function test_delegateSession_delegatedBy_recorded() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent11");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        // delegatedBy[account][subKey] must point to parent key
        address recordedParent = validator.delegatedBy(account, subWallet.addr);
        assertEq(recordedParent, sessionWallet.addr);
    }

    // ─── G-extra: selectorAllowlist scope escalation (MEDIUM-2 fix) ───────────

    /// @notice Sub cannot set empty selectorAllowlist (all selectors) when parent restricts to subset.
    function test_delegateSession_selectorAllowlist_emptySubVsRestrictedParent_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4 parentSel = bytes4(0xAABBCCDD);
        bytes4[] memory parentSels = new bytes4[](1);
        parentSels[0] = parentSel;

        // Parent has restricted selectorAllowlist: [0xAABBCCDD]
        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: parentSels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subSel1");
        bytes4[] memory emptySels = new bytes4[](0); // sub wants all selectors — escalation
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: emptySels
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    /// @notice Sub selector not in parent list → escalation denied.
    function test_delegateSession_selectorAllowlist_unknownSubSelector_reverts() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[] memory parentSels = new bytes4[](1);
        parentSels[0] = bytes4(0xAAAAAAAA);

        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: parentSels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subSel2");
        bytes4[] memory subSels = new bytes4[](1);
        subSels[0] = bytes4(0xBBBBBBBB); // not in parent's list

        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: subSels
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.ScopeEscalationDenied.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }

    /// @notice Sub can delegate with a strict subset of parent's selectorAllowlist.
    function test_delegateSession_selectorAllowlist_subset_allowed() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        vm.prank(account);
        validator.onInstall(bytes(""));

        address[] memory targets = new address[](0);
        bytes4[] memory parentSels = new bytes4[](2);
        parentSels[0] = bytes4(0xAAAAAAAA);
        parentSels[1] = bytes4(0xBBBBBBBB);

        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: parentSels
        });
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        Vm.Wallet memory subWallet = vm.createWallet("subSel3");
        bytes4[] memory subSels = new bytes4[](1);
        subSels[0] = bytes4(0xAAAAAAAA); // strict subset of parent

        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry, velocityLimit: 0, velocityWindow: 0,
            spendToken: address(0), spendCap: 0, revoked: false,
            callTargets: targets, selectorAllowlist: subSels
        });

        // Should NOT revert — sub is a strict subset
        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        (uint48 stored, , , , , , ,) = _readConfig(account, subWallet.addr);
        assertEq(stored, parentExpiry);
    }

    /// @notice Both parent and sub have empty selectorAllowlist → both allow all → not escalation.
    function test_delegateSession_selectorAllowlist_bothEmpty_allowed() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry); // both targets and selectors are empty

        Vm.Wallet memory subWallet = vm.createWallet("subSel4");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg); // should not revert

        (uint48 stored, , , , , , ,) = _readConfig(account, subWallet.addr);
        assertEq(stored, parentExpiry);
    }

    function test_delegateSession_parentRevoked_subsessionStillExists_butParentKeyFails() public {
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        _setupParentSession(parentExpiry);

        Vm.Wallet memory subWallet = vm.createWallet("subAgent12");
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = _defaultConfig(parentExpiry);

        vm.prank(sessionWallet.addr);
        validator.delegateSession(subWallet.addr, subCfg);

        // Revoke the parent session
        vm.prank(account);
        validator.revokeAgentSession(sessionWallet.addr);

        // Parent key must now fail validateUserOp
        bytes memory parentSig = _sign(sessionWallet, USER_OP_HASH);
        PackedUserOperation memory parentOp = _buildUserOp(account, parentSig);
        uint256 parentResult = validator.validateUserOp(parentOp, USER_OP_HASH);
        assertEq(parentResult, 1);

        // Sub-session still exists in storage (not automatically revoked)
        (uint48 storedExpiry, , , , , bool revoked, ,) = _readConfig(account, subWallet.addr);
        assertEq(storedExpiry, parentExpiry);
        assertFalse(revoked);
    }

    // ─── Review fix: selectorAllowlist length limit ───────────────────

    function test_grantAgentSession_tooManySelectors_reverts() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        uint48 expiry = uint48(block.timestamp + 1 hours);
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](31); // MAX_SELECTORS = 30
        for (uint256 i = 0; i < 31; i++) {
            selectors[i] = bytes4(uint32(i + 1));
        }
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: selectors
        });

        vm.prank(account);
        vm.expectRevert(AgentSessionKeyValidator.MaxSelectorsExceeded.selector);
        validator.grantAgentSession(sessionWallet.addr, cfg);
    }

    function test_grantAgentSession_exactMaxSelectors_succeeds() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        uint48 expiry = uint48(block.timestamp + 1 hours);
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](30); // exactly MAX_SELECTORS
        for (uint256 i = 0; i < 30; i++) {
            selectors[i] = bytes4(uint32(i + 1));
        }
        AgentSessionKeyValidator.AgentSessionConfig memory cfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: expiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: targets,
            selectorAllowlist: selectors
        });

        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, cfg);
        // Should succeed without revert
    }

    function test_delegateSession_tooManySelectors_reverts() public {
        vm.prank(account);
        validator.onInstall(bytes(""));

        // Grant parent session with unlimited selectors
        uint48 parentExpiry = uint48(block.timestamp + 2 hours);
        AgentSessionKeyValidator.AgentSessionConfig memory parentCfg = _defaultConfig(parentExpiry);
        vm.prank(account);
        validator.grantAgentSession(sessionWallet.addr, parentCfg);

        // Sub-delegate with too many selectors
        Vm.Wallet memory subWallet = vm.createWallet("subTooMany");
        bytes4[] memory selectors = new bytes4[](31);
        for (uint256 i = 0; i < 31; i++) {
            selectors[i] = bytes4(uint32(i + 1));
        }
        AgentSessionKeyValidator.AgentSessionConfig memory subCfg = AgentSessionKeyValidator.AgentSessionConfig({
            expiry: parentExpiry,
            velocityLimit: 0,
            velocityWindow: 0,
            spendToken: address(0),
            spendCap: 0,
            revoked: false,
            callTargets: new address[](0),
            selectorAllowlist: selectors
        });

        vm.prank(sessionWallet.addr);
        vm.expectRevert(AgentSessionKeyValidator.MaxSelectorsExceeded.selector);
        validator.delegateSession(subWallet.addr, subCfg);
    }
}
