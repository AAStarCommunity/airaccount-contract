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
    string public constant ACCOUNT_VERSION = "0.17.2";

    /// @dev Implementation constructor. Does NOT disable initializers so that direct `new` in tests works.
    ///      The factory deploys one shared implementation and uses Clones for user accounts.
    constructor() {}

    /// @notice Initialize this account without a guard (called directly in tests or for no-guard accounts).
    ///         The `initializer` modifier from OZ Initializable prevents re-initialization.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians and algorithm list (dailyLimit ignored — no guard deployed)
    function initialize(address _entryPoint, address _owner, InitConfig calldata _config) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.minDailyLimit, address(0), _config.approvedAlgIds);
    }

    /// @notice Initialize this account with a pre-deployed guard.
    ///         Guard must be deployed by the caller (factory or test) before calling this.
    ///         Keeping guard deployment outside the account removes ~4,595B of creation code
    ///         from the account's runtime, keeping it under EIP-170's 24,576-byte limit.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians (dailyLimit/algIds used to deploy _guardAddr)
    /// @param _guardAddr Pre-deployed AAStarGlobalGuard address bound to this account's address
    function initialize(address _entryPoint, address _owner, InitConfig calldata _config, address _guardAddr) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.minDailyLimit, _guardAddr, _config.approvedAlgIds);
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
        _initAccount(_entryPoint, _owner, _config.guardians, _config.minDailyLimit, _guardAddr, _config.approvedAlgIds);
    }

    // ─── ERC-7579 Minimum Compatibility Shim ─────────────────────────

    // Module type IDs (ERC-7579 §2): 1=validator, 2=executor, 3=fallback, 4=hook.
    // We support validator/executor/hook; fallback (3) is intentionally unsupported.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;
    uint256 internal constant MODULE_TYPE_HOOK      = 4;

    // ERC-7579 module lifecycle selectors
    bytes4 private constant SEL_ON_INSTALL   = 0x6d61fe70; // onInstall(bytes)
    bytes4 private constant SEL_ON_UNINSTALL = 0x8a91b0e3; // onUninstall(bytes)

    /// @notice ERC-7579 account identity string.
    ///         Format: "vendor.name.version" — enables tooling to identify this account type.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.17.2";
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

    /// @notice ERC-1271: on-chain signature validation used by ERC-7579 tooling and DeFi protocols.
    ///         Validates that the ECDSA signature was produced by this account's owner.
    /// @dev IMPORTANT — hash behaviour: this function does NOT apply any EIP-191 prefix.
    ///      The `hash` parameter must be the exact bytes32 the owner signed.
    ///      - EIP-712 / DeFi flows (Permit2, OpenSea, etc.): pass the typed-data struct hash directly.
    ///        The owner signs this hash without a personal_sign prefix, so no prefix is applied here.
    ///      - personal_sign / MetaMask eth_sign flows: the wallet adds the EIP-191 prefix before signing,
    ///        so the caller must pass keccak256("\x19Ethereum Signed Message:\n32" || rawHash) as `hash`.
    ///      This matches the behaviour of Gnosis Safe and most production ERC-1271 implementations.
    ///      Note: internally, UserOp validation (_validateECDSA) does apply toEthSignedMessageHash()
    ///      because EOA wallets sign userOpHash with personal_sign — these are two separate paths.
    /// @return magicValue 0x1626ba7e if valid, 0xffffffff otherwise
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

    /// @dev Best-effort lifecycle call (onUninstall) with empty bytes data.
    ///      Uses abi.encodeWithSelector to avoid clobbering Solidity's scratch space (0x00–0x3f)
    ///      and free-memory pointer (0x40). Return value intentionally ignored.
    function _callLifecycle(bytes4 sel, address module) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool _ok,) = module.call(abi.encodeWithSelector(sel, new bytes(0)));
        _ok; // silence unused-variable warning — best-effort, failure is intentionally ignored
    }

    /// @dev Verify `count` sequential 65-byte ECDSA sigs from distinct guardians.
    ///      Reverts InstallModuleUnauthorized on any failure (too few bytes, non-guardian, double-vote).
    function _checkGuardianSigs(bytes32 hash, bytes calldata sigs, uint8 count) private {
        uint256 bitmap;
        for (uint8 i; i < count; ++i) {
            uint256 end = uint256(i + 1) * 65;
            if (sigs.length < end) revert InstallModuleUnauthorized();
            address recovered = hash.recover(sigs[end - 65 : end]);
            uint256 bit = uint256(1) << _guardianIndex(recovered);
            if (bitmap & bit != 0) revert InstallModuleUnauthorized();
            bitmap |= bit;
        }
    }

    /// @notice ERC-7579: Install a module.
    /// @param moduleTypeId 1=Validator, 2=Executor, 3=Hook
    /// @param module Module contract address (must be deployed)
    /// @param initData Layout: guardian sig(s) prepended, then module init data.
    ///   Guardian sig count: 0 if threshold<=40, 1 if threshold<=70, 2 if threshold=100.
    ///   Sig hash: keccak256("INSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    ///   Bytes after the sig(s) are passed as initData to onInstall(bytes).
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external onlyOwnerOrEntryPoint {
        if (module == address(0) || module.code.length == 0) revert ModuleInvalid();
        if (moduleTypeId != MODULE_TYPE_VALIDATOR
            && moduleTypeId != MODULE_TYPE_EXECUTOR
            && moduleTypeId != MODULE_TYPE_HOOK) revert InvalidModuleType();

        uint8 threshold = _installModuleThreshold == 0 ? 70 : _installModuleThreshold;
        uint8 sigsRequired = threshold >= 100 ? 2 : (threshold >= 70 ? 1 : 0);

        if (sigsRequired > 0) {
            uint256 sigEnd = uint256(sigsRequired) * 65;
            // Explicit length guard before slice — prevents panic and gives readable revert.
            if (initData.length < sigEnd) revert InstallModuleUnauthorized();
            // v3-MEDIUM fix: sig binds keccak256(moduleInitData) to prevent config-swap attacks.
            // Guardian signs over both the module identity AND the module init configuration.
            bytes32 moduleInitDataHash = keccak256(initData[sigEnd:]);
            _checkGuardianSigs(
                keccak256(abi.encodePacked(
                    "INSTALL_MODULE", block.chainid, address(this),
                    moduleTypeId, module, moduleInitDataHash
                )).toEthSignedMessageHash(),
                initData, sigsRequired
            );
        }

        bytes calldata moduleInitData = initData[uint256(sigsRequired) * 65:];

        if (_installedModules[moduleTypeId][module]) revert ModuleAlreadyInstalled();
        // LOW-1: Reject second hook install — silent overwrite would deactivate TierGuardHook without warning.
        // Caller must explicitly uninstallModule the existing hook before installing a new one.
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook != address(0)) revert ModuleAlreadyInstalled();

        // MEDIUM-2: Only call onInstall on the first installation of this module address.
        // A module may legitimately implement multiple roles (e.g. validator + executor).
        // Calling onInstall again on secondary typeId would double-initialize shared state
        // (e.g. _initialized in AgentSessionKeyValidator) and silently discard initData.
        bool alreadyLive = _installedModules[MODULE_TYPE_VALIDATOR][module]
                        || _installedModules[MODULE_TYPE_EXECUTOR][module]
                        || _installedModules[MODULE_TYPE_HOOK][module];

        _installedModules[moduleTypeId][module] = true;
        if (moduleTypeId == MODULE_TYPE_HOOK) _activeHook = module;

        if (!alreadyLive) {
            // MEDIUM-1: Hard-revert if onInstall fails — leaving module marked installed but
            // uninitialized creates a stuck state where validateUserOp returns 1 forever.
            // Revert rolls back _installedModules and _activeHook atomically.
            (bool _ok,) = module.call(abi.encodeWithSelector(SEL_ON_INSTALL, moduleInitData));
            if (!_ok) revert ModuleInstallCallbackFailed(moduleTypeId, module);
        }

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @notice ERC-7579: Uninstall a module.
    /// @dev Requires min(guardianCount, 2) guardian sigs.
    ///      Accounts with fewer than 2 real guardians use all available guardian sigs
    ///      so that modules are never permanently locked even on minimal-guardian accounts.
    ///      Sig hash: keccak256("UNINSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external onlyOwnerOrEntryPoint {
        if (moduleTypeId != MODULE_TYPE_VALIDATOR
            && moduleTypeId != MODULE_TYPE_EXECUTOR
            && moduleTypeId != MODULE_TYPE_HOOK) revert InvalidModuleType();

        uint8 sigsRequired = _guardianCount < 2 ? _guardianCount : 2;
        _checkGuardianSigs(
            keccak256(abi.encodePacked("UNINSTALL_MODULE", block.chainid, address(this), moduleTypeId, module))
                .toEthSignedMessageHash(),
            deInitData, sigsRequired
        );

        if (!_installedModules[moduleTypeId][module]) revert ModuleNotInstalled();
        _installedModules[moduleTypeId][module] = false;
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook == module) _activeHook = address(0);

        // MEDIUM-2: Only call onUninstall when this is the last active installation of the module.
        // If the module is still installed under another typeId, calling onUninstall would clear
        // shared state (e.g. _initialized) and break the remaining role.
        bool stillLive = _installedModules[MODULE_TYPE_VALIDATOR][module]
                      || _installedModules[MODULE_TYPE_EXECUTOR][module]
                      || _installedModules[MODULE_TYPE_HOOK][module];
        if (!stillLive) {
            _callLifecycle(SEL_ON_UNINSTALL, module); // best-effort
        }

        emit ModuleUninstalled(moduleTypeId, module);
    }

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
        _enforceGuard(value, ALG_ECDSA, bytes32(0), target, data, false);

        returnData = new bytes[](1);
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) { assembly { revert(add(result, 32), mload(result)) } }
        returnData[0] = result;
    }
}
