// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {TierGuardHook} from "../src/core/TierGuardHook.sol";

/// @dev Contract account proxy — preCheck returns bytes memory so msg.sender must be a contract.
///      All onInstall/onUninstall/preCheck calls are routed through this helper so that
///      msg.sender = address(accountContract) (a real contract), which TierGuardHook expects.
contract MockAccountCaller {
    function callInstall(TierGuardHook hook, bytes calldata data) external {
        hook.onInstall(data);
    }

    function callUninstall(TierGuardHook hook) external {
        hook.onUninstall("");
    }

    function callPreCheck(
        TierGuardHook hook,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external returns (bytes memory) {
        return hook.preCheck(msgSender, msgValue, msgData);
    }

    function callPreCheckExpectRevert(
        TierGuardHook hook,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external {
        hook.preCheck(msgSender, msgValue, msgData);
    }
}

/// @dev Account that exposes getCurrentAlgId() returning ALG_SESSION_KEY=0x08
///      and getCurrentSessionKey() returning a tagged ECDSA session key address.
contract MockAccountWithSessionKey is MockAccountCaller {
    address public immutable sessionKeyAddr;

    constructor(address _sessionKey) {
        sessionKeyAddr = _sessionKey;
    }

    function getCurrentAlgId() external pure returns (uint256) {
        return 0x08; // ALG_SESSION_KEY
    }

    function getCurrentSessionKey() external view returns (bytes32) {
        // Tag 0x01 = ECDSA session key; lower 20 bytes = session key address
        return bytes32(uint256(0x01) << 248 | uint256(uint160(sessionKeyAddr)));
    }
}

/// @dev Account that returns a non-session algId — simulates ECDSA / BLS / etc.
contract MockAccountWithNonSessionAlgId is MockAccountCaller {
    uint8 public immutable algId;
    constructor(uint8 _algId) { algId = _algId; }
    function getCurrentAlgId() external view returns (uint256) { return algId; }
}

/// @dev Mock AgentSessionKeyValidator that allows/rejects based on a configured allowlist.
contract MockAgentSessionKeyValidator {
    address[] public allowedTargets;

    function setAllowedTargets(address[] memory targets) external {
        delete allowedTargets;
        for (uint256 i = 0; i < targets.length; i++) {
            allowedTargets.push(targets[i]);
        }
    }

    function enforceSessionScope(
        address, /* account */
        address, /* sessionKey */
        address callTarget,
        bytes4  /* selector */
    ) external view {
        if (allowedTargets.length == 0) return; // empty = allow all
        for (uint256 i = 0; i < allowedTargets.length; i++) {
            if (allowedTargets[i] == callTarget) return;
        }
        revert("CallTargetForbidden");
    }
}

/// @title TierGuardHookTest — Unit tests for TierGuardHook (session scope enforcement only)
contract TierGuardHookTest is Test {
    TierGuardHook public hook;

    MockAccountCaller public accountContract;
    address public account;
    address public other;

    function setUp() public {
        hook            = new TierGuardHook();
        accountContract = new MockAccountCaller();
        account         = address(accountContract);
        other           = makeAddr("other");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _installEmpty() internal {
        accountContract.callInstall(hook, "");
    }

    function _installWithValidator(address agentValidator) internal {
        accountContract.callInstall(hook, abi.encode(agentValidator));
    }

    /// @dev Build full execute() calldata as forwarded by _dispatchHook (calldatacopy).
    ///      Layout: [4B selector][32B dest][32B value][32B offset][32B func len][func bytes]
    function _buildExecuteMsgData(
        address dest,
        uint256 value,
        bytes memory func
    ) internal pure returns (bytes memory) {
        bytes4 sel = bytes4(keccak256("execute(address,uint256,bytes)"));
        return abi.encodePacked(sel, abi.encode(dest, value, func));
    }

    // ─── onInstall ────────────────────────────────────────────────────────────

    function test_onInstall_emptyData_initializes() public {
        _installEmpty();
        assertTrue(hook.isInitialized(account));
        assertEq(hook.accountAgentValidator(account), address(0));
    }

    function test_onInstall_withValidator_setsValidator() public {
        address agentValidator = makeAddr("validator");
        _installWithValidator(agentValidator);
        assertTrue(hook.isInitialized(account));
        assertEq(hook.accountAgentValidator(account), agentValidator);
    }

    function test_onInstall_alreadyInstalled_reverts() public {
        _installEmpty();
        vm.expectRevert(TierGuardHook.AlreadyInstalled.selector);
        accountContract.callInstall(hook, "");
    }

    // ─── onUninstall ─────────────────────────────────────────────────────────

    function test_onUninstall_clearsState() public {
        address agentValidator = makeAddr("validator");
        _installWithValidator(agentValidator);

        assertTrue(hook.isInitialized(account));
        assertEq(hook.accountAgentValidator(account), agentValidator);

        accountContract.callUninstall(hook);

        assertFalse(hook.isInitialized(account));
        assertEq(hook.accountAgentValidator(account), address(0));
    }

    function test_onUninstall_allowsReinstall() public {
        _installEmpty();
        accountContract.callUninstall(hook);
        _installEmpty(); // should not revert
        assertTrue(hook.isInitialized(account));
    }

    // ─── isInitialized ────────────────────────────────────────────────────────

    function test_isInitialized_beforeInstall_false() public view {
        assertFalse(hook.isInitialized(account));
    }

    function test_isInitialized_afterInstall_true() public {
        _installEmpty();
        assertTrue(hook.isInitialized(account));
    }

    function test_isInitialized_afterUninstall_false() public {
        _installEmpty();
        accountContract.callUninstall(hook);
        assertFalse(hook.isInitialized(account));
    }

    // ─── preCheck: no agentValidator ─────────────────────────────────────────

    function test_preCheck_notInstalled_passes() public {
        // No install — hook must return empty bytes without reverting
        bytes memory result = accountContract.callPreCheck(hook, other, 0, "");
        assertEq(result, "");
    }

    function test_preCheck_noValidator_passes() public {
        _installEmpty();
        bytes memory result = accountContract.callPreCheck(hook, other, 1 ether, "");
        assertEq(result, "");
    }

    function test_preCheck_noValidator_largeValue_passes() public {
        // Without agentValidator, ETH value is not checked here (enforced by account directly)
        _installEmpty();
        bytes memory result = accountContract.callPreCheck(hook, other, 100 ether, "");
        assertEq(result, "");
    }

    // ─── preCheck: agentValidator set, non-session algId ─────────────────────

    function test_preCheck_validatorSet_nonSessionAlgId_skipsEnforcement() public {
        address tokenB = makeAddr("tokenB");
        address agentValidator = makeAddr("validator"); // any address — staticcall fails = ok, enforcement skipped

        // Deploy account that returns ALG_ECDSA (0x01), not SESSION_KEY
        MockAccountWithNonSessionAlgId ecdsaAccount = new MockAccountWithNonSessionAlgId(0x01);
        ecdsaAccount.callInstall(hook, abi.encode(agentValidator));

        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", other, 100);
        bytes memory msgData = _buildExecuteMsgData(tokenB, 0, func);

        // Should pass — session scope enforcement only applies to ALG_SESSION_KEY
        bytes memory result = ecdsaAccount.callPreCheck(hook, other, 0, msgData);
        assertEq(result, "");
    }

    // ─── preCheck: postCheck ──────────────────────────────────────────────────

    function test_postCheck_noRevert() public {
        hook.postCheck("");
    }

    // ─── M8.P2: Session scope enforcement ────────────────────────────────────

    /// @notice ALG_SESSION_KEY + configured validator: call to forbidden target must revert.
    function test_preCheck_sessionKey_blocksUnauthorizedTarget() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA;
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        sessionAccount.callInstall(hook, abi.encode(address(agentValidator)));

        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", other, 100);
        bytes memory msgData = _buildExecuteMsgData(tokenB, 0, func);

        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        sessionAccount.callPreCheckExpectRevert(hook, other, 0, msgData);
    }

    /// @notice ALG_SESSION_KEY + configured validator: call to allowed target must pass.
    function test_preCheck_sessionKey_allowsAuthorizedTarget() public {
        address tokenA = makeAddr("tokenA");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA;
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        sessionAccount.callInstall(hook, abi.encode(address(agentValidator)));

        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", other, 100);
        bytes memory msgData = _buildExecuteMsgData(tokenA, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, other, 0, msgData);
        assertEq(result, "");
    }

    /// @notice Empty allowlist in validator = any target allowed.
    function test_preCheck_sessionKey_emptyAllowlist_allowsAll() public {
        address anyTarget = makeAddr("anyTarget");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        // No targets set → empty allowlist → allow all

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        sessionAccount.callInstall(hook, abi.encode(address(agentValidator)));

        bytes memory func = abi.encodeWithSignature("doSomething()");
        bytes memory msgData = _buildExecuteMsgData(anyTarget, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, other, 0, msgData);
        assertEq(result, "");
    }

    /// @notice ALG_SESSION_KEY but no agentValidator configured → enforcement skipped, pass.
    function test_preCheck_sessionKey_noValidator_skipsEnforcement() public {
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        sessionAccount.callInstall(hook, ""); // no validator

        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", other, 100);
        bytes memory msgData = _buildExecuteMsgData(tokenB, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, other, 0, msgData);
        assertEq(result, "");
    }

    // ─── Multi-account isolation ──────────────────────────────────────────────

    function test_multiAccount_isolatedState() public {
        MockAccountCaller accountB = new MockAccountCaller();
        address validatorA = makeAddr("validatorA");
        address validatorB = makeAddr("validatorB");

        accountContract.callInstall(hook, abi.encode(validatorA));
        accountB.callInstall(hook, abi.encode(validatorB));

        assertEq(hook.accountAgentValidator(account), validatorA);
        assertEq(hook.accountAgentValidator(address(accountB)), validatorB);
        assertTrue(hook.isInitialized(account));
        assertTrue(hook.isInitialized(address(accountB)));
    }

    function test_multiAccount_uninstallOneDoesNotAffectOther() public {
        MockAccountCaller accountB = new MockAccountCaller();
        address validatorA = makeAddr("validatorA");

        accountContract.callInstall(hook, abi.encode(validatorA));
        accountB.callInstall(hook, "");

        accountContract.callUninstall(hook);

        assertFalse(hook.isInitialized(account));
        assertTrue(hook.isInitialized(address(accountB)));
    }

    // ─── Security: non-canonical ABI offset bypass prevention ────────────────

    /// @notice Attacker crafts calldata with non-canonical bytes offset so the real func
    ///         is at a different position while a fake "allowed" selector sits at offset 132.
    ///         The hook must read the actual offset pointer and block the real (forbidden) selector.
    function test_preCheck_sessionKey_nonCanonicalOffset_blocksRealSelector() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA; // only tokenA is allowed
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        sessionAccount.callInstall(hook, abi.encode(address(agentValidator)));

        // Build non-canonical msgData: offset = 0x80 (128) instead of 0x60 (96).
        // Forbidden func (transfer to tokenB) is at the non-canonical position.
        // Fake allowed selector is planted at fixed offset 132 (the old vulnerable position).
        bytes4 executeSelector = bytes4(keccak256("execute(address,uint256,bytes)"));
        bytes4 allowedFakeSelector = bytes4(keccak256("doSomething()")); // not in forbidden list
        bytes4 forbiddenSelector   = bytes4(keccak256("transfer(address,uint256)"));

        // non-canonical offset = 0x80 = 128
        // args layout (starting after executeSelector):
        //   [0:32]   dest = tokenB (padded)
        //   [32:64]  value = 0
        //   [64:96]  offset = 0x80 (non-canonical, was 0x60)
        //   [96:128] 32 bytes of padding / filler (old "length" position — now contains fake selector)
        //   [128:160] func length = 4
        //   [160:192] func data = forbiddenSelector padded
        bytes memory args = abi.encodePacked(
            bytes32(uint256(uint160(tokenB))),  // dest
            bytes32(uint256(0)),                 // value
            bytes32(uint256(0x80)),              // non-canonical offset: 128 bytes into args
            bytes32(uint256(uint32(allowedFakeSelector))), // fake selector at canonical-offset position
            bytes32(uint256(4)),                 // func length
            bytes32(uint256(uint32(forbiddenSelector)))    // real func: transfer() — forbidden
        );
        bytes memory msgData = abi.encodePacked(executeSelector, args);

        // Hook must follow the offset pointer (0x80) and read the real forbidden selector,
        // NOT read at the canonical fixed position (args[96:100] = fake selector).
        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        sessionAccount.callPreCheckExpectRevert(hook, other, 0, msgData);
    }
}
