// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title SessionKeyValidator — algId 0x08 Time-Limited Session Key Authorization
/// @notice Implements temporary delegated signing for ERC-4337 accounts.
///         A session key is an ephemeral key pair whose public key is pre-authorized
///         by the account owner for a bounded time window. The session key signs
///         UserOps instead of the owner, enabling dApp automation without exposing
///         the owner's key.
///
/// @dev Architecture:
///      - Standalone validator contract, registered in AAStarValidator for algId 0x08
///      - Zero changes to AAStarAirAccountBase (except ALG_SESSION_KEY constant + _algTier)
///      - Session data lives in this contract's storage, keyed by (account, sessionKey)
///      - Owner can grant sessions off-chain (signed message, anyone submits) or directly
///      - Tier: session key ops are Tier 1 — the session itself was authorized by owner
///
/// Signature format (after algId byte stripped by AAStarValidator):
///   [account(20)][sessionKey(20)][ECDSASig(65)] = 105 bytes
///
/// Session grant hash (off-chain signing):
///   keccak256(abi.encodePacked(
///       "GRANT_SESSION",
///       block.chainid,
///       address(sessionKeyValidator),
///       account,
///       sessionKey,
///       expiry,
///       contractScope,
///       selectorScope
///   )).toEthSignedMessageHash()
///
/// @dev Scope enforcement limitation: validate() only receives the userOpHash — it cannot
///      inspect the actual calldata target or selector. contractScope and selectorScope are
///      included in the grant hash (replay protection) but are NOT enforced on-chain during
///      validation. Enforcement is done off-chain by bundler/DVT policy nodes.
///      M7 will add _enforceGuard integration to check scope against live calldata.
///
/// @dev Spend cap limitation: validate() is a view function (ERC-4337 constraint),
///      so on-chain spend tracking is impossible here. Spend caps are enforced
///      off-chain by bundler/DVT nodes. M7 will add execution-phase spend recording.
contract SessionKeyValidator is IAAStarAlgorithm {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Structs ──────────────────────────────────────────────────────

    struct Session {
        uint48  expiry;           // Unix timestamp; 0 = session does not exist
        address contractScope;    // address(0) = any dest allowed
        bytes4  selectorScope;    // bytes4(0) = any selector allowed
        bool    revoked;          // owner can revoke before expiry
    }

    // ─── Storage ──────────────────────────────────────────────────────

    /// @notice Session registry: account → sessionKey → Session
    mapping(address => mapping(address => Session)) public sessions;

    // ─── Events ──────────────────────────────────────────────────────

    event SessionGranted(
        address indexed account,
        address indexed sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    );
    event SessionRevoked(address indexed account, address indexed sessionKey);

    // ─── Errors ──────────────────────────────────────────────────────

    error NotAccountOwner();
    error SessionAlreadyExists();
    error ExpiryInPast();
    error InvalidExpiry();
    error ExpiryTooFar();

    /// @dev Maximum session duration: 30 days. Prevents permanent session keys
    ///      that would be indistinguishable from full owner delegation.
    uint48 internal constant MAX_SESSION_DURATION = 30 days;

    // ─── IAAStarAlgorithm ────────────────────────────────────────────

    /// @inheritdoc IAAStarAlgorithm
    /// @dev Called by AAStarValidator with signature[1:] (algId byte stripped).
    ///      Expects: [account(20)][sessionKey(20)][ECDSASig(65)] = 105 bytes
    function validate(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view override returns (uint256 validationData) {
        if (signature.length != 105) return 1;

        address account  = address(bytes20(signature[0:20]));
        address sessionKey = address(bytes20(signature[20:40]));

        Session memory s = sessions[account][sessionKey];

        // Session existence check: expiry == 0 means never granted
        if (s.expiry == 0) return 1;
        if (s.revoked) return 1;
        if (block.timestamp >= s.expiry) return 1;

        // Recover ECDSA signer — must be the session key
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, signature[40:105]);
        if (err != ECDSA.RecoverError.NoError || recovered != sessionKey) return 1;

        return 0;
    }

    // ─── Session Management ──────────────────────────────────────────

    /// @notice Grant a session via off-chain owner signature (gasless, anyone can submit).
    ///         Owner signs the grant message off-chain; session key holder or relayer submits.
    /// @param account       The AA account granting the session
    /// @param sessionKey    The ephemeral public key address
    /// @param expiry        Unix timestamp after which the session key is invalid (max 30 days)
    /// @param contractScope Restrict to a specific dest contract (address(0) = no restriction)
    /// @param selectorScope Restrict to a specific calldata selector (bytes4(0) = no restriction)
    /// @param ownerSig      ECDSA signature from account.owner() over the grant hash
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

    /// @notice Grant a session by direct owner call (simpler, requires owner to be msg.sender).
    /// @param account       The AA account granting the session
    /// @param sessionKey    The ephemeral public key address
    /// @param expiry        Unix timestamp
    /// @param contractScope Restrict to a specific dest (address(0) = no restriction)
    /// @param selectorScope Restrict to a specific selector (bytes4(0) = no restriction)
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

    /// @notice Revoke a session before its expiry.
    ///         Callable by account owner or by the account contract itself.
    function revokeSession(address account, address sessionKey) external {
        if (msg.sender != _ownerOf(account) && msg.sender != account) {
            revert NotAccountOwner();
        }
        sessions[account][sessionKey].revoked = true;
        emit SessionRevoked(account, sessionKey);
    }

    /// @notice Check if a session is currently active (not expired, not revoked, exists).
    function isSessionActive(address account, address sessionKey) external view returns (bool) {
        Session memory s = sessions[account][sessionKey];
        return s.expiry != 0 && !s.revoked && block.timestamp < s.expiry;
    }

    /// @notice Build the off-chain signing hash for a session grant.
    ///         Domain: "GRANT_SESSION" + chainId + validator + account + sessionKey + expiry + scopes
    function buildGrantHash(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) external view returns (bytes32) {
        return _buildGrantHash(account, sessionKey, expiry, contractScope, selectorScope);
    }

    // ─── Internal ────────────────────────────────────────────────────

    function _buildGrantHash(
        address account,
        address sessionKey,
        uint48  expiry,
        address contractScope,
        bytes4  selectorScope
    ) internal view returns (bytes32) {
        bytes32 inner = keccak256(abi.encodePacked(
            "GRANT_SESSION",
            block.chainid,
            address(this),
            account,
            sessionKey,
            expiry,
            contractScope,
            selectorScope
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
            expiry:         expiry,
            contractScope:  contractScope,
            selectorScope:  selectorScope,
            revoked:        false
        });
        emit SessionGranted(account, sessionKey, expiry, contractScope, selectorScope);
    }

    function _checkExpiry(uint48 expiry) internal view {
        if (expiry == 0) revert InvalidExpiry();
        if (block.timestamp >= expiry) revert ExpiryInPast();
        if (expiry > block.timestamp + MAX_SESSION_DURATION) revert ExpiryTooFar();
    }

    function _checkNotExists(address account, address sessionKey) internal view {
        Session memory s = sessions[account][sessionKey];
        if (s.expiry != 0 && !s.revoked && block.timestamp < s.expiry) {
            revert SessionAlreadyExists();
        }
    }

    /// @dev Read owner from account (must implement owner() view function)
    function _ownerOf(address account) internal view returns (address) {
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
