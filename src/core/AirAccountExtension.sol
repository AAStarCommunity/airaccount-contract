// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAgentStorageLayout} from "./AAStarAgentStorageLayout.sol";
import {IAirAccountAgent} from "../interfaces/IAirAccountAgent.sol";
import {IERC8004IdentityRegistry} from "../interfaces/IERC8004IdentityRegistry.sol";
import {IERC8004ReputationRegistry} from "../interfaces/IERC8004ReputationRegistry.sol";
import {ERC8004Addresses} from "../config/ERC8004Addresses.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

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

    // Guardian-signed domain version (mirror AAStarAirAccountBase, issue #84).
    uint8 internal constant GUARDIAN_SIG_VERSION = 4;

    // ERC-7579 module type IDs (mirror AAStarAirAccountV7): 1=validator, 2=executor, 4=hook.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;
    uint256 internal constant MODULE_TYPE_HOOK      = 4;

    // ERC-7579 onInstall(bytes) lifecycle selector (mirror AAStarAirAccountV7).
    bytes4 private constant SEL_ON_INSTALL = 0x6d61fe70;

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

    /// @dev Verify `count` sequential 65-byte ECDSA sigs from distinct guardians
    ///      (mirror AAStarAirAccountV7._checkGuardianSigs).
    function _checkGuardianSigs(bytes32 hash, bytes calldata sigs, uint8 count) private view {
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

    // ─── Module Install Timelock (KI-6 / issue #58) ──────────────────────

    /// @dev Snapshot of the auth config a module-install proposal is bound to. Any change to the owner
    ///      (social recovery) or the guardian set (add/remove/replace) shifts this hash, invalidating an
    ///      in-flight proposal so it cannot be silently executed under a different signer set.
    function _moduleAuthHash() private view returns (bytes32) {
        return keccak256(abi.encode(owner, _guardian0, _guardian1, _guardian2, _guardianCount));
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
    /// @param guardianSigs Concatenated 65-byte guardian sigs over
    ///        _guardianOpHash("SET_MODULE_TIMELOCK", abi.encode(newTimelock, moduleManagementNonce)).
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
            _checkGuardianSigs(
                _guardianOpHash("SET_MODULE_TIMELOCK", abi.encode(newTimelock, _moduleManagementNonce)),
                guardianSigs,
                sigsRequired
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
    /// @param initData     Layout: guardian sig(s) prepended (per configured threshold), then module init data.
    ///        Sig hash: _guardianOpHash("INSTALL_MODULE", abi.encode(moduleTypeId, module, keccak256(moduleInitData), moduleManagementNonce)).
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

        bytes calldata moduleInitData;
        if (sigsRequired > 0) {
            uint256 sigEnd = uint256(sigsRequired) * 65;
            if (initData.length < sigEnd) revert InstallModuleUnauthorized();
            moduleInitData = initData[sigEnd:];
            _checkGuardianSigs(
                _guardianOpHash(
                    "INSTALL_MODULE",
                    abi.encode(moduleTypeId, module, keccak256(moduleInitData), _moduleManagementNonce)
                ),
                initData,
                sigsRequired
            );
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
    function setWeightConfig(WeightConfig calldata config) external onlyOwner {
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
    }

    /// @dev Returns true if proposed config is a weakening of current config.
    function _isWeakening(WeightConfig memory current, WeightConfig memory proposed) private pure returns (bool) {
        if (proposed.passkeyWeight   < current.passkeyWeight)   return true;
        if (proposed.ecdsaWeight     < current.ecdsaWeight)     return true;
        if (proposed.blsWeight       < current.blsWeight)       return true;
        if (proposed.guardian0Weight < current.guardian0Weight) return true;
        if (proposed.guardian1Weight < current.guardian1Weight) return true;
        if (proposed.guardian2Weight < current.guardian2Weight) return true;
        if (proposed.tier1Threshold  < current.tier1Threshold)  return true;
        if (proposed.tier2Threshold  < current.tier2Threshold)  return true;
        if (proposed.tier3Threshold  < current.tier3Threshold)  return true;
        return false;
    }
}
