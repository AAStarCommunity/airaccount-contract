// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title SessionKeyValidator — algId 0x08 Time-Limited Session Key Authorization
/// @notice Implements temporary delegated signing for ERC-4337 accounts.
///         Supports two session key types:
///           - ECDSA session (DApp server holds key): [account(20)][key(20)][ECDSASig(65)] = 105 bytes
///           - P256 session (user's own Passkey):    [account(20)][keyX(32)][keyY(32)][r(32)][s(32)] = 148 bytes
///
/// @dev Architecture:
///      - Standalone validator, registered in AAStarValidator for algId 0x08
///      - Session data keyed by (account, sessionKey/p256KeyHash)
///      - Owner can grant sessions off-chain (signed message) or directly on-chain
///      - Tier: session key ops are Tier 1 — the session itself was authorized by owner
///
/// @dev Scope enforcement: contractScope and selectorScope are stored here and enforced
///      on-chain in AAStarAirAccountBase._enforceGuard (execution phase) via transient
///      storage passing of the session key identifier.
///
/// @dev Spend cap: validate() is a view function (ERC-4337 constraint), so on-chain
///      spend tracking is impossible at validation time. Bundler/DVT nodes enforce caps.
contract SessionKeyValidator is IAAStarAlgorithm {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants ────────────────────────────────────────────────────

    /// @dev EIP-7212 P256 verification precompile
    address internal constant P256_VERIFIER = address(0x100);

    /// @dev Maximum session duration: 7 days. Limits blast radius if a session key is
    ///      compromised while still allowing week-long DApp sessions and travel use cases.
    ///      revokeSession can always cancel early; this constant caps accidental long grants.
    uint48 internal constant MAX_SESSION_DURATION = 7 days;

    // ─── Structs ──────────────────────────────────────────────────────

    struct Session {
        uint48  expiry;           // Unix timestamp; 0 = session does not exist
        address contractScope;    // address(0) = any dest allowed
        bytes4  selectorScope;    // bytes4(0) = any selector allowed
        bool    revoked;          // owner can revoke before expiry
    }

    // ─── Storage ──────────────────────────────────────────────────────

    /// @notice ECDSA session registry: account → sessionKeyAddress → Session
    mapping(address => mapping(address => Session)) public sessions;

    /// @notice P256 session registry: account → keccak256(keyX||keyY) → Session
    ///         Allows user's own Passkey (WebAuthn P256) to act as a scoped session key.
    mapping(address => mapping(bytes32 => Session)) public sessions_p256;

    /// @notice Revocation nonce: incremented on each revokeSession call.
    ///         Included in the grant hash so prior grant signatures become invalid after revocation.
    mapping(address => mapping(address => uint256)) public grantNonces;

    /// @notice Revocation nonce for P256 sessions.
    mapping(address => mapping(bytes32 => uint256)) public grantNonces_p256;

    // ─── Events ──────────────────────────────────────────────────────

    event SessionGranted(
        address indexed account,
        address indexed sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    );
    event SessionRevoked(address indexed account, address indexed sessionKey);

    event P256SessionGranted(
        address indexed account,
        bytes32 indexed p256KeyHash,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    );
    event P256SessionRevoked(address indexed account, bytes32 indexed p256KeyHash);

    // ─── Errors ──────────────────────────────────────────────────────

    error NotAccountOwner();
    error SessionAlreadyExists();
    error ExpiryInPast();
    error InvalidExpiry();
    error ExpiryTooFar();

    // ─── IAAStarAlgorithm ────────────────────────────────────────────

    /// @inheritdoc IAAStarAlgorithm
    /// @dev Dispatches by signature length:
    ///      105 bytes → ECDSA session: [account(20)][key(20)][ECDSASig(65)]
    ///      148 bytes → P256 session:  [account(20)][keyX(32)][keyY(32)][r(32)][s(32)]
    function validate(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view override returns (uint256 validationData) {
        if (signature.length == 105) return _validateECDSASession(userOpHash, signature);
        if (signature.length == 148) return _validateP256Session(userOpHash, signature);
        return 1;
    }

    // ─── ECDSA Session Management ────────────────────────────────────

    /// @notice Grant an ECDSA session via off-chain owner signature (gasless).
    function grantSession(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope,
        bytes calldata ownerSig
    ) external {
        _checkExpiry(expiry);
        _checkNotExists(account, sessionKey);

        bytes32 grantHash = _buildGrantHash(account, sessionKey, expiry, contractScope, selectorScope);
        address recovered = grantHash.recover(ownerSig);
        if (recovered != _ownerOf(account)) revert NotAccountOwner();

        _storeSession(account, sessionKey, expiry, contractScope, selectorScope);
    }

    /// @notice Grant an ECDSA session by direct owner call.
    function grantSessionDirect(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) external {
        if (msg.sender != _ownerOf(account)) revert NotAccountOwner();
        _checkExpiry(expiry);
        _checkNotExists(account, sessionKey);

        _storeSession(account, sessionKey, expiry, contractScope, selectorScope);
    }

    /// @notice Revoke an ECDSA session before its expiry.
    /// @dev Increments grantNonces so any prior ownerSig for this sessionKey becomes invalid.
    function revokeSession(address account, address sessionKey) external {
        if (msg.sender != _ownerOf(account) && msg.sender != account) {
            revert NotAccountOwner();
        }
        sessions[account][sessionKey].revoked = true;
        grantNonces[account][sessionKey]++;
        emit SessionRevoked(account, sessionKey);
    }

    /// @notice Check if an ECDSA session is currently active.
    function isSessionActive(address account, address sessionKey) external view returns (bool) {
        Session memory s = sessions[account][sessionKey];
        return s.expiry != 0 && !s.revoked && block.timestamp < s.expiry;
    }

    /// @notice Build the off-chain signing hash for an ECDSA session grant.
    /// @dev The hash includes the current grantNonce so the owner must re-sign after revocation.
    function buildGrantHash(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) external view returns (bytes32) {
        return _buildGrantHash(account, sessionKey, expiry, contractScope, selectorScope);
    }

    // ─── P256 Session Management ─────────────────────────────────────

    /// @notice Grant a P256 (Passkey/WebAuthn) session via off-chain owner signature.
    ///         Allows user's own P256 passkey to act as a scoped session key.
    ///         More secure than ECDSA sessions: P256 keys are hardware-bound.
    /// @param p256KeyX  P256 public key x-coordinate (32 bytes)
    /// @param p256KeyY  P256 public key y-coordinate (32 bytes)
    function grantP256Session(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope,
        bytes calldata ownerSig
    ) external {
        _checkExpiry(expiry);
        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        _checkP256NotExists(account, keyHash);

        bytes32 grantHash = _buildP256GrantHash(account, p256KeyX, p256KeyY, expiry, contractScope, selectorScope);
        address recovered = grantHash.recover(ownerSig);
        if (recovered != _ownerOf(account)) revert NotAccountOwner();

        _storeP256Session(account, keyHash, expiry, contractScope, selectorScope);
    }

    /// @notice Grant a P256 session by direct owner call.
    function grantP256SessionDirect(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) external {
        if (msg.sender != _ownerOf(account)) revert NotAccountOwner();
        _checkExpiry(expiry);
        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        _checkP256NotExists(account, keyHash);

        _storeP256Session(account, keyHash, expiry, contractScope, selectorScope);
    }

    /// @notice Revoke a P256 session before its expiry.
    /// @dev Increments grantNonces_p256 so any prior ownerSig for this key becomes invalid.
    function revokeP256Session(address account, bytes32 p256KeyX, bytes32 p256KeyY) external {
        if (msg.sender != _ownerOf(account) && msg.sender != account) {
            revert NotAccountOwner();
        }
        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        sessions_p256[account][keyHash].revoked = true;
        grantNonces_p256[account][keyHash]++;
        emit P256SessionRevoked(account, keyHash);
    }

    /// @notice Check if a P256 session is currently active.
    function isP256SessionActive(address account, bytes32 p256KeyX, bytes32 p256KeyY) external view returns (bool) {
        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        Session memory s = sessions_p256[account][keyHash];
        return s.expiry != 0 && !s.revoked && block.timestamp < s.expiry;
    }

    /// @notice Retrieve P256 session by pre-computed key hash (used by _enforceGuard).
    function getP256Session(address account, bytes32 p256KeyHash) external view returns (Session memory) {
        return sessions_p256[account][p256KeyHash];
    }

    /// @notice Build the off-chain signing hash for a P256 session grant.
    function buildP256GrantHash(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) external view returns (bytes32) {
        return _buildP256GrantHash(account, p256KeyX, p256KeyY, expiry, contractScope, selectorScope);
    }

    // ─── Internal: ECDSA ─────────────────────────────────────────────

    function _validateECDSASession(bytes32 userOpHash, bytes calldata sig) internal view returns (uint256) {
        address account    = address(bytes20(sig[0:20]));
        address sessionKey = address(bytes20(sig[20:40]));

        Session memory s = sessions[account][sessionKey];
        if (s.expiry == 0) return 1;
        if (s.revoked) return 1;
        if (block.timestamp >= s.expiry) return 1;

        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, sig[40:105]);
        if (err != ECDSA.RecoverError.NoError || recovered != sessionKey) return 1;

        return 0;
    }

    function _buildGrantHash(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) internal view returns (bytes32) {
        // grantNonces[account][sessionKey] is included so that revoking a session
        // invalidates all prior grant signatures for the same key.
        bytes32 inner = keccak256(abi.encodePacked(
            "GRANT_SESSION",
            block.chainid,
            address(this),
            account,
            sessionKey,
            expiry,
            contractScope,
            selectorScope,
            grantNonces[account][sessionKey]
        ));
        return inner.toEthSignedMessageHash();
    }

    function _storeSession(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) internal {
        sessions[account][sessionKey] = Session({
            expiry:        expiry,
            contractScope: contractScope,
            selectorScope: selectorScope,
            revoked:       false
        });
        emit SessionGranted(account, sessionKey, expiry, contractScope, selectorScope);
    }

    function _checkNotExists(address account, address sessionKey) internal view {
        Session memory s = sessions[account][sessionKey];
        if (s.expiry != 0 && !s.revoked && block.timestamp < s.expiry) {
            revert SessionAlreadyExists();
        }
    }

    // ─── Internal: P256 ──────────────────────────────────────────────

    function _validateP256Session(bytes32 userOpHash, bytes calldata sig) internal view returns (uint256) {
        address account  = address(bytes20(sig[0:20]));
        bytes32 p256KeyX = bytes32(sig[20:52]);
        bytes32 p256KeyY = bytes32(sig[52:84]);
        bytes32 r        = bytes32(sig[84:116]);
        bytes32 s_val    = bytes32(sig[116:148]);

        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        Session memory s = sessions_p256[account][keyHash];
        if (s.expiry == 0) return 1;
        if (s.revoked) return 1;
        if (block.timestamp >= s.expiry) return 1;

        // P256 signature verification via EIP-7212 precompile (0x100)
        bytes32 msgHash = sha256(abi.encodePacked(userOpHash));
        (bool ok, bytes memory result) = P256_VERIFIER.staticcall(
            abi.encode(msgHash, r, s_val, p256KeyX, p256KeyY)
        );
        if (!ok || result.length < 32 || abi.decode(result, (uint256)) != 1) return 1;

        return 0;
    }

    function _buildP256GrantHash(
        address account,
        bytes32 p256KeyX,
        bytes32 p256KeyY,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) internal view returns (bytes32) {
        bytes32 keyHash = keccak256(abi.encodePacked(p256KeyX, p256KeyY));
        // grantNonces_p256 included so revoking invalidates all prior grant signatures.
        bytes32 inner = keccak256(abi.encodePacked(
            "GRANT_P256_SESSION",
            block.chainid,
            address(this),
            account,
            p256KeyX,
            p256KeyY,
            expiry,
            contractScope,
            selectorScope,
            grantNonces_p256[account][keyHash]
        ));
        return inner.toEthSignedMessageHash();
    }

    function _storeP256Session(
        address account,
        bytes32 keyHash,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) internal {
        sessions_p256[account][keyHash] = Session({
            expiry:        expiry,
            contractScope: contractScope,
            selectorScope: selectorScope,
            revoked:       false
        });
        emit P256SessionGranted(account, keyHash, expiry, contractScope, selectorScope);
    }

    function _checkP256NotExists(address account, bytes32 keyHash) internal view {
        Session memory s = sessions_p256[account][keyHash];
        if (s.expiry != 0 && !s.revoked && block.timestamp < s.expiry) {
            revert SessionAlreadyExists();
        }
    }

    // ─── Internal: Common ────────────────────────────────────────────

    function _checkExpiry(uint48 expiry) internal view {
        if (expiry == 0) revert InvalidExpiry();
        if (block.timestamp >= expiry) revert ExpiryInPast();
        if (expiry > block.timestamp + MAX_SESSION_DURATION) revert ExpiryTooFar();
    }

    /// @dev Read owner from account (must implement owner() view function)
    function _ownerOf(address account) internal view returns (address) {
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
