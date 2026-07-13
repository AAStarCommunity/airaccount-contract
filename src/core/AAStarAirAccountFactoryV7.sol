// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAirAccountV7} from "./AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title AAStarAirAccountFactoryV7 - EIP-1167 clone factory for V7 accounts
/// @notice Deploys minimal proxy clones pointing to a shared implementation, then calls initialize().
///         This keeps factory bytecode well under EIP-170's 24,576-byte limit.
///         Account address = Clones.predictDeterministicAddress(implementation, keccak256(owner ++ salt))
/// @dev Provides both full-config and convenience (default guardian) creation methods.
///      No default daily limit — user must specify their own limit during creation.
contract AAStarAirAccountFactoryV7 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Semantic version of this factory deployment. Used by SDKs for programmatic version detection.
    string public constant FACTORY_VERSION = "0.28.0";

    /// @dev Shared implementation contract — all user accounts are clones of this address.
    ///      INJECTED as a constructor parameter (deployer must deploy AAStarAirAccountV7 first and
    ///      pass its address). Never call initialize() on this address directly.
    /// @dev #82 EIP-3860 fix: previously the factory deployed the implementation INLINE
    ///      (`new AAStarAirAccountV7()` in the constructor), which embedded the implementation's
    ///      entire creation bytecode (~14 KB) into the factory's own initcode and brought it within
    ///      ~18 bytes of the 49,152-byte EIP-3860 cap. Injecting the address removes that embedded
    ///      creation code, recovering several KB of initcode headroom. CREATE2 account-address
    ///      determinism is unchanged: the clone (EIP-1167 minimal proxy) bytecode embeds this
    ///      address, so identical impl bytecode at the same address yields identical account
    ///      addresses — exactly as before, when the factory deployed the impl itself.
    address public immutable implementation;

    /// @dev The EntryPoint address used for all created accounts
    address public immutable entryPoint;

    /// @dev Default community guardian (Safe multisig provided by the community)
    address public immutable defaultCommunityGuardian;

    /// @dev Default token addresses for new accounts (chain-specific, set at deploy time)
    address[] private _defaultTokenAddresses;
    /// @dev Default token spending configs aligned with _defaultTokenAddresses
    AAStarGlobalGuard.TokenConfig[] private _defaultTokenConfigs;

    /// @dev Maximum allowed TTL for guardian2 (and agentKey) signatures in createAgentAccount.
    ///      Prevents a long-lived signature from being replayed far in the future.
    uint48 internal constant MAX_GUARDIAN_SIG_TTL = 30 days;

    /// @dev v0.17.2 H-2 (Codex P1 round 2): AgentRegistry that records the provenance of each
    ///      account created by this factory. Set once via `setAgentRegistry` post-deploy
    ///      (factory↔registry circular dependency). When non-zero, each createAccount* calls
    ///      `agentRegistry.markValid(account)`, which is the only path to populating
    ///      `isValidAccount`. SuperPaymaster's sponsorship eligibility rests on this mapping.
    address public agentRegistry;
    /// @dev Deployer of the factory; the only address allowed to call `setAgentRegistry`. Set-once.
    address public immutable factoryAdmin;

    /// @dev Per-owner nonce for createAccount owner signature (issue #155 P1 replay protection).
    mapping(address => uint256) public createNonces;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);
    event AgentRegistrySet(address indexed agentRegistry);

    /// @dev Emitted when an agent account is created via createAgentAccount.
    event AgentAccountCreated(
        address indexed account,
        address indexed agentKey,
        address indexed humanOwner,
        bytes32 agentId,
        address guardian2,
        uint256 dailyLimit
    );

    error GuardianDidNotAccept(address guardian);
    error DuplicateGuardian();
    error AgentKeyDidNotAccept();
    error ImplementationRequired();
    error NotFactoryAdmin();
    error AgentRegistryAlreadySet();
    error AgentRegistryNotContract();
    error AgentRegistryMarkValidFailed();
    error TokenConfigLengthMismatch();
    error DefaultTokenAddressZero(address token);
    error DuplicateDefaultToken(address token);
    error InvalidDefaultTokenConfig(address token);
    error GuardiansRequired();
    error GuardiansMustBeDistinct();
    error AgentKeyRequired();
    error Guardian2Required();
    error CallerCannotBeGuardian2();
    error AgentKeyCannotBeGuardian2();
    error DailyLimitRequired();
    error GuardianSigExpired();
    error DeadlineTooFarInFuture();
    error SignatureExpired();
    error NonceMismatch();
    error InvalidOwnerSignature();
    error HumanOwnerCannotBeCommunityGuardian();
    error Guardian2CannotBeCommunityGuardian();
    error AgentKeyCannotBeCommunityGuardian();

    /// @param _implementation Pre-deployed AAStarAirAccountV7 implementation that all clones point to.
    ///        Deployer MUST deploy `new AAStarAirAccountV7()` first and pass its address here.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _communityGuardian Default community Safe multisig guardian address
    /// @param defaultTokens Token addresses to pre-configure for all new accounts (empty = no defaults)
    /// @param defaultConfigs Spending limits aligned with defaultTokens
    /// @dev v0.17.2: removed defaultValidatorModule / defaultHookModule / agentSessionKeyValidator
    ///      machinery. The unified SessionKeyValidator (router algId 0x08) replaces ERC-7579
    ///      install-based session keys. CompositeValidator and TierGuardHook are deleted.
    /// @dev #82 EIP-3860 fix: implementation is now INJECTED (was `new AAStarAirAccountV7()` inline)
    ///      to keep the factory's initcode well under the 49,152-byte creation-code cap.
    constructor(
        address _implementation,
        address _entryPoint,
        address _communityGuardian,
        address[] memory defaultTokens,
        AAStarGlobalGuard.TokenConfig[] memory defaultConfigs
    ) {
        if (_implementation == address(0)) revert ImplementationRequired();
        if (defaultTokens.length != defaultConfigs.length) revert TokenConfigLengthMismatch();
        // All user accounts are EIP-1167 clones of this pre-deployed implementation.
        implementation = _implementation;
        entryPoint = _entryPoint;
        defaultCommunityGuardian = _communityGuardian;
        factoryAdmin = msg.sender; // for set-once setAgentRegistry post-deploy
        for (uint256 i = 0; i < defaultTokens.length; i++) {
            address tok = defaultTokens[i];
            if (tok == address(0)) revert DefaultTokenAddressZero(tok);
            // Dedup check: O(n^2) but n is small (≤10 expected) and this is deploy-time only
            for (uint256 j = 0; j < i; j++) {
                if (_defaultTokenAddresses[j] == tok) revert DuplicateDefaultToken(tok);
            }
            // Validate tier/daily relationship eagerly — invalid configs revert here rather
            // than failing silently for every createAccountWithDefaults call.
            AAStarGlobalGuard.TokenConfig memory cfg = defaultConfigs[i];
            bool bad = (cfg.tier1Limit > 0 && cfg.tier2Limit > 0 && cfg.tier1Limit > cfg.tier2Limit)
                || (cfg.tier2Limit > 0 && cfg.dailyLimit > 0 && cfg.dailyLimit < cfg.tier2Limit)
                || (cfg.tier1Limit > 0 && cfg.tier2Limit == 0 && cfg.dailyLimit > 0 && cfg.dailyLimit < cfg.tier1Limit)
                || ((cfg.tier1Limit > 0 || cfg.tier2Limit > 0) && cfg.dailyLimit == 0);
            if (bad) revert InvalidDefaultTokenConfig(tok);
            _defaultTokenAddresses.push(tok);
            _defaultTokenConfigs.push(cfg);
        }
    }

    // ─── Post-deploy AgentRegistry binding (v0.17.2 H-2 round 2) ─────

    /// @notice One-time setter for the AgentRegistry whose `isValidAccount` mapping records
    ///         which accounts were created by this factory. Caller must be `factoryAdmin`
    ///         (i.e., the deployer of this factory). Set-once: cannot be re-pointed.
    /// @dev    Why a setter and not a constructor param: AgentRegistry's own constructor needs
    ///         to know the factory address (to gate `markValid`), creating a circular dependency
    ///         at deploy time. Deployment order is: factory → AgentRegistry(factory) →
    ///         factory.setAgentRegistry(agentRegistry). Until set, createAccount* still works
    ///         but does NOT call markValid — those accounts will not be able to registerAgent
    ///         until the registry is bound. Recommended to set immediately after deploy.
    function setAgentRegistry(address _agentRegistry) external {
        if (msg.sender != factoryAdmin) revert NotFactoryAdmin();
        if (agentRegistry != address(0)) revert AgentRegistryAlreadySet();
        if (_agentRegistry.code.length == 0) revert AgentRegistryNotContract();
        agentRegistry = _agentRegistry;
        emit AgentRegistrySet(_agentRegistry);
    }

    /// @dev Helper called from each createAccount* path to mark provenance in the AgentRegistry.
    ///      No-op if agentRegistry is unset (deployer hasn't bound a registry yet — recommended
    ///      to set immediately after deploy).
    /// @dev Codex P1 round 3 (2026-05-30): if the registry IS set but markValid fails (wrong
    ///      address, wrong contract, paused, etc), REVERT the whole account creation. Previously
    ///      this was a silent best-effort swallow — but that produces "ghost" accounts that
    ///      exist on-chain but cannot registerAgent (registry's isValidAccount mapping is empty
    ///      for them), with no signal to user / SDK / SuperPaymaster about why. Loud failure is
    ///      strictly better than silent half-broken state.
    function _markAccountValid(address account) internal {
        address reg = agentRegistry;
        if (reg == address(0)) return;
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = reg.call(abi.encodeWithSignature("markValid(address)", account));
        if (!ok) {
            if (ret.length > 0) {
                assembly { revert(add(ret, 0x20), mload(ret)) }
            }
            revert AgentRegistryMarkValidFailed();
        }
    }

    // ─── Full Configuration ─────────────────────────────────────────

    /// @notice Deploy a new account with full configuration.
    /// @param owner Account owner (ECDSA signer)
    /// @param salt CREATE2 salt for deterministic address
    /// @param config Full initialization config (guardians, guard, algorithms)
    /// @notice Deploy an AirAccount clone from this factory.
    /// @notice Deploy an AirAccount clone from this factory.
    ///
    ///      Two authorization modes (auto-selected by ownerSig.length):
    ///
    ///      Direct mode (ownerSig empty, msg.sender == owner):
    ///        EOA owners who send the tx themselves need no extra signature — the tx is their proof.
    ///        nonce and deadline are ignored; pass (0, 0) or any value.
    ///
    ///      Relayed / KMS mode (ownerSig non-empty):
    ///        For KMS-managed accounts whose owner key lives in a TEE and cannot issue raw txs.
    ///        Any relayer can submit; the signature authenticates the owner.
    ///        Signature domain: EIP-191 over
    ///          keccak256(abi.encode("CREATE_ACCOUNT", chainId, address(this), owner, salt,
    ///                               ownerP256X, ownerP256Y, _getConfigHash(config), nonce, deadline))
    ///        nonce must equal createNonces[owner] (incremented on success).
    ///        Validator is auto-wired from the implementation's validatorRouter immutable.
    ///        Owner passkey (p256KeyX/Y) is set atomically at account birth when ownerP256X/Y are non-zero.
    ///
    /// @param owner       Account owner (ECDSA signer / KMS-derived address)
    /// @param salt        User-chosen CREATE2 salt (combined with owner + configHash + passkey for uniqueness)
    /// @param config      Full init config (guardians, algIds, limits, tokens)
    /// @param ownerP256X  Owner P256 passkey x-coordinate (bytes32(0) to skip)
    /// @param ownerP256Y  Owner P256 passkey y-coordinate (bytes32(0) to skip)
    /// @param nonce       Replay-prevention nonce (relayed mode only; ignored if ownerSig is empty)
    /// @param deadline    Unix timestamp deadline (relayed mode only; ignored if ownerSig is empty)
    /// @param ownerSig    EIP-191 owner sig (empty = direct mode where msg.sender must be owner)
    function createAccount(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config,
        bytes32 ownerP256X,
        bytes32 ownerP256Y,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSig
    ) external returns (address account) {
        // Owner authorization: direct tx (msg.sender proof) or KMS-relayed EIP-191 sig.
        if (ownerSig.length == 0) {
            if (msg.sender != owner) revert InvalidOwnerSignature();
        } else {
            if (block.timestamp > deadline) revert SignatureExpired();
            if (nonce != createNonces[owner]) revert NonceMismatch();
            bytes32 digest = keccak256(abi.encode(
                "CREATE_ACCOUNT",
                block.chainid,
                address(this),
                owner,
                salt,
                ownerP256X,
                ownerP256Y,
                _getConfigHash(config),
                nonce,
                deadline
            )).toEthSignedMessageHash();
            if (digest.recover(ownerSig) != owner) revert InvalidOwnerSignature();
            createNonces[owner]++;
        }
        // Validate guardians: non-zero entries must be pairwise distinct.
        // Without this, [addrA, addrA, addrB] degrades 2-of-3 social recovery to 1-of-2.
        address[3] memory g = config.guardians;
        if (g[0] != address(0) && g[1] != address(0) && g[0] == g[1]) revert DuplicateGuardian();
        if (g[0] != address(0) && g[2] != address(0) && g[0] == g[2]) revert DuplicateGuardian();
        if (g[1] != address(0) && g[2] != address(0) && g[1] == g[2]) revert DuplicateGuardian();

        // Bind address to config + passkey: ownerP256X/Y are folded into the clone salt so that
        // (a) a front-runner cannot pre-deploy with a different config, and (b) different passkeys
        // produce different addresses, allowing the same owner+salt to be used across devices.
        bytes32 cloneSalt = _getSalt(owner, salt, keccak256(abi.encode(_getConfigHash(config), ownerP256X, ownerP256Y)));
        account = Clones.predictDeterministicAddress(implementation, cloneSalt);
        if (account.code.length > 0) {
            return account;
        }
        // Pre-deploy guard bound to the predicted account address.
        // Guard must be deployed BEFORE the clone so it can reference the account address.
        // guard creation code stays in factory runtime, not in account runtime — avoids EIP-170 overflow.
        address guardAddr = address(0);
        if (config.dailyLimit > 0) {
            guardAddr = _deployGuard(account, config);
        }
        account = Clones.cloneDeterministic(implementation, cloneSalt);
        // Validator is auto-wired by the implementation's validatorRouter immutable (issue #155 P1).
        // ownerP256X/Y are set atomically at account birth if non-zero.
        AAStarAirAccountV7(payable(account)).initialize(entryPoint, owner, config, guardAddr, ownerP256X, ownerP256Y);
        _markAccountValid(account);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Predict the counterfactual address for a full-config account.
    /// @dev Address depends on owner + salt + keccak256(configHash, ownerP256X, ownerP256Y) to prevent
    ///      front-running attacks where an attacker pre-deploys the account with malicious guardians or passkey.
    function getAddress(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config,
        bytes32 ownerP256X,
        bytes32 ownerP256Y
    ) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt, keccak256(abi.encode(_getConfigHash(config), ownerP256X, ownerP256Y))));
    }

    // ─── Convenience: Default Guardian Setup ────────────────────────

    /// @notice Deploy account with default community guardian as third guardian.
    /// @dev User provides 2 personal guardians with acceptance signatures.
    ///      Each guardian must sign: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt, dailyLimit)).toEthSignedMessageHash()
    ///      Guard is initialized with user-specified dailyLimit and all 3 standard algorithms.
    /// @param owner Account owner
    /// @param salt CREATE2 salt
    /// @param guardian1 User's backup key (passkey, EOA, or second device)
    /// @param guardian1Sig guardian1's acceptance signature
    /// @param guardian2 Trusted person (spouse, family) or another passkey
    /// @param guardian2Sig guardian2's acceptance signature
    /// @param dailyLimit Daily spending limit in wei (user chooses based on their needs)
    /// @dev Guardian acceptance hash is domain-separated:
    ///      keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt, dailyLimit)).toEthSignedMessageHash()
    ///      Including chainId and address(this) prevents cross-chain and cross-factory replay;
    ///      dailyLimit prevents front-run with a weaker limit on the same address.
    function createAccountWithDefaults(
        address owner,
        uint256 salt,
        address guardian1,
        bytes calldata guardian1Sig,
        address guardian2,
        bytes calldata guardian2Sig,
        uint256 dailyLimit
    ) external returns (address account) {
        if (guardian1 == address(0) || guardian2 == address(0)) revert GuardiansRequired();
        if (guardian1 == guardian2) revert GuardiansMustBeDistinct();
        if (dailyLimit == 0) revert DailyLimitRequired(); // F72: guard must be configured

        // Verify both guardians signed the domain-separated acceptance message (F56 — M5.3)
        // chainId + address(this) prevent replay across chains and factories with same owner+salt.
        // dailyLimit is bound so a front-runner cannot replay these guardian sigs with a larger
        // (weaker) dailyLimit on the same counterfactual address (_getDefaultSalt = owner+salt only).
        bytes32 acceptHash = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(this), owner, salt, dailyLimit))
            .toEthSignedMessageHash();
        (address recovered1,,) = acceptHash.tryRecover(guardian1Sig);
        if (recovered1 != guardian1) revert GuardianDidNotAccept(guardian1);
        (address recovered2,,) = acceptHash.tryRecover(guardian2Sig);
        if (recovered2 != guardian2) revert GuardianDidNotAccept(guardian2);

        bytes32 cloneSalt = _getDefaultSalt(owner, salt, guardian1, guardian2);
        account = Clones.predictDeterministicAddress(implementation, cloneSalt);
        if (account.code.length > 0) {
            return account;
        }

        AAStarAirAccountBase.InitConfig memory config = _buildDefaultConfig(
            guardian1, guardian2, dailyLimit
        );
        // Pre-deploy guard bound to the predicted account address before cloning.
        address guardAddr = _deployGuard(account, config);
        account = Clones.cloneDeterministic(implementation, cloneSalt);
        AAStarAirAccountV7(payable(account)).initialize(entryPoint, owner, config, guardAddr, bytes32(0), bytes32(0));
        _markAccountValid(account);        emit AccountCreated(account, owner, salt);
    }

    /// @notice Create a dedicated AirAccount for an autonomous AI agent.
    ///         The human caller (msg.sender) becomes the account OWNER (not a guardian).
    ///         Guardians are [guardian2, communityGuardian] (2-of-2); only guardian2 must sign.
    ///
    /// @param agentKey    The agent's signing key (EOA address). NOT the account owner — it is the
    ///                   agent's intended session key, authorized after deployment via
    ///                   SessionKeyValidator.grantSession() (algId 0x08, ALG_SESSION_KEY; agent-scoped —
    ///                   there is no separate AgentSessionKeyValidator). The owner is msg.sender (human).
    ///                   For autonomous agents: use a secure server-side / KMS-held key.
    /// @param agentId     A bytes32 identifier for this agent (e.g. keccak256("my-agent-v1")).
    ///                   Combined with msg.sender to derive a unique deterministic salt.
    /// @param guardian2   Second guardian (human's personal backup key, trusted person, etc.)
    /// @param guardian2Sig guardian2's acceptance signature. Signs:
    ///                   keccak256("ACCEPT_AGENT_GUARDIAN" || chainId || factory || agentKey || humanOwner || agentId || deadline).toEthSignedMessageHash()
    ///                   The "ACCEPT_AGENT_GUARDIAN" domain and explicit humanOwner + agentId prevent
    ///                   cross-namespace collision with createAccountWithDefaults signatures.
    /// @param agentKeySig agentKey's consent signature. Signs:
    ///                   keccak256("ACCEPT_AGENT_KEY" || chainId || factory || agentKey || humanOwner || agentId || deadline).toEthSignedMessageHash()
    ///                   Proves the KMS/agent key holder explicitly authorized this creation;
    ///                   prevents a human from binding an arbitrary EOA as the agent's session key.
    /// @param deadline    Expiry timestamp for guardian2Sig and agentKeySig — prevents replay of stale signatures
    /// @param dailyLimit  Daily spending limit in wei for this agent account
    /// @return account    The deployed agent account address
    function createAgentAccount(
        address agentKey,
        bytes32 agentId,
        address guardian2,
        bytes calldata guardian2Sig,
        bytes calldata agentKeySig,
        uint48 deadline,
        uint256 dailyLimit
    ) external returns (address account) {
        if (agentKey == address(0)) revert AgentKeyRequired();
        if (guardian2 == address(0)) revert Guardian2Required();
        if (msg.sender == guardian2) revert CallerCannotBeGuardian2();
        if (agentKey == guardian2) revert AgentKeyCannotBeGuardian2();
        if (dailyLimit == 0) revert DailyLimitRequired();
        if (block.timestamp > deadline) revert GuardianSigExpired();
        if (deadline > block.timestamp + MAX_GUARDIAN_SIG_TTL) revert DeadlineTooFarInFuture();

        // Uniqueness prechecks: none of the three guardians may be the community guardian,
        // preventing an attacker from using the factory's own defaultCommunityGuardian as
        // guardian2 (or as the human caller) to trivially satisfy social-recovery thresholds.
        if (msg.sender == defaultCommunityGuardian) revert HumanOwnerCannotBeCommunityGuardian();
        if (guardian2 == defaultCommunityGuardian) revert Guardian2CannotBeCommunityGuardian();
        if (agentKey == defaultCommunityGuardian) revert AgentKeyCannotBeCommunityGuardian();

        // Verify agentKey consents to being bound as this account's agent (session) key.
        // (owner = msg.sender/human, set at initialize below; agentKey is NOT the owner.)
        // This proves the agentKey holder (KMS) authorized this creation,
        // preventing a human from binding an arbitrary EOA as the agent key.
        bytes32 agentKeyHash = keccak256(
            abi.encodePacked("ACCEPT_AGENT_KEY", block.chainid, address(this), agentKey, msg.sender, agentId, deadline)
        ).toEthSignedMessageHash();
        (address recoveredAgentKey,,) = agentKeyHash.tryRecover(agentKeySig);
        if (recoveredAgentKey != agentKey) revert AgentKeyDidNotAccept();

        // Verify guardian2 signed the agent-specific acceptance hash.
        // Domain "ACCEPT_AGENT_GUARDIAN" (distinct from "ACCEPT_GUARDIAN" used in createAccountWithDefaults)
        // prevents signature reuse across the two creation paths.
        // Including msg.sender (humanOwner), agentId, and deadline prevents reuse across different
        // owners, agents, or after the signature expires.
        bytes32 acceptHash = keccak256(
            abi.encodePacked("ACCEPT_AGENT_GUARDIAN", block.chainid, address(this), agentKey, msg.sender, agentId, deadline)
        ).toEthSignedMessageHash();
        (address recovered,,) = acceptHash.tryRecover(guardian2Sig);
        if (recovered != guardian2) revert GuardianDidNotAccept(guardian2);

        bytes32 cloneSalt = _getAgentSalt(agentKey, msg.sender, agentId);
        account = Clones.predictDeterministicAddress(implementation, cloneSalt);
        if (account.code.length > 0) {
            return account;
        }

        // owner = msg.sender (humanAirAccount), NOT agentKey.
        // agentKey is authorized as a session key separately via SessionKeyValidator.grantSession()
        // (algId 0x08, ALG_SESSION_KEY) after deployment.
        // Guardians: [guardian2, communityGuardian] — 2-of-2.
        // humanAirAccount is the owner but NOT a guardian (avoids owner==guardian constraint).
        AAStarAirAccountBase.InitConfig memory config = _buildDefaultConfig(
            guardian2, address(0), dailyLimit
        );
        // Pre-deploy guard bound to the predicted account address before cloning.
        address guardAddr = _deployGuard(account, config);
        account = Clones.cloneDeterministic(implementation, cloneSalt);
        // v0.17.2: agent accounts are structurally identical to human accounts. Session-key
        // grants happen post-creation via the unified SessionKeyValidator (router algId 0x08).
        AAStarAirAccountV7(payable(account)).initializeAgentAccount(
            entryPoint, msg.sender, config, guardAddr
        );
        _markAccountValid(account);        emit AgentAccountCreated(account, agentKey, msg.sender, agentId, guardian2, dailyLimit);
    }

    /// @notice Predict the address of a future agent account.
    /// @param humanOwner  The human who will call createAgentAccount (msg.sender)
    /// @param agentKey    The agent's signing key address
    /// @param agentId     The bytes32 agent identifier
    function getAgentAddress(
        address humanOwner,
        address agentKey,
        bytes32 agentId
    ) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _getAgentSalt(agentKey, humanOwner, agentId));
    }

    /// @notice Predict address for a default-config account.
    /// @dev With the clone pattern, the address depends only on implementation + salt (not guardian config).
    function getAddressWithDefaults(
        address owner,
        uint256 salt,
        address guardian1,
        address guardian2,
        uint256 /* dailyLimit */
    ) public view returns (address) {
        // Security fix "c": the guardian identities (already in this view's signature) are now folded
        // into the salt, so the predicted address matches createAccountWithDefaults for the SAME
        // guardian set and differs for any other set. SDKs that call this view already pass guardians,
        // so they need no change; only an SDK that replicates the CREATE2 salt off-chain must add them.
        return Clones.predictDeterministicAddress(implementation, _getDefaultSalt(owner, salt, guardian1, guardian2));
    }

    // ─── Internal ───────────────────────────────────────────────────

    function _buildDefaultConfig(
        address guardian1,
        address guardian2,
        uint256 dailyLimit
    ) internal view returns (AAStarAirAccountBase.InitConfig memory) {
        // Default approved algorithms: ECDSA, BLS, P256, Cumulative T2/T3, WebAuthn T2/T3, Combined T1, Weighted, SessionKey
        uint8[] memory algIds = new uint8[](10);
        algIds[0] = 0x02; // ALG_ECDSA
        algIds[1] = 0x01; // ALG_BLS
        algIds[2] = 0x03; // ALG_P256
        algIds[3] = 0x04; // ALG_CUMULATIVE_T2 (P256 raw + BLS)
        algIds[4] = 0x05; // ALG_CUMULATIVE_T3 (P256 raw + BLS + Guardian)
        algIds[5] = 0x06; // ALG_COMBINED_T1 (P256 + ECDSA zero-trust)
        algIds[6] = 0x07; // ALG_WEIGHTED (resolves to 0x02/0x04/0x05 based on weight)
        algIds[7] = 0x08; // ALG_SESSION_KEY (time-limited session key)
        algIds[8] = 0x09; // ALG_CUMULATIVE_T2_WA (WebAuthn passkey + BLS)
        algIds[9] = 0x0a; // ALG_CUMULATIVE_T3_WA (WebAuthn passkey + BLS + Guardian)

        // minDailyLimit = 10% of dailyLimit — stolen ECDSA key cannot reduce limit below this floor
        uint256 minLimit = dailyLimit / 10;

        // Use chain-specific defaults set at factory deploy time; copy from storage to memory
        uint256 n = _defaultTokenAddresses.length;
        address[] memory tokens = new address[](n);
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _defaultTokenAddresses[i];
            configs[i] = _defaultTokenConfigs[i];
        }

        return AAStarAirAccountBase.InitConfig({
            guardians: [guardian1, guardian2, defaultCommunityGuardian],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: dailyLimit,
            approvedAlgIds: algIds,
            minDailyLimit: minLimit,
            initialTokens: tokens,
            initialTokenConfigs: configs,
            tier1Limit: 0,  // #161: defaults path leaves native-ETH tiering unset (unchanged behavior); owner may setTierLimits() later
            tier2Limit: 0
        });
    }

    /// @dev Hash ALL config fields that determine account security posture.
    ///      Binding the full InitConfig prevents a front-runner from pre-deploying the same
    ///      counterfactual address with a weakened config (e.g. an irreversible high
    ///      minDailyLimit floor, an empty approvedAlgIds whitelist, or stripped token limits)
    ///      while keeping guardians + dailyLimit identical to collide on the address.
    function _getConfigHash(AAStarAirAccountBase.InitConfig memory config) internal pure returns (bytes32) {
        // ownerP256X/Y are NOT in InitConfig (issue #155): passkey is passed as explicit createAccount
        // params and folded into the clone salt directly (alongside this hash) rather than here,
        // so the InitConfig hash itself remains stable across passkey rotations.
        return keccak256(abi.encode(
            config.guardians,
            config.guardianP256X,
            config.guardianP256Y,
            config.dailyLimit,
            config.approvedAlgIds,
            config.minDailyLimit,
            config.initialTokens,
            config.initialTokenConfigs,
            config.tier1Limit,  // #161: bind native-ETH tier profile so it can't be front-run away
            config.tier2Limit
        ));
    }

    /// @notice Public view of the InitConfig hash the factory folds into the CREATE2 clone salt and the
    ///         relay-mode ownerSig digest. Exposes the internal `_getConfigHash` so SDKs/relayers hash the
    ///         SAME preimage on-chain instead of replicating it off-chain (one wrong byte => wrong address
    ///         / InvalidOwnerSignature). #155.
    function getConfigHash(AAStarAirAccountBase.InitConfig memory config) external pure returns (bytes32) {
        return _getConfigHash(config);
    }

    /// @notice Public view of the relay-mode CREATE_ACCOUNT digest — the INNER hash, BEFORE EIP-191.
    ///         The owner signs this via personal_sign / EIP-191 (the relay branch applies
    ///         `.toEthSignedMessageHash()` before `ecrecover`), and that signature is passed as
    ///         `createAccount(..., ownerSig)` in relay mode (msg.sender != owner). Lets SDKs/relayers read
    ///         the exact digest from chain rather than reconstruct `_getConfigHash` + the preimage. #155.
    /// @dev    deadline must be strictly greater than block.timestamp in relay mode. Passing deadline=0
    ///         always causes createAccount to revert with SignatureExpired (block.timestamp > 0 is always
    ///         true). deadline is ignored only in direct mode (ownerSig empty).
    function hashCreateAccount(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config,
        bytes32 ownerP256X,
        bytes32 ownerP256Y,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return keccak256(abi.encode(
            "CREATE_ACCOUNT",
            block.chainid,
            address(this),
            owner,
            salt,
            ownerP256X,
            ownerP256Y,
            _getConfigHash(config),
            nonce,
            deadline
        ));
    }

    /// @dev #82 size recovery: deduplicate the three identical `new AAStarGlobalGuard(...)` sites
    ///      into ONE so the guard creation code is embedded once, not three times. The uint128
    ///      packing of TokenConfig (#82) added masking codegen that, embedded 3×, tipped this
    ///      factory's initcode over the EIP-3860 limit; collapsing the sites recovers the headroom.
    ///      Behavior is identical — every caller passed the same five constructor arguments.
    function _deployGuard(address account, AAStarAirAccountBase.InitConfig memory config)
        private
        returns (address)
    {
        return address(new AAStarGlobalGuard(
            account,
            config.dailyLimit,
            config.minDailyLimit,
            config.initialTokens,
            config.initialTokenConfigs
        ));
    }

    /// @dev Internal salt for createAccount/getAddress: binds address to owner + salt + configHash.
    function _getSalt(address owner, uint256 salt, bytes32 configHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt, configHash));
    }

    /// @dev Internal salt for createAccountWithDefaults/getAddressWithDefaults. Binds owner + salt +
    ///      BOTH guardian identities into the CREATE2 address (security fix "c").
    ///
    ///      Why guardians MUST be in the address: the ACCEPT_GUARDIAN acceptance digest proves the
    ///      guardians consented, but it does NOT bind them to the OWNER's choice — nothing in the old
    ///      (owner, salt)-only salt or the digest committed the owner to a specific guardian set. A
    ///      mempool front-runner could therefore call createAccountWithDefaults with the victim's
    ///      (owner, salt) but the ATTACKER's own guardians (self-signing the acceptance digest, which
    ///      omitted guardian identities), deploy at the victim's counterfactual address, and then seize
    ///      the account via 2-of-3 social recovery. Folding guardian1+guardian2 into the salt makes any
    ///      different guardian set resolve to a DIFFERENT address, so an attacker can no longer land on
    ///      the victim's (pre-funded) address without the victim's guardians' acceptance signatures.
    function _getDefaultSalt(address owner, uint256 salt, address guardian1, address guardian2)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, salt, guardian1, guardian2));
    }

    /// @dev Agent account salt: namespaced with "AASTAR_AGENT_V1" to prevent cross-namespace
    ///      collision with createAccountWithDefaults which uses _getDefaultSalt(owner, salt).
    ///      Including humanOwner and agentId ensures each (human, agent, agentId) triple is unique.
    function _getAgentSalt(address agentKey, address humanOwner, bytes32 agentId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("AASTAR_AGENT_V1", agentKey, humanOwner, agentId));
    }

    // ─── ERC-7828 Chain-Specific Address (M7.4) ─────────────────────

    /// @notice ERC-7828: Returns a chain-qualified address identifier.
    ///         Enables cross-chain address disambiguation for accounts deployed at the same address
    ///         on multiple L2s via CREATE2 with the same salt.
    /// @dev keccak256(account ++ chainId) — unique per (address, chain) pair.
    ///      Use for canonical cross-chain account references.
    /// @param account The account address to qualify
    /// @return Chain-qualified address bytes32 identifier
    function getChainQualifiedAddress(address account) external view returns (bytes32) {
        return keccak256(abi.encodePacked(account, block.chainid));
    }

    /// @notice Predict account address AND its chain-qualified identifier in one call.
    /// @dev Convenience function for frontends building cross-chain address registries.
    function getAddressWithChainId(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config,
        bytes32 ownerP256X,
        bytes32 ownerP256Y
    ) external view returns (address account, bytes32 chainQualified) {
        account = Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt, keccak256(abi.encode(_getConfigHash(config), ownerP256X, ownerP256Y))));
        chainQualified = keccak256(abi.encodePacked(account, block.chainid));
    }
}
