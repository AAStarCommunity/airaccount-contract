// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title SessionKeyValidator — Unified Session Key (algId 0x08) for AAStar AirAccount
/// @notice Implements scoped, time-limited delegated signing keys for ERC-4337 accounts.
///         Supports two session-key kinds:
///           - ECDSA session (DApp / KMS-held key):  [0x08][account(20)][key(20)][ECDSA(65)] = 106 B
///             (router strips algId byte; this validator receives the trailing 105 B)
///           - P256 session (user's Passkey):        [0x08][account(20)][keyX(32)][keyY(32)][r(32)][s(32)] = 149 B
///             (validator receives the trailing 148 B)
///
/// @dev v0.17.2 supersedes the prior split between this contract (M6.4 simple session)
///      and the deleted AgentSessionKeyValidator (M7+ agent session). The unified Session
///      struct carries both classic single-target scope AND richer agent-grade controls
///      (velocity, multi-target callTargets[], selectorAllowlist[]).
///
/// @dev ERC-4337 / EIP-7562 mempool storage rules: validate() MUST NOT SSTORE. Velocity is
///      enforced in two halves:
///        - validate() does a view-only "would exceed" check (early reject)
///        - base._enforceGuard calls recordCallForVelocity() in execute phase (state mutation)
///      Cross-bundle race (2 in-flight UserOps both pass validation, then both execute) is an
///      accepted limitation — same shape as expiry checks at validation time.
///
/// @dev Scope enforcement happens entirely on execute side via base._enforceGuard staticcalling
///      checkSessionScope(). Reverts with specific errors on violation.
contract SessionKeyValidator is IAAStarAlgorithm {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Semantic version of this module deployment. Used by SDKs for programmatic version detection.
    string public constant MODULE_VERSION = "0.17.2";

    // ─── Constants ────────────────────────────────────────────────────

    /// @dev EIP-7212 P256 verification precompile
    address internal constant P256_VERIFIER = address(0x100);

    /// @dev floor((n-1)/2) for the secp256r1 order n — the low-S bound. EIP-7212/RIP-7696 do NOT
    ///      enforce canonical (low-S) signatures, so both (r,s) and (r,n-s) pass the precompile.
    ///      We reject high-S here to prevent session-signature malleability (issue #78). Mirrors
    ///      AAStarAirAccountBase.SECP256R1_N_OVER_2 (independently verified identical value).
    uint256 internal constant SECP256R1_N_OVER_2 =
        0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8;

    /// @dev Maximum session duration: 7 days. revokeSession can always cancel early.
    uint48 internal constant MAX_SESSION_DURATION = 7 days;

    /// @dev Gas-bomb caps on dynamic arrays.
    uint256 internal constant MAX_CALL_TARGETS = 20;
    uint256 internal constant MAX_SELECTORS    = 30;

    /// @dev Per-account session-key cap (issue #83). Bounds unbounded session-key
    ///      registration (storage griefing / DoS by a buggy dApp or compromised owner).
    ///      Counts ECDSA + P256 sessions together. A revoke frees a slot.
    uint256 internal constant MAX_SESSION_KEYS_PER_ACCOUNT = 50;

    /// @dev sessionType tags carried in the transient identifier bytes32 (set by base).
    uint8 internal constant SESSION_TYPE_ECDSA = 0x01;
    uint8 internal constant SESSION_TYPE_P256  = 0x02;

    // ─── Structs ──────────────────────────────────────────────────────

    struct Session {
        uint48    expiry;
        address   contractScope;       // legacy single-target; ignored if callTargets non-empty
        bytes4    selectorScope;       // legacy single-selector; ignored if selectorAllowlist non-empty
        bool      revoked;
        uint16    velocityLimit;       // 0 = unlimited
        uint32    velocityWindow;      // seconds
        address[] callTargets;         // non-empty: dest must be in list (priority over contractScope)
        bytes4[]  selectorAllowlist;   // non-empty: selector must be in list (priority over selectorScope)
    }

    /// @dev Sliding-window velocity counter state (issue #57). `callCount` is the number of
    ///      calls in the current window anchored at `windowStart`; `prevCount` is the previous
    ///      window's final count, weighted into the rolling estimate to kill the boundary burst.
    struct SessionState {
        uint256 callCount;
        uint256 windowStart;
        uint256 prevCount;
    }

    // ─── Storage ──────────────────────────────────────────────────────

    /// @notice ECDSA session registry: account → sessionKey → Session
    mapping(address => mapping(address => Session)) internal _sessions;

    /// @notice P256 session registry: account → keccak256(keyX||keyY) → Session
    mapping(address => mapping(bytes32 => Session)) internal _sessions_p256;

    /// @notice Velocity counters (execute-phase state).
    mapping(address => mapping(address => SessionState)) public sessionStates;
    mapping(address => mapping(bytes32 => SessionState)) public sessionStates_p256;

    /// @notice Revocation nonces. Included in grant typed-hash so prior owner sigs invalidated on revoke.
    mapping(address => mapping(address => uint256)) public grantNonces;
    mapping(address => mapping(bytes32 => uint256)) public grantNonces_p256;

    /// @notice Number of session-key slots currently consumed per account (issue #83).
    ///         Counts ECDSA and P256 sessions together; enforced against
    ///         MAX_SESSION_KEYS_PER_ACCOUNT on grant, released on revoke.
    mapping(address => uint256) public sessionKeyCount;

    // ─── Events ──────────────────────────────────────────────────────

    event SessionGranted(address indexed account, address indexed sessionKey, Session cfg);
    event SessionRevoked(address indexed account, address indexed sessionKey);
    event P256SessionGranted(address indexed account, bytes32 indexed p256KeyHash, Session cfg);
    event P256SessionRevoked(address indexed account, bytes32 indexed p256KeyHash);

    // ─── Errors ──────────────────────────────────────────────────────

    error NotAccountOwner();
    /// @dev Distinguishes "account does not expose owner() at all" from "caller is not the owner".
    ///      Raised by _ownerOf when the staticcall fails or returns no data — i.e. the address
    ///      is not an AirAccount-shaped contract. Codex PR #61 LOW #3 (David, 2026-05-30):
    ///      separate this from NotAccountOwner so debugging is unambiguous.
    error NotAirAccount();
    error NotBoundAccount();
    error SessionAlreadyExists();
    error SessionNotFound();
    error SessionRevoked_();
    error SessionExpired();
    error InvalidExpiry();
    error ExpiryInPast();
    error ExpiryTooFar();
    error InvalidVelocityWindow();
    error MaxTargetsExceeded();
    error MaxSelectorsExceeded();
    error CallTargetForbidden(address dest);
    error SelectorForbidden(bytes4 selector);
    error VelocityLimitExceeded();
    error InvalidSessionType(uint8 sessionType);
    /// @dev Per-account session-key cap reached (issue #83). Revoke an existing session to free a slot.
    error TooManySessionKeys();

    // ─── IAAStarAlgorithm.validate() — view, mempool-safe ────────────

    /// @inheritdoc IAAStarAlgorithm
    /// @dev Dispatches by signature length: 105 → ECDSA, 148 → P256. View-only.
    function validate(bytes32 userOpHash, bytes calldata signature)
        external view override returns (uint256 validationData)
    {
        if (signature.length == 105) return _validateECDSASession(userOpHash, signature);
        if (signature.length == 148) return _validateP256Session(userOpHash, signature);
        return 1;
    }

    function _validateECDSASession(bytes32 userOpHash, bytes calldata sig) internal view returns (uint256) {
        address account    = address(bytes20(sig[0:20]));
        address sessionKey = address(bytes20(sig[20:40]));

        Session storage s = _sessions[account][sessionKey];
        if (s.expiry == 0) return 1;
        if (s.revoked) return 1;
        if (block.timestamp >= s.expiry) return 1;

        // Velocity early-reject (view, would-exceed). SSTORE happens in recordCallForVelocity (execute phase).
        // Mirrors the sliding-window estimate used on the execute side (issue #57).
        if (s.velocityLimit > 0 &&
            _velocityWouldExceed(sessionStates[account][sessionKey], s.velocityLimit, s.velocityWindow)) {
            return 1;
        }

        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, sig[40:105]);
        if (err != ECDSA.RecoverError.NoError || recovered != sessionKey) return 1;

        return 0;
    }

    function _validateP256Session(bytes32 userOpHash, bytes calldata sig) internal view returns (uint256) {
        address account = address(bytes20(sig[0:20]));
        bytes32 keyX    = bytes32(sig[20:52]);
        bytes32 keyY    = bytes32(sig[52:84]);
        bytes32 r       = bytes32(sig[84:116]);
        bytes32 s_val   = bytes32(sig[116:148]);
        // Reject high-S (malleability): EIP-7212 doesn't enforce canonical signatures (issue #78).
        if (uint256(s_val) > SECP256R1_N_OVER_2) return 1;
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(keyX, keyY)));

        Session storage s = _sessions_p256[account][keyHash];
        if (s.expiry == 0) return 1;
        if (s.revoked) return 1;
        if (block.timestamp >= s.expiry) return 1;

        if (s.velocityLimit > 0 &&
            _velocityWouldExceed(sessionStates_p256[account][keyHash], s.velocityLimit, s.velocityWindow)) {
            return 1;
        }

        // EIP-7212 P256 verification (sha256-wrapped userOpHash)
        bytes32 msgHash = sha256(abi.encodePacked(userOpHash));
        (bool ok, bytes memory result) = P256_VERIFIER.staticcall(abi.encode(msgHash, r, s_val, keyX, keyY));
        if (!ok || result.length < 32 || abi.decode(result, (uint256)) != 1) return 1;

        return 0;
    }

    // ─── Grant API (ECDSA) ───────────────────────────────────────────

    /// @notice Grant an ECDSA session via off-chain owner signature (gasless DApp on-boarding).
    function grantSession(
        address account,
        address sessionKey,
        Session calldata cfg,
        bytes calldata ownerSig
    ) external {
        _validateCfg(cfg);
        _checkNotExists(account, sessionKey);

        bytes32 grantHash = _buildGrantHash(account, sessionKey, cfg);
        address recovered = grantHash.recover(ownerSig);
        if (recovered != _ownerOf(account)) revert NotAccountOwner();

        _reserveSlot(account, _sessions[account][sessionKey]);
        _storeSession(account, sessionKey, cfg);
    }

    /// @notice Grant an ECDSA session by direct owner call. Owner EOA only.
    /// @dev Codex P1 round 3 (2026-05-30): the v0.17.2 round 2 fix briefly accepted
    ///      `msg.sender == account` to support "owner signs a UserOp whose calldata is
    ///      grantSessionDirect" — but that opens a confused-deputy attack: an existing
    ///      unscoped session key (callTargets empty + selectorAllowlist empty) can have the
    ///      account call this function via execute() and mint itself a new session, bypassing
    ///      owner re-authorisation entirely. So we revert to "owner-only" here. For UserOp /
    ///      gasless on-boarding flows, callers MUST use `grantSession` with the off-chain
    ///      owner signature (relayer-submittable, no account self-call required).
    function grantSessionDirect(
        address account,
        address sessionKey,
        Session calldata cfg
    ) external {
        if (msg.sender != _ownerOf(account)) revert NotAccountOwner();
        _validateCfg(cfg);
        _checkNotExists(account, sessionKey);
        _reserveSlot(account, _sessions[account][sessionKey]);
        _storeSession(account, sessionKey, cfg);
    }

    /// @dev Revoke remains caller=owner OR caller=account: revoking a session never grants
    ///      authority — it only removes it. Letting a session key self-revoke (by causing
    ///      the account to call revokeSession via execute) is actually a beneficial property
    ///      (a compromised session key can be turned off promptly without an EOA tx).
    function revokeSession(address account, address sessionKey) external {
        if (msg.sender != _ownerOf(account) && msg.sender != account) revert NotAccountOwner();
        Session storage s = _sessions[account][sessionKey];
        _releaseSlot(account, s);
        s.revoked = true;
        grantNonces[account][sessionKey]++;
        emit SessionRevoked(account, sessionKey);
    }

    // ─── Grant API (P256) ────────────────────────────────────────────

    function grantP256Session(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        Session calldata cfg,
        bytes calldata ownerSig
    ) external {
        _validateCfg(cfg);
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(p256KeyX, p256KeyY)));
        _checkP256NotExists(account, keyHash);

        bytes32 grantHash = _buildP256GrantHash(account, p256KeyX, p256KeyY, cfg);
        address recovered = grantHash.recover(ownerSig);
        if (recovered != _ownerOf(account)) revert NotAccountOwner();

        _reserveSlot(account, _sessions_p256[account][keyHash]);
        _storeP256Session(account, keyHash, cfg);
    }

    /// @notice Grant a P256 session by direct owner call. Owner EOA only.
    /// @dev See grantSessionDirect for why `msg.sender == account` is NOT accepted (round 3 fix).
    function grantP256SessionDirect(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        Session calldata cfg
    ) external {
        if (msg.sender != _ownerOf(account)) revert NotAccountOwner();
        _validateCfg(cfg);
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(p256KeyX, p256KeyY)));
        _checkP256NotExists(account, keyHash);
        _reserveSlot(account, _sessions_p256[account][keyHash]);
        _storeP256Session(account, keyHash, cfg);
    }

    /// @dev Revoke: same rationale as revokeSession — caller=owner OR caller=account both ok.
    function revokeP256Session(address account, bytes32 p256KeyX, bytes32 p256KeyY) external {
        if (msg.sender != _ownerOf(account) && msg.sender != account) revert NotAccountOwner();
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(p256KeyX, p256KeyY)));
        Session storage s = _sessions_p256[account][keyHash];
        _releaseSlot(account, s);
        s.revoked = true;
        grantNonces_p256[account][keyHash]++;
        emit P256SessionRevoked(account, keyHash);
    }

    // ─── Execute-side Enforcement (called from base._enforceGuard) ──

    /// @notice Enforce session scope. View; reverts on violation.
    /// @param account           The AirAccount whose session is being checked.
    /// @param sessionKeyOrHash  ECDSA: lower 20 bytes = key address. P256: full 32 bytes = key hash.
    /// @param sessionType       SESSION_TYPE_ECDSA (0x01) or SESSION_TYPE_P256 (0x02).
    /// @param dest              The destination contract of the current call.
    /// @param selector          The function selector of the current call.
    function checkSessionScope(
        address account,
        bytes32 sessionKeyOrHash,
        uint8   sessionType,
        address dest,
        bytes4  selector
    ) external view {
        Session storage s;
        if (sessionType == SESSION_TYPE_ECDSA) {
            s = _sessions[account][address(uint160(uint256(sessionKeyOrHash)))];
        } else if (sessionType == SESSION_TYPE_P256) {
            s = _sessions_p256[account][sessionKeyOrHash];
        } else {
            revert InvalidSessionType(sessionType);
        }

        if (s.expiry == 0) revert SessionNotFound();
        if (s.revoked) revert SessionRevoked_();
        if (block.timestamp >= s.expiry) revert SessionExpired();

        // Target scope: callTargets array takes priority over contractScope.
        if (s.callTargets.length > 0) {
            if (!_containsAddr(s.callTargets, dest)) revert CallTargetForbidden(dest);
        } else if (s.contractScope != address(0) && dest != s.contractScope) {
            revert CallTargetForbidden(dest);
        }

        // Selector scope: selectorAllowlist array takes priority over selectorScope.
        if (s.selectorAllowlist.length > 0) {
            if (!_containsSel(s.selectorAllowlist, selector)) revert SelectorForbidden(selector);
        } else if (s.selectorScope != bytes4(0) && selector != s.selectorScope) {
            revert SelectorForbidden(selector);
        }
    }

    /// @notice Increment velocity counter; reverts if limit exceeded.
    /// @dev Only callable when msg.sender is the bound account (anti-griefing).
    ///      Called from base._enforceGuard in execute / executeBatch / executeFromExecutor.
    ///      No-op for sessions with velocityLimit == 0.
    function recordCallForVelocity(
        address account,
        bytes32 sessionKeyOrHash,
        uint8   sessionType
    ) external {
        if (msg.sender != account) revert NotBoundAccount();

        Session storage s;
        SessionState storage state;
        if (sessionType == SESSION_TYPE_ECDSA) {
            address k = address(uint160(uint256(sessionKeyOrHash)));
            s     = _sessions[account][k];
            state = sessionStates[account][k];
        } else if (sessionType == SESSION_TYPE_P256) {
            s     = _sessions_p256[account][sessionKeyOrHash];
            state = sessionStates_p256[account][sessionKeyOrHash];
        } else {
            revert InvalidSessionType(sessionType);
        }

        if (s.velocityLimit == 0) return; // unlimited

        // Sliding-window counter (issue #57). Roll the stored window forward to `now`, then
        // gate on the weighted estimate so the rolling rate can never exceed velocityLimit —
        // unlike the old fixed window, which allowed up to 2*limit-1 calls across a boundary.
        (uint256 ws, uint256 cc, uint256 pc, uint256 elapsed) =
            _rollWindow(state.windowStart, state.callCount, state.prevCount, s.velocityWindow, block.timestamp);
        if (_slidingEstimate(cc, pc, s.velocityWindow, elapsed) >= s.velocityLimit) revert VelocityLimitExceeded();
        state.windowStart = ws;
        state.callCount   = cc + 1;
        state.prevCount   = pc;
    }

    // ─── View accessors ──────────────────────────────────────────────

    function getSession(address account, address sessionKey) external view returns (Session memory) {
        return _sessions[account][sessionKey];
    }

    function getP256Session(address account, bytes32 p256KeyHash) external view returns (Session memory) {
        return _sessions_p256[account][p256KeyHash];
    }

    function isSessionActive(address account, address sessionKey) external view returns (bool) {
        Session storage s = _sessions[account][sessionKey];
        return s.expiry != 0 && !s.revoked && block.timestamp < s.expiry;
    }

    function isP256SessionActive(address account, bytes32 p256KeyX, bytes32 p256KeyY) external view returns (bool) {
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(p256KeyX, p256KeyY)));
        Session storage s = _sessions_p256[account][keyHash];
        return s.expiry != 0 && !s.revoked && block.timestamp < s.expiry;
    }

    function buildGrantHash(address account, address sessionKey, Session calldata cfg)
        external view returns (bytes32)
    {
        return _buildGrantHash(account, sessionKey, cfg);
    }

    function buildP256GrantHash(address account, bytes32 p256KeyX, bytes32 p256KeyY, Session calldata cfg)
        external view returns (bytes32)
    {
        return _buildP256GrantHash(account, p256KeyX, p256KeyY, cfg);
    }

    // ─── Internal helpers ────────────────────────────────────────────

    /// @dev Reserve a session-key slot against the per-account cap (issue #83). `existing` is the
    ///      storage slot being (re)granted — guaranteed inactive here by the prior _checkNotExists.
    ///      If the slot already holds a live count (granted previously, expired but never revoked),
    ///      the re-grant reuses that count and consumes nothing new. Otherwise consume one slot,
    ///      reverting if the per-account cap is already reached.
    function _reserveSlot(address account, Session storage existing) internal {
        if (existing.expiry != 0 && !existing.revoked) return; // re-grant of expired-unrevoked slot: reuse count
        uint256 c = sessionKeyCount[account];
        if (c >= MAX_SESSION_KEYS_PER_ACCOUNT) revert TooManySessionKeys();
        sessionKeyCount[account] = c + 1;
    }

    /// @dev Release a session-key slot on revoke (issue #83). Only decrements when the slot
    ///      currently holds a live count, making repeated/already-revoked revokes idempotent.
    function _releaseSlot(address account, Session storage existing) internal {
        if (existing.expiry != 0 && !existing.revoked && sessionKeyCount[account] > 0) {
            sessionKeyCount[account] -= 1;
        }
    }

    /// @dev Sliding-window normalisation (issue #57 / KI-4). Rolls the stored counter state to
    ///      `nowTs` without mutating storage: drops both counts after two stale windows, otherwise
    ///      shifts the current count into `prevCount` once a full window has elapsed. Returns the
    ///      (advanced) window start, current count, previous count, and elapsed seconds in window.
    ///      Caller guarantees `window > 0` (enforced by _validateCfg when velocityLimit > 0).
    function _rollWindow(uint256 windowStart, uint256 callCount, uint256 prevCount, uint256 window, uint256 nowTs)
        internal pure returns (uint256 ws, uint256 cc, uint256 pc, uint256 elapsed)
    {
        if (nowTs <= windowStart) return (windowStart, callCount, prevCount, 0);
        uint256 e = nowTs - windowStart;
        if (e >= 2 * window) return (nowTs, 0, 0, 0);                              // both windows stale
        if (e >= window)      return (windowStart + window, 0, callCount, e - window); // rolled exactly one window
        return (windowStart, callCount, prevCount, e);
    }

    /// @dev Weighted call-count estimate over the trailing `window` seconds: the current window's
    ///      count plus the previous window's count scaled by the fraction still inside the sliding
    ///      view, (window - elapsed)/window. Integer division floors (slightly favours the caller).
    function _slidingEstimate(uint256 cc, uint256 pc, uint256 window, uint256 elapsed)
        internal pure returns (uint256)
    {
        return cc + (pc * (window - elapsed)) / window;
    }

    /// @dev View-only velocity gate mirroring recordCallForVelocity's sliding-window estimate.
    function _velocityWouldExceed(SessionState storage state, uint256 limit, uint256 window)
        internal view returns (bool)
    {
        (, uint256 cc, uint256 pc, uint256 elapsed) =
            _rollWindow(state.windowStart, state.callCount, state.prevCount, window, block.timestamp);
        return _slidingEstimate(cc, pc, window, elapsed) >= limit;
    }

    function _validateCfg(Session calldata cfg) internal view {
        if (cfg.expiry == 0) revert InvalidExpiry();
        if (block.timestamp >= cfg.expiry) revert ExpiryInPast();
        if (cfg.expiry > block.timestamp + MAX_SESSION_DURATION) revert ExpiryTooFar();
        if (cfg.velocityLimit > 0 && cfg.velocityWindow == 0) revert InvalidVelocityWindow();
        if (cfg.callTargets.length > MAX_CALL_TARGETS) revert MaxTargetsExceeded();
        if (cfg.selectorAllowlist.length > MAX_SELECTORS) revert MaxSelectorsExceeded();
    }

    function _checkNotExists(address account, address sessionKey) internal view {
        Session storage s = _sessions[account][sessionKey];
        if (s.expiry != 0 && !s.revoked && block.timestamp < s.expiry) revert SessionAlreadyExists();
    }

    function _checkP256NotExists(address account, bytes32 keyHash) internal view {
        Session storage s = _sessions_p256[account][keyHash];
        if (s.expiry != 0 && !s.revoked && block.timestamp < s.expiry) revert SessionAlreadyExists();
    }

    function _storeSession(address account, address sessionKey, Session calldata cfg) internal {
        _sessions[account][sessionKey] = cfg;
        emit SessionGranted(account, sessionKey, cfg);
    }

    function _storeP256Session(address account, bytes32 keyHash, Session calldata cfg) internal {
        _sessions_p256[account][keyHash] = cfg;
        emit P256SessionGranted(account, keyHash, cfg);
    }

    /// @dev GRANT_SESSION_V2 typed-hash domain (EIP-191). Includes all fields including
    ///      hashes of the dynamic arrays so the owner sig binds to the full scope.
    function _buildGrantHash(address account, address sessionKey, Session calldata cfg)
        internal view returns (bytes32)
    {
        bytes32 inner = keccak256(abi.encode(
            "GRANT_SESSION_V2",
            block.chainid,
            address(this),
            account,
            sessionKey,
            cfg.expiry,
            cfg.contractScope,
            cfg.selectorScope,
            cfg.velocityLimit,
            cfg.velocityWindow,
            keccak256(abi.encodePacked(cfg.callTargets)),
            keccak256(abi.encodePacked(cfg.selectorAllowlist)),
            grantNonces[account][sessionKey]
        ));
        return inner.toEthSignedMessageHash();
    }

    function _buildP256GrantHash(address account, bytes32 keyX, bytes32 keyY, Session calldata cfg)
        internal view returns (bytes32)
    {
        bytes32 keyHash = _p256StorageKey(keccak256(abi.encodePacked(keyX, keyY)));
        bytes32 inner = keccak256(abi.encode(
            "GRANT_P256_SESSION_V2",
            block.chainid,
            address(this),
            account,
            keyX,
            keyY,
            cfg.expiry,
            cfg.contractScope,
            cfg.selectorScope,
            cfg.velocityLimit,
            cfg.velocityWindow,
            keccak256(abi.encodePacked(cfg.callTargets)),
            keccak256(abi.encodePacked(cfg.selectorAllowlist)),
            grantNonces_p256[account][keyHash]
        ));
        return inner.toEthSignedMessageHash();
    }

    /// @dev P256 storage key: truncate to lower 248 bits so base's taggedSessionKey
    ///      lookup (which uses the top byte for sessionType tag) matches storage. The
    ///      8-bit entropy loss is cryptographically negligible (still 2^124 collision).
    function _p256StorageKey(bytes32 fullHash) internal pure returns (bytes32) {
        return bytes32(uint256(fullHash) & type(uint248).max);
    }

    function _containsAddr(address[] storage arr, address val) internal view returns (bool) {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            if (arr[i] == val) return true;
        }
        return false;
    }

    function _containsSel(bytes4[] storage arr, bytes4 val) internal view returns (bool) {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            if (arr[i] == val) return true;
        }
        return false;
    }

    /// @dev Read owner address from account (account must expose `owner()` view).
    ///      Reverts NotAirAccount if the address is not an AirAccount-shaped contract — this
    ///      separates "wrong address entirely" from "right account, wrong caller" (NotAccountOwner).
    function _ownerOf(address account) internal view returns (address) {
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) revert NotAirAccount();
        return abi.decode(data, (address));
    }
}
