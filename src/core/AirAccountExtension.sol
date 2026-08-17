// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAgentStorageLayout} from "./AAStarAgentStorageLayout.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAirAccountAgent} from "../interfaces/IAirAccountAgent.sol";
import {IERC8004IdentityRegistry} from "../interfaces/IERC8004IdentityRegistry.sol";
import {IERC8004ReputationRegistry} from "../interfaces/IERC8004ReputationRegistry.sol";
import {ERC8004Addresses} from "../config/ERC8004Addresses.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {WebAuthnLib} from "../utils/WebAuthnLib.sol";
import {P256} from "solady/utils/P256.sol";

/// @title AirAccountExtension — cold-function facet for AAStarAirAccountV7 (diamond-lite)
/// @notice Holds the cold, loosely-coupled functions that were split out of AAStarAirAccountBase
///         to keep the account under EIP-170's 24,576-byte runtime limit:
///           - ERC-8004 agent identity / reputation / wallet binding
///           - weighted-signature config governance (setWeightConfig + change proposal flow)
///         Deployed once (singleton) per implementation; the account reaches it via fallback +
///         delegatecall, so all logic runs in the ACCOUNT's storage/context: msg.sender,
///         address(this), owner, guardians, events and reverts are exactly as if inline.
/// @dev This contract is NEVER used as a standalone account — its own storage is irrelevant; it
///      only executes under delegatecall. Errors/events/constants are redeclared here with the
///      SAME signatures as AAStarAirAccountBase, so selectors / topic0 (and therefore on-chain
///      behavior and test expectations) are identical to the previous inline implementation.
contract AirAccountExtension is AAStarAgentStorageLayout, IAirAccountAgent {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants (mirror AAStarAirAccountBase) ─────────────────────────
    uint256 internal constant WEIGHT_CHANGE_TIMELOCK  = 2 days;
    uint256 internal constant WEIGHT_CHANGE_THRESHOLD = 2;
    uint256 internal constant WEIGHT_CHANGE_EXPIRY    = 30 days;
    /// @dev CC-102 F-W5/F-W7: timelock on the bootstrap guardian add that reaches RECOVERY_THRESHOLD
    ///      (mirror AAStarAirAccountBase — the P256 twin path lives in this contract).
    uint256 internal constant GUARDIAN_ADD_TIMELOCK   = 2 days;

    // Guardian-signed domain version (mirror AAStarAirAccountBase, issue #84).
    uint8 internal constant GUARDIAN_SIG_VERSION = 4;

    // ERC-7579 module type IDs (mirror AAStarAirAccountV7): 1=validator, 2=executor, 4=hook.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;
    uint256 internal constant MODULE_TYPE_HOOK      = 4;

    // ERC-7579 onInstall(bytes) lifecycle selector (mirror AAStarAirAccountV7).
    bytes4 private constant SEL_ON_INSTALL   = 0x6d61fe70;
    bytes4 private constant SEL_ON_UNINSTALL = 0x8a91b0e3;

    /// @dev KI-6 (#58): distinct guardian sigs (alongside owner) for the immediate-install bypass and
    ///      for weakening the timelock — owner+2 strictly exceeds the owner+1 default install threshold.
    uint8 internal constant MODULE_INSTALL_BYPASS_SIGS = 2;

    /// @dev KI-6 (#58): upper bound on the configurable module-install timelock. Caps griefing /
    ///      fat-finger lockouts and keeps proposedAt + timelock well within uint40.
    uint256 internal constant MAX_MODULE_INSTALL_TIMELOCK = 30 days;

    /// @dev KI-6 (#58): grace window after `executeAfter` during which a matured proposal stays
    ///      executable. Past `executeAfter + grace` it expires and must be re-proposed (mirrors the
    ///      30-day expiry on weight-change proposals), so a stale proposal can't linger forever.
    uint256 internal constant MODULE_INSTALL_PROPOSAL_GRACE = 30 days;

    // ─── Errors (same signatures/selectors as AAStarAirAccountBase) ──────
    error NotOwner();
    error Reentrancy();
    error InvalidGuardian();
    error NotGuardian();
    error AgentRegistrationFailed();
    error IdentityRegistrationFailed();
    error UnauthorizedRegistry();
    error RecoveryAlreadyActive();
    error InsecureWeightConfig();
    error WeakeningRequiresProposal();
    error WeightChangePending();
    error NoWeightChangeProposal();
    error WeightChangeAlreadyApproved();
    error WeightChangeNotApproved();
    error WeightChangeTimelockNotExpired();
    // ── Module management (same selectors as AAStarAirAccountBase) ──
    error NotOwnerOrEntryPoint();
    error ModuleInvalid();
    error InvalidModuleType();
    error ModuleAlreadyInstalled();
    error InstallModuleUnauthorized();
    error ModuleInstallCallbackFailed(uint256 moduleTypeId, address module);
    error ModuleNotInstalled();
    // ── KI-6 (#58) module-install timelock ──
    error ModuleInstallTimelockDisabled();
    error ModuleInstallTimelockTooLong();
    error ModuleInstallProposalExists();
    error NoModuleInstallProposal();
    error ModuleInstallTimelockNotExpired();
    error ModuleInstallProposalExpired();
    error ModuleInstallAuthChanged();
    error ModuleInstallDataMismatch();

    // ─── Events (same signatures/topic0 as AAStarAirAccountBase) ─────────
    event AgentWalletSet(uint256 indexed agentId, address indexed agentWallet, address agentRegistry);
    event AgentIdentityMinted(uint256 indexed agentId, address indexed identityRegistry, string agentURI);
    event ERC8004WalletBound(uint256 indexed agentId, address indexed agentWallet, address indexed identityRegistry);
    event AgentReputationSubmitted(uint256 indexed agentId, address indexed reputationRegistry, int128 value, string tag1);
    event WeightConfigUpdated(WeightConfig config);
    event WeightChangeProposed(WeightConfig proposed, address indexed proposedBy);
    event WeightChangeApproved(address indexed approvedBy, uint256 approvalCount);
    event WeightChangeExecuted(WeightConfig oldConfig, WeightConfig newConfig);
    event WeightChangeCancelled();
    // ModuleInstalled mirrors AAStarAirAccountBase so tooling sees a consistent topic0 whether a
    // module was installed immediately or via the timelock flow.
    event ModuleInstalled(uint256 indexed moduleTypeId, address indexed module);
    event ModuleUninstalled(uint256 indexed moduleTypeId, address indexed module);
    // KI-6 (#58) module-install timelock lifecycle.
    event ModuleInstallProposed(uint256 indexed moduleTypeId, address indexed module, uint256 executeAfter);
    event ModuleInstallExecuted(uint256 indexed moduleTypeId, address indexed module);
    event ModuleInstallCancelled(uint256 indexed moduleTypeId, address indexed module, address cancelledBy);
    event ModuleInstallTimelockChanged(uint256 oldTimelock, uint256 newTimelock);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Allows the owner EOA or the account itself (self-call via execute) so that
    ///      config changes can be submitted as gasless UserOps through SuperPaymaster.
    modifier onlyOwnerOrSelf() {
        if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != entryPoint) revert NotOwnerOrEntryPoint();
        _;
    }

    /// @dev Reentrancy guard using transient storage (EIP-1153) — slot 0 matches the account's guard,
    ///      so reentrancy state is shared correctly across the fallback boundary.
    modifier nonReentrant() {
        assembly {
            if tload(0) {
                mstore(0, 0xab143c06) // Reentrancy() selector
                revert(0x1c, 4)
            }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    // ─── Shared guardian/bit helpers (mirror AAStarAirAccountBase) ───────

    function _getGuardian(uint8 i) private view returns (address) {
        if (i == 0) return _guardian0;
        if (i == 1) return _guardian1;
        return _guardian2;
    }

    function _setGuardian(uint8 i, address addr) private {
        if (i == 0) { _guardian0 = addr; return; }
        if (i == 1) { _guardian1 = addr; return; }
        _guardian2 = addr;
    }

    function _guardianIndex(address addr) private view returns (uint8) {
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == addr) return i;
        }
        revert NotGuardian();
    }

    function _popcount(uint256 x) private pure returns (uint256 count) {
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }

    /// @dev Build the eth-signed digest a guardian must sign (mirror AAStarAirAccountBase._guardianOpHash).
    function _guardianOpHash(string memory opLabel, bytes memory opData) private view returns (bytes32) {
        return keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(this), opLabel, opData
        )).toEthSignedMessageHash();
    }

    /// @dev Verify guardian signatures (ECDSA 65-byte or P-256 WebAuthn blobs) by slot index.
    ///      signerIdxs[i] = guardian slot (0–2); sigs[i] = sig blob for that guardian.
    ///      At least `count` distinct approvals are required.
    ///      Uses _verifyGuardianSigByIdx which dispatches by slot type (ECDSA vs P-256).
    function _checkGuardianSigsMixed(
        string memory opLabel,
        bytes memory opData,
        uint8[] memory signerIdxs,
        bytes[] memory sigs,
        uint8 count
    ) private view {
        if (signerIdxs.length != sigs.length) revert InstallModuleUnauthorized();
        if (signerIdxs.length < count) revert InstallModuleUnauthorized();
        uint256 bitmap;
        for (uint256 i = 0; i < signerIdxs.length; i++) {
            uint8 gIdx = signerIdxs[i];
            if (gIdx >= _guardianCount) revert InstallModuleUnauthorized();
            uint256 bit = uint256(1) << gIdx;
            if (bitmap & bit != 0) revert InstallModuleUnauthorized();
            bitmap |= bit;
            _verifyGuardianSigByIdx(gIdx, sigs[i], opLabel, opData);
        }
    }

    /// @dev Best-effort lifecycle call (onInstall/onUninstall). Return value intentionally ignored.
    function _callLifecycle(bytes4 sel, address module) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool _ok,) = module.call(abi.encodeWithSelector(sel, new bytes(0)));
        _ok;
    }

    // ─── Module Install Timelock (KI-6 / issue #58) ──────────────────────

    /// @dev Snapshot of the auth config a module-install proposal is bound to. Any change to the owner
    ///      (social recovery) or the guardian set (add/remove/replace) shifts this hash, invalidating an
    ///      in-flight proposal so it cannot be silently executed under a different signer set.
    /// @dev #120 R2 [Medium]: P-256 guardians all share the sentinel in _guardian0/1/2, so a
    ///      remove+add P-256 rotation leaves the address slots and count unchanged. The public keys
    ///      MUST therefore be folded in too, else a P-256 key swap would survive an in-flight proposal.
    function _moduleAuthHash() private view returns (bytes32) {
        return keccak256(abi.encode(
            owner, _guardian0, _guardian1, _guardian2, _guardianCount,
            _guardianP256X0, _guardianP256Y0,
            _guardianP256X1, _guardianP256Y1,
            _guardianP256X2, _guardianP256Y2
        ));
    }

    /// @notice Read the active module-install timelock (seconds). 0 = disabled (immediate installs).
    function moduleInstallTimelock() external view returns (uint256) {
        return _moduleInstallTimelock;
    }

    /// @notice Read the pending module-install proposal. proposedAt == 0 means none pending.
    /// @return module        Module contract pending install.
    /// @return moduleTypeId  1=validator, 2=executor, 4=hook.
    /// @return proposedAt    Timestamp the proposal was created.
    /// @return executeAfter  Fixed timestamp from which the proposal may be executed (immutable once set).
    /// @return initDataHash  keccak256 of the committed module init data.
    function pendingModuleInstall()
        external
        view
        returns (address module, uint8 moduleTypeId, uint40 proposedAt, uint40 executeAfter, bytes32 initDataHash)
    {
        ModuleInstallProposal memory p = _pendingModuleInstall;
        return (p.module, p.moduleTypeId, p.proposedAt, p.executeAfter, p.initDataHash);
    }

    /// @notice Configure the optional module-install timelock (issue #58 / KI-6).
    /// @dev Strengthening (increasing, or first-time set) is a direct owner action. Weakening
    ///      (reducing or disabling → 0) requires the SAME elevated owner+2-guardian consensus as the
    ///      immediate-install bypass, so a compromised owner+1-guardian pair cannot silently switch
    ///      the protection off and then install instantly. On accounts with fewer than 2 guardians the
    ///      weakening bar degrades to all available guardians (mirrors uninstallModule's min(count,2)),
    ///      so the timelock can never become permanently un-removable.
    /// @param newTimelock  New timelock in seconds (0 disables). Capped at MAX_MODULE_INSTALL_TIMELOCK
    ///        (30 days); larger values revert ModuleInstallTimelockTooLong.
    /// @param guardianSigs abi.encode(uint8[] signerIdxs, bytes[] sigs) over
    ///        ("SET_MODULE_TIMELOCK", abi.encode(newTimelock, moduleManagementNonce)).
    ///        Ignored (may be empty) when strengthening.
    function setModuleInstallTimelock(uint256 newTimelock, bytes calldata guardianSigs)
        external
        onlyOwnerOrEntryPoint
    {
        if (newTimelock > MAX_MODULE_INSTALL_TIMELOCK) revert ModuleInstallTimelockTooLong();
        uint256 current = _moduleInstallTimelock;
        if (newTimelock < current) {
            uint8 sigsRequired =
                _guardianCount < MODULE_INSTALL_BYPASS_SIGS ? _guardianCount : MODULE_INSTALL_BYPASS_SIGS;
            (uint8[] memory signerIdxs, bytes[] memory sigs) = abi.decode(guardianSigs, (uint8[], bytes[]));
            _checkGuardianSigsMixed(
                "SET_MODULE_TIMELOCK",
                abi.encode(newTimelock, _moduleManagementNonce),
                signerIdxs, sigs, sigsRequired
            );
            // Consume the guardian signatures so they cannot be replayed (shared monotonic nonce, #75).
            unchecked { _moduleManagementNonce++; }
        }
        _moduleInstallTimelock = newTimelock;
        emit ModuleInstallTimelockChanged(current, newTimelock);
    }

    /// @notice Propose a module install for the timelocked two-step flow (issue #58 / KI-6).
    /// @dev Only valid when the timelock is enabled. Requires the SAME authorization as a normal
    ///      install at the configured threshold (owner + N guardian sigs); the guardian signature is
    ///      consumed via the module-management nonce so it cannot be replayed. After the timelock
    ///      elapses anyone may call executeModuleInstall; meanwhile owner or any guardian may cancel.
    /// @param moduleTypeId 1=validator, 2=executor, 4=hook.
    /// @param module       Module contract address (must be deployed).
    /// @param initData     When sigsRequired > 0: abi.encode(signerIdxs, sigs, moduleInitData).
    ///        When sigsRequired == 0: raw module init data.
    ///        Op: "INSTALL_MODULE", opData: abi.encode(moduleTypeId, module, keccak256(moduleInitData), nonce).
    function proposeModuleInstall(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external onlyOwnerOrEntryPoint {
        uint256 timelock = _moduleInstallTimelock;
        if (timelock == 0) revert ModuleInstallTimelockDisabled();
        // A still-live proposal blocks a new one; an EXPIRED proposal (past its grace) may be overwritten
        // so a lapsed proposal can simply be re-proposed without a separate cancel.
        ModuleInstallProposal memory existing = _pendingModuleInstall;
        if (existing.proposedAt != 0
            && block.timestamp <= uint256(existing.executeAfter) + MODULE_INSTALL_PROPOSAL_GRACE) {
            revert ModuleInstallProposalExists();
        }
        if (module == address(0) || module.code.length == 0) revert ModuleInvalid();
        if (moduleTypeId != MODULE_TYPE_VALIDATOR
            && moduleTypeId != MODULE_TYPE_EXECUTOR
            && moduleTypeId != MODULE_TYPE_HOOK) revert InvalidModuleType();
        if (_installedModules[moduleTypeId][module]) revert ModuleAlreadyInstalled();
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook != address(0)) revert ModuleAlreadyInstalled();

        uint8 threshold = _installModuleThreshold == 0 ? 70 : _installModuleThreshold;
        uint8 sigsRequired = threshold >= 100 ? 2 : (threshold >= 70 ? 1 : 0);

        bytes memory moduleInitData;
        if (sigsRequired > 0) {
            (uint8[] memory signerIdxs, bytes[] memory sigs, bytes memory _mInitData) =
                abi.decode(initData, (uint8[], bytes[], bytes));
            _checkGuardianSigsMixed(
                "INSTALL_MODULE",
                abi.encode(moduleTypeId, module, keccak256(_mInitData), _moduleManagementNonce),
                signerIdxs, sigs, sigsRequired
            );
            moduleInitData = _mInitData;
        } else {
            moduleInitData = initData;
        }

        // executeAfter is FIXED here (timelock bounded to 30 days, so block.timestamp + timelock is well
        // within uint40 for millennia). A later setModuleInstallTimelock cannot move this proposal's window.
        uint40 executeAfter = uint40(block.timestamp + timelock);

        _pendingModuleInstall = ModuleInstallProposal({
            module: module,
            moduleTypeId: uint8(moduleTypeId),
            proposedAt: uint40(block.timestamp),
            executeAfter: executeAfter,
            initDataHash: keccak256(moduleInitData),
            authHash: _moduleAuthHash()
        });

        // #75: consume the guardian signature so this proposal cannot be replayed.
        unchecked { _moduleManagementNonce++; }

        emit ModuleInstallProposed(moduleTypeId, module, executeAfter);
    }

    /// @notice Execute a matured module-install proposal (issue #58 / KI-6).
    /// @dev Permissionless (like executeRecovery) — authorization was captured at propose time and the
    ///      timelock window has elapsed. The caller must reproduce the exact module init data that was
    ///      proposed (its keccak256 must match the stored hash) so onInstall receives the authorized config.
    /// @param moduleInitData The module init data committed at propose time.
    function executeModuleInstall(bytes calldata moduleInitData) external nonReentrant {
        ModuleInstallProposal memory p = _pendingModuleInstall;
        if (p.proposedAt == 0) revert NoModuleInstallProposal();
        // Compare against the FIXED executeAfter captured at propose time (not a re-derived deadline).
        if (block.timestamp < uint256(p.executeAfter)) revert ModuleInstallTimelockNotExpired();
        // A proposal that has sat past its grace window expires and must be re-proposed.
        if (block.timestamp > uint256(p.executeAfter) + MODULE_INSTALL_PROPOSAL_GRACE) {
            revert ModuleInstallProposalExpired();
        }
        // The proposal is bound to the auth config (owner + guardians) as it was at propose time. If the
        // owner was replaced via social recovery, or any guardian was added/removed/changed during the
        // window, the snapshot no longer matches — reject so a new signer set must re-authorize.
        if (_moduleAuthHash() != p.authHash) revert ModuleInstallAuthChanged();
        if (keccak256(moduleInitData) != p.initDataHash) revert ModuleInstallDataMismatch();

        uint256 moduleTypeId = p.moduleTypeId;
        address module = p.module;

        // The module could have selfdestructed during the window — re-validate it is still deployed.
        if (module == address(0) || module.code.length == 0) revert ModuleInvalid();
        if (_installedModules[moduleTypeId][module]) revert ModuleAlreadyInstalled();
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook != address(0)) revert ModuleAlreadyInstalled();

        bool alreadyLive = _installedModules[MODULE_TYPE_VALIDATOR][module]
                        || _installedModules[MODULE_TYPE_EXECUTOR][module]
                        || _installedModules[MODULE_TYPE_HOOK][module];

        _installedModules[moduleTypeId][module] = true;
        if (moduleTypeId == MODULE_TYPE_HOOK) _activeHook = module;

        // Effects before interaction: clear the proposal so a re-entrant onInstall cannot replay it.
        delete _pendingModuleInstall;

        if (!alreadyLive) {
            // Hard-revert if onInstall fails (mirror installModule MEDIUM-1) — a revert rolls back the
            // install marks AND the proposal deletion atomically, leaving no stuck state.
            (bool ok,) = module.call(abi.encodeWithSelector(SEL_ON_INSTALL, moduleInitData));
            if (!ok) revert ModuleInstallCallbackFailed(moduleTypeId, module);
        }

        emit ModuleInstalled(moduleTypeId, module);
        emit ModuleInstallExecuted(moduleTypeId, module);
    }

    /// @notice Cancel the pending module-install proposal during the timelock window (issue #58 / KI-6).
    /// @dev Owner OR any single guardian may veto. The timelock exists precisely to let ANY other
    ///      stakeholder stop an install pushed through by a compromised owner+1-guardian pair, so a
    ///      single honest party must be able to cancel. This deliberately mirrors cancelWeightChange
    ///      (owner-or-any-guardian) rather than the 2-of-3 cancelRecovery: recovery's higher cancel bar
    ///      stops a lone compromised guardian from blocking legitimate recovery, but here easy
    ///      cancellation IS the defense, so the looser rule is the safer one.
    function cancelModuleInstall() external {
        ModuleInstallProposal memory p = _pendingModuleInstall;
        if (p.proposedAt == 0) revert NoModuleInstallProposal();
        if (msg.sender != owner) {
            _guardianIndex(msg.sender); // reverts NotGuardian if msg.sender is neither owner nor guardian
        }
        delete _pendingModuleInstall;
        emit ModuleInstallCancelled(p.moduleTypeId, p.module, msg.sender);
    }

    // ─── ERC-7579 Module Management (install / uninstall) ────────────────

    /// @notice ERC-7579: Install a module. Supports both ECDSA and P-256 guardian multi-sig.
    /// @param moduleTypeId 1=Validator, 2=Executor, 4=Hook.
    /// @param module Module contract address (must be deployed).
    /// @param initData When sigsRequired > 0: abi.encode(uint8[] signerIdxs, bytes[] sigs, bytes moduleInitData).
    ///   When sigsRequired == 0: raw module init data.
    ///   Op: "INSTALL_MODULE", opData: abi.encode(moduleTypeId, module, keccak256(moduleInitData), nonce).
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

        // KI-6 (#58): when the optional install timelock is enabled, the immediate-install path
        // demands the elevated owner+2-guardian bypass authorization.
        if (_moduleInstallTimelock != 0 && sigsRequired < MODULE_INSTALL_BYPASS_SIGS) {
            sigsRequired = MODULE_INSTALL_BYPASS_SIGS;
        }

        bytes memory moduleInitData;
        if (sigsRequired > 0) {
            (uint8[] memory signerIdxs, bytes[] memory sigs, bytes memory _mInitData) =
                abi.decode(initData, (uint8[], bytes[], bytes));
            _checkGuardianSigsMixed(
                "INSTALL_MODULE",
                abi.encode(moduleTypeId, module, keccak256(_mInitData), _moduleManagementNonce),
                signerIdxs, sigs, sigsRequired
            );
            moduleInitData = _mInitData;
        } else {
            moduleInitData = initData;
        }

        if (_installedModules[moduleTypeId][module]) revert ModuleAlreadyInstalled();
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook != address(0)) revert ModuleAlreadyInstalled();

        // MEDIUM-2: Only call onInstall on the first installation of this module address.
        bool alreadyLive = _installedModules[MODULE_TYPE_VALIDATOR][module]
                        || _installedModules[MODULE_TYPE_EXECUTOR][module]
                        || _installedModules[MODULE_TYPE_HOOK][module];

        _installedModules[moduleTypeId][module] = true;
        if (moduleTypeId == MODULE_TYPE_HOOK) _activeHook = module;

        if (!alreadyLive) {
            // MEDIUM-1: Hard-revert if onInstall fails.
            (bool _ok,) = module.call(abi.encodeWithSelector(SEL_ON_INSTALL, moduleInitData));
            if (!_ok) revert ModuleInstallCallbackFailed(moduleTypeId, module);
        }

        // #75: advance the nonce so this guardian signature cannot be replayed after uninstall.
        unchecked { _moduleManagementNonce++; }

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @notice ERC-7579: Uninstall a module. Supports both ECDSA and P-256 guardian multi-sig.
    /// @dev Requires min(guardianCount, 2) guardian sigs.
    ///      deInitData: abi.encode(uint8[] signerIdxs, bytes[] sigs).
    ///      Op: "UNINSTALL_MODULE", opData: abi.encode(moduleTypeId, module, nonce).
    /// @dev **0-guardian accounts**: when guardianCount == 0, sigsRequired degrades to 0 and the
    ///      owner/EntryPoint can uninstall without any guardian signatures. This is intentional —
    ///      a module installed on a 0-guardian account is protected only by the owner key, which is
    ///      the same security model as every other operation on such an account. Accounts that require
    ///      guardian-gated module removal must configure at least one guardian.
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external onlyOwnerOrEntryPoint {
        if (moduleTypeId != MODULE_TYPE_VALIDATOR
            && moduleTypeId != MODULE_TYPE_EXECUTOR
            && moduleTypeId != MODULE_TYPE_HOOK) revert InvalidModuleType();

        uint8 sigsRequired = _guardianCount < 2 ? _guardianCount : 2;

        (uint8[] memory signerIdxs, bytes[] memory sigs) = abi.decode(deInitData, (uint8[], bytes[]));
        _checkGuardianSigsMixed(
            "UNINSTALL_MODULE",
            abi.encode(moduleTypeId, module, _moduleManagementNonce),
            signerIdxs, sigs, sigsRequired
        );

        if (!_installedModules[moduleTypeId][module]) revert ModuleNotInstalled();
        _installedModules[moduleTypeId][module] = false;
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook == module) _activeHook = address(0);

        // MEDIUM-2: Only call onUninstall when this is the last active installation.
        bool stillLive = _installedModules[MODULE_TYPE_VALIDATOR][module]
                      || _installedModules[MODULE_TYPE_EXECUTOR][module]
                      || _installedModules[MODULE_TYPE_HOOK][module];
        if (!stillLive) {
            _callLifecycle(SEL_ON_UNINSTALL, module);
        }

        // #75: advance the nonce so this guardian signature cannot be replayed on reinstall.
        unchecked { _moduleManagementNonce++; }

        emit ModuleUninstalled(moduleTypeId, module);
    }

    // ─── ERC-8004 Agent Identity Binding (M7.16) ─────────────────────────

    /// @notice Link an agent wallet to this AirAccount by registering it in AgentRegistry.
    function setAgentWallet(
        uint256 agentId,
        address agentWallet,
        address agentRegistry,
        bytes calldata agentWalletSig
    ) external onlyOwner {
        if (agentWallet == address(0) || agentRegistry == address(0)) revert InvalidGuardian();
        uint256 codeSize;
        assembly { codeSize := extcodesize(agentRegistry) }
        if (codeSize == 0) revert AgentRegistrationFailed();
        (bool ok,) = agentRegistry.call(
            abi.encodeWithSignature("registerAgent(address,bytes)", agentWallet, agentWalletSig)
        );
        if (!ok) revert AgentRegistrationFailed();
        emit AgentWalletSet(agentId, agentWallet, agentRegistry);
    }

    /// @dev Pin a registry argument to the official ERC-8004 deployment for this chain.
    function _requireOfficialIdentityRegistry(address r) private view {
        if (r != ERC8004Addresses.identityRegistry(block.chainid)) revert UnauthorizedRegistry();
    }

    function _requireOfficialReputationRegistry(address r) private view {
        if (r != ERC8004Addresses.reputationRegistry(block.chainid)) revert UnauthorizedRegistry();
    }

    /// @notice Mint an ERC-8004 agent identity NFT to this AirAccount via the official registry.
    function mintAgentIdentity(
        address identityRegistry,
        string calldata agentURI
    ) external onlyOwner nonReentrant returns (uint256 agentId) {
        _requireOfficialIdentityRegistry(identityRegistry);
        agentId = IERC8004IdentityRegistry(identityRegistry).register(agentURI);
        emit AgentIdentityMinted(agentId, identityRegistry, agentURI);
    }

    /// @notice Bind an execution wallet to an ERC-8004 agent identity NFT.
    function bindERC8004AgentWallet(
        address identityRegistry,
        uint256 agentId,
        address agentWallet,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOwner nonReentrant {
        _requireOfficialIdentityRegistry(identityRegistry);
        if (agentWallet == address(0)) revert IdentityRegistrationFailed();
        IERC8004IdentityRegistry(identityRegistry).setAgentWallet(agentId, agentWallet, deadline, signature);
        emit ERC8004WalletBound(agentId, agentWallet, identityRegistry);
    }

    /// @notice Submit reputation feedback for an agent interaction via the official registry.
    function submitAgentReputation(
        address reputationRegistry,
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external onlyOwner nonReentrant {
        _requireOfficialReputationRegistry(reputationRegistry);
        IERC8004ReputationRegistry(reputationRegistry).giveFeedback(
            agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash
        );
        emit AgentReputationSubmitted(agentId, reputationRegistry, value, tag1);
    }

    /// @notice Query aggregated reputation for an agent across a set of clients.
    function queryAgentReputation(
        address reputationRegistry,
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryDecimals) {
        _requireOfficialReputationRegistry(reputationRegistry);
        return IERC8004ReputationRegistry(reputationRegistry).getSummary(
            agentId, clientAddresses, tag1, tag2
        );
    }

    // ─── Weighted Signature Management (M6.1 + M6.2) ─────────────────────

    /// @notice Set the weight configuration for algId 0x07. First-time: direct owner call.
    ///         Subsequent weakening changes require the guardian proposal flow (M6.2).
    function setWeightConfig(WeightConfig calldata config) external onlyOwnerOrSelf {
        _validateWeightConfig(config);

        WeightConfig memory current = weightConfig;
        if (current.tier1Threshold != 0 && _isWeakening(current, config)) {
            revert WeakeningRequiresProposal();
        }
        if (pendingWeightChange.proposedAt != 0) revert WeightChangePending();

        weightConfig = config;
        emit WeightConfigUpdated(config);
    }

    /// @notice Propose a weakening weight-config change (guardian-gated, M6.2).
    function proposeWeightChange(WeightConfig calldata proposed) external onlyOwner {
        _validateWeightConfig(proposed);
        if (!_isWeakening(weightConfig, proposed)) revert WeakeningRequiresProposal();
        if (pendingWeightChange.proposedAt != 0) revert WeightChangePending();
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();

        pendingWeightChange = WeightChangeProposal({
            proposed: proposed,
            proposedAt: block.timestamp,
            approvalBitmap: 0
        });
        emit WeightChangeProposed(proposed, msg.sender);
    }

    /// @notice Guardian approves the pending weight-change proposal.
    function approveWeightChange() external {
        if (pendingWeightChange.proposedAt == 0) revert NoWeightChangeProposal();
        if (block.timestamp > pendingWeightChange.proposedAt + WEIGHT_CHANGE_EXPIRY) revert NoWeightChangeProposal();

        uint8 guardianIndex = _guardianIndex(msg.sender);
        uint256 bit = uint256(1) << guardianIndex;
        if (pendingWeightChange.approvalBitmap & bit != 0) revert WeightChangeAlreadyApproved();

        pendingWeightChange.approvalBitmap |= bit;
        uint256 count = _popcount(pendingWeightChange.approvalBitmap);
        emit WeightChangeApproved(msg.sender, count);
    }

    /// @notice Execute an approved weight-change after timelock and threshold are met.
    function executeWeightChange() external {
        WeightChangeProposal memory p = pendingWeightChange;
        if (p.proposedAt == 0) revert NoWeightChangeProposal();
        if (block.timestamp > p.proposedAt + WEIGHT_CHANGE_EXPIRY) revert NoWeightChangeProposal();
        if (_popcount(p.approvalBitmap) < WEIGHT_CHANGE_THRESHOLD) revert WeightChangeNotApproved();
        if (block.timestamp < p.proposedAt + WEIGHT_CHANGE_TIMELOCK) revert WeightChangeTimelockNotExpired();

        WeightConfig memory oldConfig = weightConfig;
        weightConfig = p.proposed;
        delete pendingWeightChange;
        emit WeightChangeExecuted(oldConfig, p.proposed);
        emit WeightConfigUpdated(p.proposed);
    }

    /// @notice Cancel a pending weight-change proposal. Owner or any guardian can cancel.
    function cancelWeightChange() external {
        if (pendingWeightChange.proposedAt == 0) revert NoWeightChangeProposal();
        if (msg.sender != owner) {
            _guardianIndex(msg.sender);
        }
        delete pendingWeightChange;
        emit WeightChangeCancelled();
    }

    /// @dev Validate that a WeightConfig is internally consistent and secure.
    function _validateWeightConfig(WeightConfig calldata config) private pure {
        if (config.tier1Threshold == 0) revert InsecureWeightConfig();
        if (config.passkeyWeight   >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.ecdsaWeight     >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.blsWeight       >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian0Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian1Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian2Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.tier2Threshold != 0 && config.tier2Threshold < config.tier1Threshold) revert InsecureWeightConfig();
        if (config.tier3Threshold != 0 && config.tier3Threshold < config.tier2Threshold) revert InsecureWeightConfig();
        if (config.tier3Threshold != 0 && config.tier2Threshold == 0) revert InsecureWeightConfig();
        // Security fix "b" (Codex): the owner controls BOTH the device passkey (P256) and the KMS ECDSA
        // key in the TEE model, so {passkey, ecdsa} is the OWNER-ALONE signer subset. It may satisfy the
        // lower tiers, but MUST NOT reach Tier-3 (the highest-value, multi-sig tier), which is meant to
        // require an EXTERNAL factor (DVT BLS and/or a guardian). Without this, a compromised owner could
        // set a config — including a FIRST-TIME config, which bypasses the _isWeakening guardian gate —
        // where passkey+ecdsa alone accumulate into Tier-3. Enforced in _validateWeightConfig so it holds
        // for both setWeightConfig and proposeWeightChange. Sum in uint16 (max 2*255) to avoid overflow.
        if (config.tier3Threshold != 0 &&
            uint16(config.passkeyWeight) + uint16(config.ecdsaWeight) >= config.tier3Threshold) {
            revert InsecureWeightConfig();
        }
        // CC-102 F-W11: bound the SUM of all factor weights to uint8 max. `_validateWeightedSignature`
        // accumulates matched factors into a `uint8` with checked arithmetic; a config whose weights sum to
        // > 255 (each still `< tier1Threshold`, so the per-weight checks above pass) would Panic(0x11)-revert
        // INSIDE validateUserOp once enough factors sign — a validation-phase revert, violating the repo's
        // revert-free rule (ERC-7562 / fix M-C: return 1, never revert). Cap the max reachable accumulator.
        if (uint16(config.passkeyWeight) + uint16(config.ecdsaWeight) + uint16(config.blsWeight)
            + uint16(config.guardian0Weight) + uint16(config.guardian1Weight) + uint16(config.guardian2Weight)
            > 255) {
            revert InsecureWeightConfig();
        }
    }

    /// @dev Returns true if proposed config is a weakening of current config.
    /// @dev A change is "weakening" (→ requires the guardian proposal flow) when it makes a tier EASIER
    ///      to reach for a given signer subset. Two directions do that:
    ///        - RAISING any factor weight  → that factor contributes more → threshold reached sooner.
    ///        - LOWERING any tier threshold → less accumulated weight needed.
    ///      Security fix "b": the weight checks previously used `<` (flagging DECREASES), which is
    ///      backwards — lowering a weight is a STRENGTHENING. A compromised owner could therefore RAISE
    ///      passkey/ecdsa weights (each still `< tier1Threshold`, so `_validateWeightConfig` passes) via
    ///      the direct `onlyOwnerOrSelf` `setWeightConfig`, with NO guardian consent, and make an
    ///      owner-only signer subset accumulate into Tier-3. Flagging weight INCREASES closes that.
    ///      (Lowering a weight or raising a threshold is a strengthening → allowed directly.)
    function _isWeakening(WeightConfig memory current, WeightConfig memory proposed) private pure returns (bool) {
        if (proposed.passkeyWeight   > current.passkeyWeight)   return true;
        if (proposed.ecdsaWeight     > current.ecdsaWeight)     return true;
        if (proposed.blsWeight       > current.blsWeight)       return true;
        if (proposed.guardian0Weight > current.guardian0Weight) return true;
        if (proposed.guardian1Weight > current.guardian1Weight) return true;
        if (proposed.guardian2Weight > current.guardian2Weight) return true;
        if (proposed.tier1Threshold  < current.tier1Threshold)  return true;
        if (proposed.tier2Threshold  < current.tier2Threshold)  return true;
        if (proposed.tier3Threshold  < current.tier3Threshold)  return true;
        // CC-102 F-W6: ENABLING a previously-disabled higher tier (tier2/tier3 0 → N) is a weakening — it
        // makes a tier reachable that `_resolveWeightedAlgId` gated off (the `tierN > 0` guard), handing
        // whatever signer subset already sums past N a level that was unreachable. Route it through the
        // guardian proposal flow, not a direct owner set. NOTE: `_isWeakening` is reached from BOTH
        // setWeightConfig (which pre-gates on `current.tier1Threshold != 0`) AND proposeWeightChange (no
        // init gate), so `current` may be all-zero here — harmless (an all-zero `current` makes every
        // enable return true, the correct direction), but do NOT assume `current` is initialised.
        if (current.tier2Threshold == 0 && proposed.tier2Threshold != 0) return true;
        if (current.tier3Threshold == 0 && proposed.tier3Threshold != 0) return true;
        return false;
    }

    // ─── P-256 Guardian Support (issue #119) ─────────────────────────────

    /// @dev secp256r1 curve order / 2 for low-S canonicality (mirror AAStarAirAccountBase)
    uint256 private constant SECP256R1_N_OVER_2 =
        0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8;

    /// @dev Sentinel address indicating a P-256 guardian slot (mirror AAStarAirAccountBase)
    address private constant P256_GUARDIAN_SENTINEL = address(0x7026);

    uint256 private constant RECOVERY_THRESHOLD = 2;
    uint256 private constant RECOVERY_TIMELOCK = 2 days;

    // Errors (same selectors as AAStarAirAccountBase)
    error MaxGuardiansReached();
    error RecoveryTimelockNotExpired();
    error RecoveryNotApproved();
    error GuardianAlreadySet();
    error InvalidP256GuardianKey();
    error DuplicateP256GuardianKey();
    error InvalidP256GuardianSignature(uint8 gIdx);
    error InvalidGuardianSignature();
    error NoActiveRecovery();
    error RecoveryAlreadyProposed();
    error AlreadyApproved();
    error AlreadyCancelVoted();
    error InvalidNewOwner();
    error DuplicateGuardianSig();
    error InsufficientGuardianApprovals();
    error MinGuardianRequired();
    error TierLimitSigExpired();
    error InvalidTierConfig();
    error CannotIncreaseTierLimit();
    error UseGuardianConsensus();
    error GuardianAdditionNotProposed();
    error GuardianAdditionTimelockNotExpired();
    error InvalidAuthenticatorData();

    // Events (same selectors as AAStarAirAccountBase)
    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event GuardianAdditionProposed(address indexed guardian, uint256 executeAfter);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event P256GuardianAdded(uint8 indexed index, bytes32 x, bytes32 y);
    // guardianIdx (review #120 follow-up): the WithSig paths are submitted by a relayer, so
    // msg.sender (proposedBy/approvedBy/votedBy) is NOT the authorizing guardian. guardianIdx
    // names the actual guardian slot whose signature (P-256) or msg.sender (ECDSA) authorized
    // the op, so off-chain forensics can answer "which guardian acted" without decoding calldata.
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy, uint8 guardianIdx);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount, uint8 guardianIdx);
    event RecoveryCancelVoted(address indexed votedBy, uint256 cancelCount, uint8 guardianIdx);
    event RecoveryCancelled();
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event TierLimitsSet(uint256 tier1, uint256 tier2);

    // ── P-256 key storage helpers (mirror AAStarAirAccountBase, access same delegatecall slots) ──

    function _isP256Guardian(uint8 i) private view returns (bool) {
        return _getGuardian(i) == P256_GUARDIAN_SENTINEL;
    }

    /// @dev Compute the operation challenge (keccak_hash) that becomes the WebAuthn challenge.
    ///      The SDK passes this as the challenge to navigator.credentials.get(); the browser
    ///      base64url-encodes it into clientDataJSON before signing.
    function _p256GuardianChallenge(string memory opLabel, bytes memory opData) private view returns (bytes32) {
        return keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(this), "P256_GUARDIAN", opLabel, opData
        ));
    }

    /// @dev Base64URL-encode exactly 32 bytes (no padding). Used to reconstruct clientDataJSON.
    ///      Output is 43 characters: floor(32/3)=10 full groups → 40 chars, remaining 2 bytes → 3 chars.
    function _base64UrlEncode32(bytes32 input) private pure returns (bytes memory result) {
        result = new bytes(43);
        bytes memory data = abi.encodePacked(input);
        bytes memory t = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_");
        uint256 j = 0;
        for (uint256 i = 0; i < 30; i += 3) {
            uint256 b0 = uint8(data[i]);
            uint256 b1 = uint8(data[i + 1]);
            uint256 b2 = uint8(data[i + 2]);
            result[j++] = t[b0 >> 2];
            result[j++] = t[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j++] = t[((b1 & 0x0F) << 2) | (b2 >> 6)];
            result[j++] = t[b2 & 0x3F];
        }
        // Final 2 bytes (indices 30, 31) → 3 base64url chars (no padding)
        uint256 b30 = uint8(data[30]);
        uint256 b31 = uint8(data[31]);
        result[j++] = t[b30 >> 2];
        result[j++] = t[((b30 & 0x03) << 4) | (b31 >> 4)];
        result[j]   = t[(b31 & 0x0F) << 2];
    }

    /// @dev Verify a full WebAuthn assertion for a P-256 guardian.
    ///      Reconstructs clientDataJSON = prefix || base64url(challenge) || suffix, then
    ///      verifies: P256(sha256(authenticatorData || sha256(clientDataJSON)), r, s, x, y).
    ///      This matches what navigator.credentials.get() actually produces in all browsers.
    ///
    ///      sig encoding: abi.encode(bytes authenticatorData, bytes clientDataJSONPrefix,
    ///                               bytes clientDataJSONSuffix, bytes32 r, bytes32 s)
    function _verifyWebAuthnP256Sig(uint8 gIdx, bytes32 challenge, bytes memory sig) private view {
        // Minimum encoding: 5×32 (head offsets) + 3×(32 length + 32 min-content) = 352 bytes.
        // r and s are fixed 32-byte values already counted in the head. Reject short blobs early
        // so malformed input emits InvalidP256GuardianSignature instead of a generic revert.
        if (sig.length < 352) revert InvalidP256GuardianSignature(gIdx);
        (
            bytes memory authenticatorData,
            bytes memory clientDataJSONPrefix,
            bytes memory clientDataJSONSuffix,
            bytes32 r,
            bytes32 s
        ) = abi.decode(sig, (bytes, bytes, bytes, bytes32, bytes32));

        // Minimum authenticatorData: rpIdHash(32) + flags(1) + signCount(4) = 37 bytes
        if (authenticatorData.length < 37) revert InvalidAuthenticatorData();
        // UP (User Present) flag must be set (bit 0 of byte 32)
        if (uint8(authenticatorData[32]) & 0x01 == 0) revert InvalidAuthenticatorData();

        // #120 R1 [Medium]: bind the WebAuthn operation TYPE. clientDataJSONPrefix must be exactly
        // the standard assertion preamble, so a relayer cannot supply arbitrary JSON or replay a
        // webauthn.create (registration) assertion through the webauthn.get (recovery) path. All
        // major platform authenticators (iOS/macOS Safari, Android/Chrome, Windows Hello) emit
        // clientDataJSON with `type` first and `challenge` immediately after, in this exact form.
        // NOTE: origin / rpIdHash are intentionally NOT bound on-chain — the platform enforces RP
        // binding (a passkey only signs under its own rpId's origin) and the challenge is already
        // domain-separated (chainId + account + nonce + newOwner). Same stance as webauthn-sol /
        // Coinbase Smart Wallet. See docs/p256-guardian-spec.md.
        if (keccak256(clientDataJSONPrefix) != keccak256(bytes('{"type":"webauthn.get","challenge":"'))) {
            revert InvalidAuthenticatorData();
        }

        // Reconstruct clientDataJSON from parts around the challenge
        bytes memory clientDataJSON = abi.encodePacked(
            clientDataJSONPrefix,
            _base64UrlEncode32(challenge),
            clientDataJSONSuffix
        );

        // WebAuthn: signed payload = authenticatorData || sha256(clientDataJSON)
        // Signing algorithm is ECDSA-SHA-256, so precompile receives sha256 of that payload
        bytes32 clientDataHash = sha256(clientDataJSON);
        bytes32 payloadHash    = sha256(abi.encodePacked(authenticatorData, clientDataHash));

        if (uint256(s) > SECP256R1_N_OVER_2) revert InvalidP256GuardianSignature(gIdx);
        (bytes32 px, bytes32 py) = _getP256Key(gIdx);
        // #191: raw precompile → Solady P256 (single audited primitive; same 0x100 on OP → byte-identical
        // revert behavior). Low-S enforced above; the WebAuthn wrapper (base64url/clientDataJSON) and this
        // path's distinct revert semantics are unchanged (only the primitive call is deduplicated).
        if (!P256.verifySignatureAllowMalleability(payloadHash, r, s, px, py)) {
            revert InvalidP256GuardianSignature(gIdx);
        }
    }

    /// @dev Verify a WebAuthn assertion against the OWNER passkey (p256KeyX / p256KeyY), returning bool.
    ///      Powers isValidOwnerAuth's WebAuthn branch (issue #159). MUST stay byte-for-byte identical to
    ///      AAStarAirAccountBase._verifyWebAuthnOwnerSig (the on-chain UserOp owner-WebAuthn path) so an
    ///      off-chain eth_call to isValidOwnerAuth and the on-chain validateUserOp path never diverge —
    ///      that non-divergence is the whole point of exposing this view (single source of truth).
    ///      Fail-closed: returns false (never reverts) on malformed input, so the caller gets 0xffffffff.
    ///      sig encoding: abi.encode(bytes authenticatorData, bytes clientDataJSONPrefix,
    ///                               bytes clientDataJSONSuffix, bytes32 r, bytes32 s)
    function _verifyOwnerWebAuthn(bytes32 challenge, bytes memory sig) private view returns (bool) {
        // #149: delegated to WebAuthnLib.verifyP256 — the SAME code AAStarAirAccountBase now calls, so
        // the "byte-for-byte identical to _verifyWebAuthnOwnerSig" invariant above is now STRUCTURAL
        // (one shared library), not a hand-maintained mirror. Still fail-closed (returns false, never
        // reverts) on malformed input, so isValidOwnerAuth yields 0xffffffff.
        return WebAuthnLib.verifyP256(challenge, sig, p256KeyX, p256KeyY);
    }

    /// @dev Dispatch guardian signature verification by slot type.
    ///      P-256 guardian: full WebAuthn Assertion (authenticatorData + clientDataJSON parts + r,s).
    ///      ECDSA guardian: 65-byte eth-signed keccak hash (existing format, no domain tag).
    function _verifyGuardianSigByIdx(
        uint8 gIdx,
        bytes memory sig,
        string memory opLabel,
        bytes memory opData
    ) private view {
        if (_isP256Guardian(gIdx)) {
            bytes32 challenge = _p256GuardianChallenge(opLabel, opData);
            _verifyWebAuthnP256Sig(gIdx, challenge, sig);
        } else {
            bytes32 ethHash = keccak256(abi.encode(
                GUARDIAN_SIG_VERSION, block.chainid, address(this), opLabel, opData
            )).toEthSignedMessageHash();
            address recovered = ethHash.recover(sig);
            if (recovered != _getGuardian(gIdx)) revert InvalidGuardianSignature();
        }
    }

    // ── Public functions ──────────────────────────────────────────────────

    /// @dev isValidOwnerAuth success magic = its own selector (issue #159). Deliberately NOT the
    ///      ERC-1271 magic 0x1626ba7e: this is a distinct owner-authorization primitive, and reusing
    ///      the ERC-1271 value would let a generic ERC-1271 caller mistake it for isValidSignature.
    bytes4  private constant OWNER_AUTH_MAGIC        = 0xa0cf00cf; // isValidOwnerAuth(bytes32,bytes)
    /// @dev ownerAuth type tags (issue #159): explicit 1-byte tag, never length-based discrimination.
    uint8   private constant OWNER_AUTH_TAG_ECDSA    = 0x01;
    uint8   private constant OWNER_AUTH_TAG_WEBAUTHN = 0x02;

    /// @notice ERC-1271-style owner-authorization check for a userOp, callable off-chain via eth_call.
    ///         Single source of truth for "did the account OWNER authorize this userOpHash", so a DVT
    ///         co-signer (or any relayer) can validate owner authorization WITHOUT re-implementing
    ///         ECDSA / WebAuthn verification off-chain (which would inevitably drift from this contract).
    ///         Issue #159; unblocks device-passkey Tier-3 DVT authorization.
    ///
    ///         ownerAuth = [tag(1 byte)] || payload:
    ///           tag 0x01 → payload = 65-byte ECDSA over EIP-191 personal_sign(userOpHash), recover==owner.
    ///                      NOTE the EIP-191 prefix matches the UserOp owner path (_validateECDSA), NOT the
    ///                      raw-hash ERC-1271 isValidSignature path — callers MUST personal_sign, not raw-sign.
    ///           tag 0x02 → payload = abi.encode(authenticatorData, clientDataJSONPrefix,
    ///                      clientDataJSONSuffix, bytes32 r, bytes32 s): a WebAuthn assertion over the owner
    ///                      device passkey (p256KeyX / p256KeyY), with challenge = userOpHash.
    ///
    /// @dev    SINGLE-FACTOR owner authorization: returns the magic if EITHER the owner ECDSA key OR the
    ///         owner device passkey validates. This is NOT tier-N cumulative authorization — a DVT MUST
    ///         layer its own tier policy on top and must not treat the magic as full tiered approval.
    /// @dev    Pure view (no state) for eth_call; fail-closed — any empty / short / malformed / unknown-tag
    ///         input returns 0xffffffff (never reverts), so a DVT treats non-magic uniformly as "deny".
    /// @dev    Non-upgradable account: only accounts deployed from an implementation carrying this facet
    ///         expose isValidOwnerAuth; pre-existing accounts must migrate to gain it.
    /// @param  userOpHash The exact 32-byte hash the owner authorized. The DVT MUST derive this itself and
    ///                    never trust a caller-supplied hash.
    /// @param  ownerAuth  Tagged owner-authorization blob (see above).
    /// @return 0xa0cf00cf (isValidOwnerAuth.selector) on success, 0xffffffff otherwise.
    function isValidOwnerAuth(bytes32 userOpHash, bytes calldata ownerAuth) external view returns (bytes4) {
        if (ownerAuth.length == 0) return 0xffffffff;
        uint8 tag = uint8(ownerAuth[0]);

        if (tag == OWNER_AUTH_TAG_ECDSA) {
            // 1 tag byte + 65-byte ECDSA signature.
            if (ownerAuth.length != 66) return 0xffffffff;
            address o = owner;
            if (o == address(0)) return 0xffffffff;
            // Mirror AAStarAirAccountBase._validateECDSA EXACTLY (the on-chain UserOp owner path),
            // including v=0/1 → 27/28 normalization, so eth_call and validateUserOp never diverge on
            // the same owner signature. tryRecover(hash, sig) alone would reject a v=0/1 encoding that
            // validateUserOp accepts. OZ tryRecover also enforces EIP-2 low-S (same bound as _validateECDSA).
            bytes calldata sig = ownerAuth[1:];
            bytes32 r; bytes32 s; uint8 v;
            assembly {
                r := calldataload(sig.offset)
                s := calldataload(add(sig.offset, 32))
                v := byte(0, calldataload(add(sig.offset, 64)))
            }
            if (v < 27) v += 27;
            (address recovered, ECDSA.RecoverError err, ) =
                ECDSA.tryRecover(userOpHash.toEthSignedMessageHash(), v, r, s);
            if (err == ECDSA.RecoverError.NoError && recovered != address(0) && recovered == o) {
                return OWNER_AUTH_MAGIC;
            }
            return 0xffffffff;
        }

        if (tag == OWNER_AUTH_TAG_WEBAUTHN) {
            if (_verifyOwnerWebAuthn(userOpHash, ownerAuth[1:])) return OWNER_AUTH_MAGIC;
            return 0xffffffff;
        }

        return 0xffffffff;
    }

    /// @notice Add a P-256 (passkey) guardian — owner-only while fewer than RECOVERY_THRESHOLD
    ///         guardians exist (pre-consensus bootstrap; a single guardian cannot form a quorum).
    ///         Once RECOVERY_THRESHOLD guardians are set, call addP256GuardianWithMixedSigs instead.
    function addP256Guardian(bytes32 x, bytes32 y) external onlyOwner {
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (_guardianCount >= RECOVERY_THRESHOLD) revert UseGuardianConsensus();
        // CC-102 F-W5/F-W7 (P256 twin of base addGuardian — pr-daemon B1): the add that REACHES
        // RECOVERY_THRESHOLD (count 1 → 2) forms a full recovery quorum. A P256 slot is a COMPLETE recovery
        // guardian (approveRecoveryWithSig checks only slot index + a WebAuthn assertion over an
        // attacker-chosen (x,y)), so an untimelocked path here lets a stolen owner key instantly self-add a
        // puppet passkey guardian and take the account over — the exact bypass the ECDSA-path timelock
        // closes. Require a matching proposal aged >= GUARDIAN_ADD_TIMELOCK, committed to THIS (x,y). The
        // first guardian (0 → 1) stays instant; addP256GuardianWithMixedSigs (count >= 2) is never a 1 → 2
        // add, so it is untouched (sinking the gate into _addP256GuardianInternal would wrongly freeze it).
        if (_guardianCount + 1 >= RECOVERY_THRESHOLD) {
            address commitment = address(uint160(uint256(keccak256(abi.encode(x, y)))));
            if (_pendingGuardian != commitment || _pendingGuardianAt == 0) revert GuardianAdditionNotProposed();
            if (block.timestamp < uint256(_pendingGuardianAt) + GUARDIAN_ADD_TIMELOCK) {
                revert GuardianAdditionTimelockNotExpired();
            }
            _pendingGuardian = address(0);
            _pendingGuardianAt = 0;
        }
        _addP256GuardianInternal(x, y);
        // F-W9 defensive symmetry with base addGuardian: growing the guardian set clears in-flight
        // weakening approval bits.
        delete pendingWeightChange;
    }

    /// @notice Step 1 of the timelocked bootstrap P256-guardian addition (CC-102 F-W5/F-W7, pr-daemon B1).
    ///         Only needed for the add that reaches RECOVERY_THRESHOLD (count 1 → 2); the first guardian is
    ///         added directly by addP256Guardian. Commits to the specific (x, y) key via a 160-bit hash in
    ///         the shared _pendingGuardian slot (no new storage). After GUARDIAN_ADD_TIMELOCK, call
    ///         addP256Guardian(x, y). Re-proposing overwrites the pending entry and restarts the clock.
    function proposeP256GuardianAddition(bytes32 x, bytes32 y) external onlyOwner {
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (_guardianCount >= RECOVERY_THRESHOLD) revert UseGuardianConsensus();
        if (x == bytes32(0) || y == bytes32(0)) revert InvalidP256GuardianKey();
        _pendingGuardian = address(uint160(uint256(keccak256(abi.encode(x, y)))));
        _pendingGuardianAt = uint40(block.timestamp);
        emit GuardianAdditionProposed(_pendingGuardian, block.timestamp + GUARDIAN_ADD_TIMELOCK);
    }

    /// @notice Add a P-256 (passkey) guardian with existing guardian consensus.
    ///         Requires RECOVERY_THRESHOLD valid guardian signatures so a stolen owner key
    ///         cannot expand the guardian set without the current guardians' approval.
    function addP256GuardianWithMixedSigs(
        bytes32 x,
        bytes32 y,
        uint8[] calldata signerIdxs,
        bytes[] calldata sigs
    ) external onlyOwner {
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (signerIdxs.length != sigs.length) revert InsufficientGuardianApprovals();
        if (signerIdxs.length < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        bytes memory opData = abi.encode(_guardianAdditionNonce, x, y);
        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < signerIdxs.length; i++) {
            uint8 gIdx = signerIdxs[i];
            if (gIdx >= _guardianCount) revert InvalidGuardian();
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
            _verifyGuardianSigByIdx(gIdx, sigs[i], "ADD_P256_GUARDIAN", opData);
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _guardianAdditionNonce++;
        _addP256GuardianInternal(x, y);
    }

    /// @notice Add an ECDSA guardian with existing guardian consensus.
    ///         Requires RECOVERY_THRESHOLD valid guardian signatures.
    function addGuardianWithMixedSigs(
        address _guardian,
        uint8[] calldata signerIdxs,
        bytes[] calldata sigs
    ) external onlyOwner {
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (_guardian == address(0) || _guardian == owner || _guardian == P256_GUARDIAN_SENTINEL) revert InvalidGuardian();
        if (_guardianCount >= 3) revert MaxGuardiansReached();
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == _guardian) revert GuardianAlreadySet();
        }
        if (signerIdxs.length != sigs.length) revert InsufficientGuardianApprovals();
        if (signerIdxs.length < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        bytes memory opData = abi.encode(_guardianAdditionNonce, _guardian);
        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < signerIdxs.length; i++) {
            uint8 gIdx = signerIdxs[i];
            if (gIdx >= _guardianCount) revert InvalidGuardian();
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
            _verifyGuardianSigByIdx(gIdx, sigs[i], "ADD_GUARDIAN", opData);
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _guardianAdditionNonce++;
        _setGuardian(_guardianCount, _guardian);
        emit GuardianAdded(_guardianCount, _guardian);
        _guardianCount++;
    }

    function _addP256GuardianInternal(bytes32 x, bytes32 y) private {
        if (x == bytes32(0) || y == bytes32(0)) revert InvalidP256GuardianKey();
        if (_guardianCount >= 3) revert MaxGuardiansReached();
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_isP256Guardian(i)) {
                (bytes32 ex, bytes32 ey) = _getP256Key(i);
                if (ex == x && ey == y) revert DuplicateP256GuardianKey();
            }
        }
        uint8 idx = _guardianCount;
        _setGuardian(idx, P256_GUARDIAN_SENTINEL);
        _setP256Key(idx, x, y);
        emit P256GuardianAdded(idx, x, y);
        _guardianCount++;
    }

    /// @notice Get the P-256 public key stored for a guardian slot (returns (0,0) if not a P-256 slot).
    function getGuardianP256Key(uint8 index) external view returns (bytes32 x, bytes32 y) {
        if (index >= _guardianCount || !_isP256Guardian(index)) return (bytes32(0), bytes32(0));
        return _getP256Key(index);
    }

    // ─── Social recovery (unified ECDSA + P-256) ──────────────────────────────────────────────────
    //
    // Moved here from AAStarAirAccountBase as part of the #120 follow-up refactor. The account
    // (V7) sat 11 bytes under EIP-170; relocating these low-frequency externals across the
    // fallback→delegatecall boundary frees that runtime budget. ECDSA (msg.sender-authed) and
    // P-256 (sig-authed) paths now share the _commit* core helpers, so the bitmap/event logic
    // exists in exactly one place — the very duplication that produced the removeGuardian
    // key-shift drift in #120. delegatecall preserves msg.sender/address(this)/storage, so these
    // behave identically to inline functions. None read V7 immutables (only storage + constants).

    /// @dev Shared cheap pre-checks for a new proposal: target validity + no active recovery.
    ///      Runs before (expensive) guardian authentication so both paths fail fast.
    function _validateNewOwner(address newOwner) private view {
        if (newOwner == address(0) || newOwner == owner) revert InvalidNewOwner();
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == newOwner) revert InvalidNewOwner();
        }
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
    }

    /// @dev Open a fresh proposal, auto-approving the proposing guardian. `guardianIdx` is the
    ///      authorized slot (msg.sender's slot for ECDSA, gIdx for P-256).
    function _commitProposal(address newOwner, uint8 guardianIdx) private {
        activeRecovery = RecoveryProposal({
            newOwner: newOwner,
            proposedAt: block.timestamp,
            approvalBitmap: uint256(1) << guardianIdx,
            cancellationBitmap: 0
        });
        emit RecoveryProposed(newOwner, msg.sender, guardianIdx);
        emit RecoveryApproved(newOwner, msg.sender, 1, guardianIdx);
    }

    /// @dev Record an approval vote for `guardianIdx` (caller verified slot + de-dup beforehand).
    function _commitApproval(uint8 guardianIdx) private {
        activeRecovery.approvalBitmap |= (uint256(1) << guardianIdx);
        uint256 count = _popcount(activeRecovery.approvalBitmap);
        emit RecoveryApproved(activeRecovery.newOwner, msg.sender, count, guardianIdx);
    }

    /// @dev Record a cancellation vote for `guardianIdx`; clears recovery once threshold is met.
    function _commitCancelVote(uint8 guardianIdx) private {
        activeRecovery.cancellationBitmap |= (uint256(1) << guardianIdx);
        uint256 count = _popcount(activeRecovery.cancellationBitmap);
        emit RecoveryCancelVoted(msg.sender, count, guardianIdx);
        if (count >= RECOVERY_THRESHOLD) {
            delete activeRecovery;
            _recoveryNonce++;
            emit RecoveryCancelled();
        }
    }

    // ── ECDSA paths (msg.sender is the guardian) ──────────────────────────────────────────────────

    /// @notice An ECDSA guardian proposes a recovery. Any guardian may propose; auto-approves self.
    function proposeRecovery(address newOwner) external {
        _validateNewOwner(newOwner);
        uint8 guardianIdx = _guardianIndex(msg.sender); // reverts if caller is not a guardian
        _commitProposal(newOwner, guardianIdx);
    }

    /// @notice An ECDSA guardian approves the active recovery proposal.
    function approveRecovery() external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();
        uint8 guardianIdx = _guardianIndex(msg.sender);
        if (activeRecovery.approvalBitmap & (uint256(1) << guardianIdx) != 0) revert AlreadyApproved();
        _commitApproval(guardianIdx);
    }

    /// @notice Execute recovery after timelock and threshold are met. Permissionless trigger.
    function executeRecovery() external {
        RecoveryProposal memory r = activeRecovery;
        if (r.newOwner == address(0)) revert NoActiveRecovery();
        if (block.timestamp < r.proposedAt + RECOVERY_TIMELOCK) revert RecoveryTimelockNotExpired();
        // #79: guardian bitmap — at most 3 bits set, so _popcount's all-ones edge is unreachable here.
        if (_popcount(r.approvalBitmap) < RECOVERY_THRESHOLD) revert RecoveryNotApproved();

        address oldOwner = owner;
        owner = r.newOwner;
        // H2/#194: recovery must revoke ALL of the old owner's auth factors, not just the ECDSA key.
        // The old owner's P256 device passkey (ALG_P256 0x03, Tier-1-whitelisted by default, and a
        // factor in cumulative tiers) survived recovery otherwise, so a compromised/lost old device
        // could keep authorizing UserOps after the account was recovered to a new owner. Clear it; the
        // new owner re-establishes their own passkey via setP256Key after recovery.
        p256KeyX = bytes32(0);
        p256KeyY = bytes32(0);
        // CC-102 F-W8: recovery changes the owner, so any weakening weight-change proposal collected under
        // the OLD (compromised) owner must not survive into the new owner's account. executeWeightChange is
        // permissionless and only checks approvals + timelock, so a proposal approved during the compromise
        // window would otherwise stay executable for up to WEIGHT_CHANGE_EXPIRY after recovery. Clear it.
        delete pendingWeightChange;
        delete activeRecovery;
        _recoveryNonce++;

        emit RecoveryExecuted(oldOwner, r.newOwner);
        emit OwnerChanged(oldOwner, r.newOwner);
    }

    /// @notice An ECDSA guardian votes to cancel the active recovery. 2-of-3 threshold clears it.
    /// @dev Owner cannot cancel: a stolen owner key could otherwise block legitimate recovery.
    function cancelRecovery() external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();
        uint8 guardianIdx = _guardianIndex(msg.sender);
        if (activeRecovery.cancellationBitmap & (uint256(1) << guardianIdx) != 0) revert AlreadyCancelVoted();
        _commitCancelVote(guardianIdx);
    }

    // ── P-256 paths (relayer submits a pre-signed assertion; gIdx names the signing guardian) ─────

    /// @notice P-256 guardian proposes a recovery (any relayer can submit the pre-signed calldata).
    /// @param newOwner  Target owner address after recovery
    /// @param gIdx      Guardian slot index (0/1/2)
    /// @param sig       WebAuthn assertion blob authorizing this proposal
    function proposeRecoveryWithSig(address newOwner, uint8 gIdx, bytes calldata sig) external {
        _validateNewOwner(newOwner);
        if (gIdx >= _guardianCount || !_isP256Guardian(gIdx)) revert InvalidGuardian();
        _verifyGuardianSigByIdx(gIdx, sig, "PROPOSE_RECOVERY", abi.encode(_recoveryNonce, newOwner));
        _commitProposal(newOwner, gIdx);
    }

    /// @notice P-256 guardian approves an active recovery proposal.
    /// @param gIdx  Guardian slot index
    /// @param sig   WebAuthn assertion blob authorizing this approval
    function approveRecoveryWithSig(uint8 gIdx, bytes calldata sig) external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();
        if (gIdx >= _guardianCount || !_isP256Guardian(gIdx)) revert InvalidGuardian();
        if (activeRecovery.approvalBitmap & (uint256(1) << gIdx) != 0) revert AlreadyApproved();
        _verifyGuardianSigByIdx(gIdx, sig, "APPROVE_RECOVERY", abi.encode(_recoveryNonce, activeRecovery.newOwner));
        _commitApproval(gIdx);
    }

    /// @notice P-256 guardian votes to cancel an active recovery proposal.
    /// @param gIdx  Guardian slot index
    /// @param sig   WebAuthn assertion blob authorizing this cancel vote
    function cancelRecoveryWithSig(uint8 gIdx, bytes calldata sig) external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();
        if (gIdx >= _guardianCount || !_isP256Guardian(gIdx)) revert InvalidGuardian();
        if (activeRecovery.cancellationBitmap & (uint256(1) << gIdx) != 0) revert AlreadyCancelVoted();
        _verifyGuardianSigByIdx(gIdx, sig, "CANCEL_RECOVERY", abi.encode(_recoveryNonce, activeRecovery.newOwner));
        _commitCancelVote(gIdx);
    }

    /// @notice Remove a guardian by index using mixed-type guardian signatures (ECDSA or P-256).
    ///         Required when at least one guardian is a P-256 type (which can't use the ECDSA-only path).
    /// @param index      Slot to remove (0-indexed)
    /// @param signerIdxs Guardian slot indices corresponding to each signature
    /// @param sigs       Signatures: 65-byte (r||s||v) eth-signed sig for ECDSA guardians; for P-256
    ///                   guardians the WebAuthn assertion blob
    ///                   abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
    function removeGuardianWithMixedSigs(
        uint8 index,
        uint8[] calldata signerIdxs,
        bytes[] calldata sigs
    ) external onlyOwner {
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (_guardianCount <= 2) revert MinGuardianRequired();
        if (index >= _guardianCount) revert InvalidGuardian();
        if (signerIdxs.length != sigs.length) revert InsufficientGuardianApprovals();
        if (signerIdxs.length < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        address guardianToRemove = _getGuardian(index);
        // #120 final review [HIGH]: P-256 guardians all share the sentinel address, so binding only
        // (nonce, guardianToRemove) makes every P-256 slot's removal payload IDENTICAL — a signature
        // collected to remove P-256 slot A could be replayed to remove a different P-256 slot B, or
        // survive a key rotation on the same slot. Bind the slot index AND the P-256 key ((0,0) for
        // ECDSA) so a signature authorizes the removal of one specific guardian/key.
        (bytes32 remX, bytes32 remY) = _getP256Key(index);
        bytes memory opData = abi.encode(_guardianRemovalNonce, index, guardianToRemove, remX, remY);

        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < signerIdxs.length; i++) {
            uint8 gIdx = signerIdxs[i];
            if (gIdx >= _guardianCount) revert InvalidGuardian();
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
            _verifyGuardianSigByIdx(gIdx, sigs[i], "REMOVE_GUARDIAN", opData);
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _guardianRemovalNonce++;

        // If removing a P-256 slot, clear the stored key
        if (guardianToRemove == P256_GUARDIAN_SENTINEL) {
            _clearP256Key(index);
        }

        // Shift remaining guardians left (also shift P-256 keys for P-256 slots)
        for (uint8 i = index; i < _guardianCount - 1; i++) {
            address nextG = _getGuardian(uint8(i + 1));
            _setGuardian(i, nextG);
            if (nextG == P256_GUARDIAN_SENTINEL) {
                (bytes32 nx, bytes32 ny) = _getP256Key(uint8(i + 1));
                _setP256Key(i, nx, ny);
                _clearP256Key(uint8(i + 1));
            }
        }
        _setGuardian(_guardianCount - 1, address(0));
        _guardianCount--;

        // CC-102 F-W9 (twin of base removeGuardian): this mixed-sig removal does the SAME left-compression
        // of guardian slots, so a surviving weakening proposal's slot-indexed approval bits would re-point
        // to different guardians (phantom approvals — the exact soundness break the base fix closes). Clear
        // the pending proposal here too, or the fix is applied to only one of two storage-sharing twins.
        delete pendingWeightChange;

        emit GuardianRemoved(index, guardianToRemove);
    }

    /// @notice Current tier-limit modification nonce.
    ///         Increments after each successful modifyTierLimitsWithGuardians /
    ///         modifyTierLimitsWithMixedGuardians call. SDK reads this offline
    ///         to build the guardian digest before requesting signatures.
    /// @dev Reached via account.fallback() → delegatecall(agentExtension).
    ///      Reads _tierLimitNonce from the ACCOUNT's storage (slot 16), not the extension's.
    function tierLimitNonce() external view returns (uint256) {
        return _tierLimitNonce;
    }

    /// @notice Modify tier limits with mixed-type guardian signatures (ECDSA or P-256).
    ///         Required when at least one guardian is a P-256 type.
    /// @param signerIdxs Guardian slot indices corresponding to each signature
    /// @param sigs       Signatures: 65-byte (r||s||v) eth-signed sig for ECDSA; for P-256 the WebAuthn
    ///                   assertion blob abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
    function modifyTierLimitsWithMixedGuardians(
        uint256 _tier1,
        uint256 _tier2,
        uint256 deadline,
        uint8[] calldata signerIdxs,
        bytes[] calldata sigs
    ) external onlyOwnerOrSelf {
        if (_tier2 > 0 && _tier1 > _tier2) revert InvalidTierConfig();
        if (block.timestamp > deadline) revert TierLimitSigExpired();
        if (signerIdxs.length != sigs.length) revert InsufficientGuardianApprovals();
        if (signerIdxs.length < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        bytes memory opData = abi.encode(_tierLimitNonce, _tier1, _tier2, deadline);

        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < signerIdxs.length; i++) {
            uint8 gIdx = signerIdxs[i];
            if (gIdx >= _guardianCount) revert InvalidGuardian();
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
            _verifyGuardianSigByIdx(gIdx, sigs[i], "MODIFY_TIER_LIMITS", opData);
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _tierLimitNonce++;
        _tierLimitsInitialized = true;
        tier1Limit = _tier1;
        tier2Limit = _tier2;
        emit TierLimitsSet(_tier1, _tier2);
    }

}
