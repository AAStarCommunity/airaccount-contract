// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";

/**
 * @title AAStarAirAccountV7 — ERC-4337 account for EntryPoint v0.7
 * @notice Non-upgradable, inherits core logic from AAStarAirAccountBase.
 *
 * ERC-7579 Minimum Compatibility Shim (M6):
 *   AirAccount is NOT a full ERC-7579 implementation (that is M7 work).
 *   This shim adds the minimum surface so that ERC-7579 ecosystem tools
 *   (paymaster SDKs, session key wizards, ZeroDev tooling) can query
 *   account metadata and installed modules without custom integration.
 *
 *   Supported in M6 (read/query only):
 *     - accountId()           — identity string for tooling
 *     - supportsModule()      — declares validator(1) and executor(2) support
 *     - isModuleInstalled()   — maps to existing validator slot
 *     - supportsInterface()   — ERC-165 for ERC-1271 and ERC-7579 interface IDs
 *     - isValidSignature()    — ERC-1271 on-chain signature validation
 *
 *   NOT supported in M6 (full M7):
 *     - installModule() / uninstallModule() with guardian gate + timelock
 *     - executeFromExecutor()
 *     - Full ModeCode execution dispatch
 */
contract AAStarAirAccountV7 is IAccount, AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Semantic version of this contract deployment. Used by SDKs for programmatic version detection.
    string public constant ACCOUNT_VERSION = "0.22.0";

    /// @dev Implementation constructor. Does NOT disable initializers so that direct `new` in tests works.
    ///      The factory deploys one shared implementation and uses Clones for user accounts.
    /// @param _validatorRouter Canonical AAStarValidator router; address(0) for no auto-wire.
    constructor(address _validatorRouter) AAStarAirAccountBase(_validatorRouter) {}

    /// @notice Initialize this account without a guard (called directly in tests or for no-guard accounts).
    ///         The `initializer` modifier from OZ Initializable prevents re-initialization.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians and algorithm list (dailyLimit ignored — no guard deployed)
    /// @notice Initialize this account with a pre-deployed guard and owner P256 passkey.
    ///         Called by the factory when ownerP256X/Y are passed to createAccount.
    ///         The owner passkey is set atomically at account birth (no post-deploy tx required).
    ///         ownerP256X/Y are NOT in InitConfig so the account address is independent of passkey
    ///         (folded into the clone salt separately). Different passkeys → different addresses.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config
    /// @param _guardAddr Pre-deployed AAStarGlobalGuard address (or address(0) for no guard)
    /// @param _ownerP256X Owner P256 public key x-coordinate (or bytes32(0) if not setting)
    /// @param _ownerP256Y Owner P256 public key y-coordinate (or bytes32(0) if not setting)
    function initialize(address _entryPoint, address _owner, InitConfig calldata _config, address _guardAddr, bytes32 _ownerP256X, bytes32 _ownerP256Y) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.guardianP256X, _config.guardianP256Y, _config.minDailyLimit, _guardAddr, _config.approvedAlgIds);
        // Set owner passkey atomically at account birth. Skipping the emit saves ~100 bytes; the
        // factory already logs AccountCreated which anchors the on-chain record.
        p256KeyX = _ownerP256X;
        p256KeyY = _ownerP256Y;
    }

    /// @notice Initialize an autonomous-agent account.
    /// @dev v0.17.2: this no longer pre-installs any validator module. Session keys (for agents
    ///      or DApp gaming flows) are managed via the unified `SessionKeyValidator` registered
    ///      in the router at algId 0x08 — no per-account install is required. After creation the
    ///      owner calls `SessionKeyValidator.grantSession[Direct]` to authorize a specific session.
    ///      Kept as a separate entrypoint from `initialize` to allow factory `createAgentAccount` to
    ///      carry agent-specific semantics (deterministic salt from agentId, agentKey consent sig)
    ///      without forcing those checks on `createAccount` / `createAccountWithDefaults`.
    function initializeAgentAccount(
        address _entryPoint,
        address _owner,
        InitConfig calldata _config,
        address _guardAddr
    ) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.guardianP256X, _config.guardianP256Y, _config.minDailyLimit, _guardAddr, _config.approvedAlgIds);
    }

    // ─── ERC-7579 Minimum Compatibility Shim ─────────────────────────

    // Module type IDs (ERC-7579 §2): 1=validator, 2=executor, 3=fallback, 4=hook.
    // We support validator/executor/hook; fallback (3) is intentionally unsupported.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;
    uint256 internal constant MODULE_TYPE_HOOK      = 4;

    /// @notice ERC-7579 account identity string.
    ///         Format: "vendor.name.version" — enables tooling to identify this account type.
    function accountId() external pure returns (string memory) {
        return string.concat("airaccount.v7@", ACCOUNT_VERSION);
    }

    /// @notice ERC-7579: declare which module types this account supports.
    ///         Declares validator(1), executor(2), and hook(4). Fallback(3) is not supported.
    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR
            || moduleTypeId == MODULE_TYPE_EXECUTOR
            || moduleTypeId == MODULE_TYPE_HOOK;
    }

    /// @notice ERC-7579: check whether a module is installed.
    ///         Checks the unified module registry for supported types (1,2,4).
    ///         Note: the built-in ECDSA validator is registered at initialize time.
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata /* additionalContext */
    ) external view returns (bool) {
        if (moduleTypeId != MODULE_TYPE_VALIDATOR
            && moduleTypeId != MODULE_TYPE_EXECUTOR
            && moduleTypeId != MODULE_TYPE_HOOK) return false;
        return _installedModules[moduleTypeId][module];
    }

    /// @notice Current module-management nonce (issue #75). A guardian signing an installModule /
    ///         uninstallModule request must fold this value into the signed hash; it increments
    ///         after every successful install AND uninstall, so a signature cannot be replayed
    ///         after an uninstall+reinstall cycle.
    function moduleManagementNonce() external view returns (uint256) {
        return _moduleManagementNonce;
    }

    /// @notice ERC-1271: on-chain signature validation used by ERC-7579 tooling and DeFi protocols.
    ///         Validates that the ECDSA signature was produced by this account's owner.
    ///
    /// @dev NO EIP-191 prefix is applied — `hash` must be the EXACT bytes32 that was signed.
    ///
    ///      Integration guide for callers:
    ///
    ///      • EIP-712 / DeFi flows (Permit2, OpenSea, CoW, most DeFi protocols):
    ///        Pass the final EIP-712 digest, i.e. `keccak256("\x19\x01" || domainSeparator || hashStruct)`
    ///        (what `TypedDataEncoder.hash(...)` / ethers `_signTypedData` produce). The owner signs this
    ///        digest directly (no personal_sign prefix). Pass that same bytes32 here — no wrapping needed.
    ///
    ///      • personal_sign / MetaMask `eth_sign` flows:
    ///        The wallet prepends the EIP-191 prefix "\x19Ethereum Signed Message:\n32" before
    ///        signing. The caller must therefore pass the PREFIXED hash, i.e.:
    ///          keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rawHash))
    ///        This is what `MessageHashUtils.toEthSignedMessageHash(rawHash)` produces.
    ///
    ///      This behaviour matches Gnosis Safe and the canonical ERC-1271 production pattern.
    ///
    ///      NOTE: _validateECDSA (the UserOp validation path) DOES apply toEthSignedMessageHash()
    ///      because EOA signers use personal_sign for userOpHash. These are intentionally separate
    ///      paths — ERC-1271 serves DeFi protocols, UserOp validation serves the ERC-4337 bundler.
    ///
    /// @param hash The exact bytes32 that was signed (no prefix added by this contract).
    /// @param sig  65-byte ECDSA signature (r || s || v) produced by the account owner.
    /// @return     0x1626ba7e if the signature is valid, 0xffffffff otherwise.
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        // Standard ERC-1271: recover directly from hash, no additional prefix.
        // tryRecover returns address(0) on a malformed signature instead of reverting, so a bad
        // signature yields the failure magic value rather than bubbling a revert to integrators.
        (address signer,,) = ECDSA.tryRecover(hash, sig);
        if (signer != address(0) && signer == owner) return 0x1626ba7e;
        return 0xffffffff;
    }

    /// @notice ERC-721 receiver — required because official ERC-8004 IdentityRegistry uses _safeMint.
    ///         Without this, minting an agent identity NFT directly to this account would revert.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02; // IERC721Receiver.onERC721Received.selector
    }

    /// @notice ERC-165: interface detection.
    ///         Signals support for ERC-1271 (isValidSignature), ERC-4337, and ERC-721 receiver.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 ||  // ERC-165 itself
            interfaceId == 0x1626ba7e ||  // ERC-1271 isValidSignature
            interfaceId == 0x150b7a02 ||  // IERC721Receiver
            interfaceId == type(IAccount).interfaceId; // ERC-4337 IAccount
    }

    // ─── Core ─────────────────────────────────────────────────────────

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // HIGH-3: key this op's transient algId/weight/sessionKey entries by its callData content,
        // so execute() (whose msg.data == userOp.callData) reads exactly what was validated here,
        // even across a bundle where an earlier op's execution reverts. Set before any store and
        // visible to the CompositeValidator callback (validateCompositeSignature) in this frame.
        _setCallDataKey(keccak256(userOp.callData));
        // ERC-7579 nonce key routing: low 160 bits of the 192-bit nonce key = validator module address (M7.2).
        // If non-zero, route to installed validator module instead of built-in signature routing.
        address validatorModule = address(uint160(userOp.nonce >> 64));
        if (validatorModule != address(0)) {
            if (!_installedModules[MODULE_TYPE_VALIDATOR][validatorModule]) {
                validationData = 1; // SIG_VALIDATION_FAILED — module not installed
            } else {
                // selector = keccak256("validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)")
                (bool ok, bytes memory ret) = validatorModule.call(
                    abi.encodeWithSelector(0x97003203, userOp, userOpHash)
                );
                validationData = (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 1;
                // H-6: store sig[0] as algId so guard receives the correct tier.
                // CompositeValidator may push a more-specific algId first via validateCompositeSignature;
                // execute() reads that entry (pos 0) first, leaving this one unconsumed.
                // Gate on "not failed" (!=1) rather than "==0" so validators returning non-zero
                // validationData (e.g. validUntil timestamp: uint256(expiry)<<160) still queue algId.
                // SIG_VALIDATION_FAILED = 1 is the only sentinel for rejection.
                if (validationData != 1 && userOp.signature.length > 0) {
                    uint8 algId = uint8(userOp.signature[0]);
                    // Codex P1-#11 (2026-05-30): session keys (algId 0x08) MUST NOT come in via
                    // ERC-7579 nonce-key routing. A third-party validator could otherwise pass
                    // sig[0]==0x08 through this path; base._enforceGuard would see algId=0x08 with
                    // taggedSessionKey == bytes32(0) (because nonce-key route does not call
                    // _storeSessionKey) and SKIP the scope/velocity check entirely. To prevent
                    // that bypass, reject ALG_SESSION_KEY here — session keys belong in the
                    // native base._validateSignature path (106/149-byte M6.4 format) where
                    // taggedSessionKey IS populated and _enforceGuard enforces scope.
                    if (algId == ALG_SESSION_KEY) {
                        validationData = 1; // SIG_VALIDATION_FAILED
                    } else {
                        _storeValidatedAlgId(algId);
                    }
                }
            }
        } else {
            validationData = _validateSignature(userOpHash, userOp.signature);
        }

        // v0.17.2-beta.4: AUTHORITATIVE algorithm-whitelist gate.
        // The whitelist now lives in the account's OWN storage (single source of truth), so it can
        // be read here during validation — ERC-7562 permits reading the account's own storage, but
        // NOT the separate unstaked guard's. Enforcing it here (rather than in the guard at execution)
        // is what makes guard-enabled accounts work through a bundler: the previous design read the
        // algId from cross-eth_call transient storage, which the bundler clears between its separate
        // validation and execution simulations → algId=0 → AlgorithmNotApproved(0). This gate runs in
        // BOTH estimation and real handleOps. SIG_VALIDATION_FAILED (1) is the only failure sentinel.
        if (validationData != 1 && address(guard) != address(0)) {
            uint8 a = _consumeValidatedAlgId();
            if (!approvedAlgorithms[a]) {
                return 1; // SIG_VALIDATION_FAILED — algorithm not whitelisted for this account
            }
            // Per-op ETH tier gate (fail-fast). Reject an obviously under-tier op here rather than
            // letting execution revert with InsufficientTier. NOTE (Codex MEDIUM, accepted): this is
            // a PER-OP check only. The CUMULATIVE daily-spend tier (todaySpent + value) cannot be
            // checked in validation because todaySpent lives in the unstaked guard contract and
            // ERC-7562 forbids reading it during validation. Cumulative tier stays authoritative in
            // execution (_enforceGuard) and is surfaced to clients at gas-estimation time (the
            // executeUserOp simulation reverts on any cumulative violation before submission).
            if (tier1Limit > 0 || tier2Limit > 0) {
                uint8 resolved = (a == ALG_WEIGHTED) ? _resolveWeightedAlgId(_consumeValidatedWeight()) : a;
                if (!_validationTierOk(resolved, userOp.callData)) {
                    return 1; // SIG_VALIDATION_FAILED — signature tier below the value's required tier
                }
            }
        }

        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }

    /// @notice ERC-4337 v0.7 IAccountExecute entrypoint (v0.17.2-beta.4).
    /// @dev When `userOp.callData` begins with this selector, the EntryPoint calls THIS function with
    ///      the FULL userOp (incl. signature) instead of calling `callData` directly. That lets the
    ///      execution phase re-derive the validated algId DIRECTLY from `userOp.signature` — in the
    ///      same call frame, deterministically, in both bundler estimation and real handleOps — with
    ///      no dependency on cross-eth_call transient storage. We populate the same-frame algId queue
    ///      from the signature, then self-`delegatecall` the inner execute()/executeBatch() calldata
    ///      (delegatecall preserves msg.sender == EntryPoint, so execute() consumes the algId we just
    ///      stored and runs its existing tier/guard logic with the correct algId).
    /// @dev Reverts when executeUserOp's inner calldata is not execute()/executeBatch().
    error UnsupportedInnerSelector();

    function executeUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external onlyEntryPoint {
        bytes calldata inner = userOp.callData[4:]; // strip the executeUserOp selector
        // SECURITY (Codex CRITICAL): only execute()/executeBatch() may be dispatched. A nested
        // executeUserOp (or any other selector) is rejected — otherwise the nested op's signature is
        // NEVER validated, so _populateExecAlg would trust a forged algId prefix and bypass the
        // tier/whitelist gate, executing a high-value/high-tier call off a tier-1 outer signature.
        if (inner.length < 4) revert UnsupportedInnerSelector();
        bytes4 innerSel = bytes4(inner[:4]);
        if (innerSel != this.execute.selector && innerSel != this.executeBatch.selector) {
            revert UnsupportedInnerSelector();
        }
        // Key the algId queue by the INNER calldata so the self-delegatecall (whose msg.data == inner,
        // matching execute()'s _setCallDataKey(keccak256(msg.data))) reads exactly what we store here.
        _setCallDataKey(keccak256(inner));
        _populateExecAlg(userOpHash, userOp.signature);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = address(this).delegatecall(inner);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
    }

    /// @dev v0.17.2-beta.4: per-op ETH tier check for the validateUserOp gate. Decodes the ETH
    ///      value(s) from the userOp callData (unwrapping the executeUserOp selector if present, then
    ///      execute/executeBatch) and verifies the provided signature tier covers requiredTier(value).
    ///      Returns true (no rejection) for callData that does not move ETH through execute/executeBatch
    ///      (those paths carry no value-tier obligation here). The cumulative/daily tier is still
    ///      enforced authoritatively in execution; this is the fail-fast per-op gate.
    function _validationTierOk(uint8 resolvedAlgId, bytes calldata callData) internal view returns (bool) {
        bytes calldata cd = callData;
        // Unwrap the ERC-4337 v0.7 executeUserOp wrapper if present.
        if (cd.length >= 4 && bytes4(cd[:4]) == this.executeUserOp.selector) {
            if (cd.length < 8) return true;
            cd = cd[4:];
        }
        if (cd.length < 4) return true;
        bytes4 sel = bytes4(cd[:4]);
        uint8 provided = _algTier(resolvedAlgId);

        if (sel == this.execute.selector) {
            // execute(address dest, uint256 value, bytes func): value at [4+32 : 4+64]
            if (cd.length < 68) return true;
            uint256 value = uint256(bytes32(cd[36:68]));
            return provided >= requiredTier(value);
        }
        // executeBatch and all other selectors: tier is enforced authoritatively per-call in
        // execution (_enforceGuard, with cumulative daily spend) and surfaced at gas estimation via
        // the executeUserOp simulation. We deliberately do NOT decode batch values here — a per-op
        // batch check in validation would be inconsistent with the execution-side CUMULATIVE check
        // (Codex MEDIUM) and would cost significant bytecode. Single execute() is the fast-fail case.
        return true;
    }

    // ─── ERC-7579 Module Management (M7.2) ────────────────────────────
    //
    // installModule() and uninstallModule() are implemented in AirAccountExtension.
    // They are reached via the account's fallback() → delegatecall(agentExtension) path.
    // The function selectors are identical; the extension runs in account storage context.

    /// @notice ERC-7579: Execute a single call on behalf of this account, called by an installed executor module.
    ///         Executor modules are installed via guardians (installModule requires guardian sig), providing
    ///         authentication. The full guard is enforced here at Tier 1 (ALG_ECDSA).
    /// @dev    C-4: executors run at Tier 1 and cannot supply higher-tier (multi-factor) signatures, so they
    ///         are bound to the account's Tier-1 ceiling. Routing through _enforceGuard (rather than a bare
    ///         guard.checkTransaction) applies the cumulative ETH tier check too: an executor op whose value
    ///         pushes today's spend above tier1Limit reverts InsufficientTier. The account owner controls what
    ///         counts as "small" by tuning tier1Limit.
    /// @dev    NOTE: the tier check is only active when tiering is configured (tier1Limit or tier2Limit > 0).
    ///         If both are 0, tiering is disabled and an executor is bounded only by the guard's daily limit
    ///         (and token limits) — it is NOT implicitly capped. Set tier1Limit to enforce a per-op ETH ceiling.
    /// @param mode    ModeCode (bytes32): byte[0] must be 0x00 (single call). Batch mode not supported in M7.
    /// @param executionCalldata abi.encodePacked(target(20), value(32), calldata)
    /// @return returnData Single-element array with the call's return bytes
    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external nonReentrant returns (bytes[] memory returnData) {
        if (!_installedModules[MODULE_TYPE_EXECUTOR][msg.sender]) revert ModuleNotInstalled();
        // ERC-7579 ModeCode: only single-call (byte[0]=0x00) with no extra flags (bytes[1-31] must be zero).
        // Reject batch mode (0x01) and any unknown execution type flags — strict compliance, no ambiguity.
        if (mode != bytes32(0)) revert InvalidModuleType();
        if (executionCalldata.length < 52) revert ArrayLengthMismatch();

        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value  = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];

        // Full guard enforcement at Tier 1: cumulative ETH tier + daily limit + algorithm
        // whitelist + ERC20/token limits. skipEthCheck=false (executor path holds correct msg.sender).
        // #81: read the guard storage slot once and pass the cached address into _enforceGuard.
        _enforceGuard(value, ALG_ECDSA, bytes32(0), target, data, false, address(guard));

        returnData = new bytes[](1);
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) { assembly { revert(add(result, 32), mload(result)) } }
        returnData[0] = result;
    }
}
