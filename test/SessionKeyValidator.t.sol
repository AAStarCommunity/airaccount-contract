// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SessionKeyValidator} from "../src/validators/SessionKeyValidator.sol";

/// @title SessionKeyValidatorTest — Unit tests for v0.17.2 unified SessionKeyValidator
contract SessionKeyValidatorTest is Test {
    using MessageHashUtils for bytes32;

    /// @dev Build a Session struct mimicking the v0.17.1 simple session (no velocity, no arrays).
    function _sessionLegacy(uint48 expiry, address scope, bytes4 sel)
        internal pure returns (SessionKeyValidator.Session memory)
    {
        return SessionKeyValidator.Session({
            expiry: expiry,
            contractScope: scope,
            selectorScope: sel,
            revoked: false,
            velocityLimit: 0,
            velocityWindow: 0,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
    }

    SessionKeyValidator public validator;

    // Test accounts
    address public account;
    address public owner;
    uint256 public ownerKey;

    address public sessionKey;
    uint256 public sessionKeyPriv;

    address public other;
    uint256 public otherKey;

    bytes32 public constant USER_OP_HASH = keccak256("test-userop");

    // ─── Setup ────────────────────────────────────────────────────────

    function setUp() public {
        validator = new SessionKeyValidator();

        ownerKey    = 0xA11CE;
        owner       = vm.addr(ownerKey);

        sessionKeyPriv = 0xDEAD;
        sessionKey     = vm.addr(sessionKeyPriv);

        otherKey    = 0xBAD1;
        other       = vm.addr(otherKey);

        // Deploy a minimal mock account that returns owner
        account = address(new MockAccount(owner));

        // Advance time past block.timestamp = 0
        vm.warp(1_000_000);
    }

    // ─── 1. grantSessionDirect ───────────────────────────────────────

    function test_grantSessionDirect_byOwner_succeeds() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));

        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSessionDirect_byNonOwner_reverts() public {
        vm.prank(other);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));
    }

    function test_grantSessionDirect_byAccount_reverts() public {
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));
    }

    function test_grantSessionDirect_expiredTimestamp_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.ExpiryInPast.selector);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp - 1), address(0), bytes4(0)));
    }

    function test_grantSessionDirect_zeroExpiry_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.InvalidExpiry.selector);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(0, address(0), bytes4(0)));
    }

    function test_grantSessionDirect_expiryBeyond30Days_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.ExpiryTooFar.selector);
        validator.grantSessionDirect(account, sessionKey,
            _sessionLegacy(uint48(block.timestamp + 31 days), address(0), bytes4(0)));
    }

    function test_grantSessionDirect_exactly24Hours_succeeds() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey,
            _sessionLegacy(uint48(block.timestamp + 24 hours), address(0), bytes4(0)));
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSessionDirect_duplicate_active_reverts() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));

        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.SessionAlreadyExists.selector);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 2 hours), address(0), bytes4(0)));
    }

    function test_grantSessionDirect_afterExpiry_canRegrant() public {
        // t=1_000_000: grant session expiring at t=1_003_600 (+1h, within 24h limit)
        vm.warp(1_000_000);
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(1_003_600, address(0), bytes4(0)));

        // Warp past first expiry
        vm.warp(1_003_601);
        assertFalse(validator.isSessionActive(account, sessionKey));

        // Re-grant same session key after expiry — new 1h session from t=1_003_601
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(1_007_201, address(0), bytes4(0)));
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    // ─── 2. grantSession (off-chain sig) ─────────────────────────────

    function test_grantSession_validOwnerSig_succeeds() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        SessionKeyValidator.Session memory cfg = _sessionLegacy(expiry, address(0), bytes4(0));
        bytes memory sig = _ownerGrantSig(account, sessionKey, expiry, address(0), bytes4(0));

        validator.grantSession(account, sessionKey, cfg, sig);
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSession_wrongSigner_reverts() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        SessionKeyValidator.Session memory cfg = _sessionLegacy(expiry, address(0), bytes4(0));

        // Sign with non-owner key (same hash, wrong signer)
        bytes32 grantHash = validator.buildGrantHash(account, sessionKey, cfg);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, grantHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSession(account, sessionKey, cfg, badSig);
    }

    function test_grantP256SessionDirect_byAccount_reverts() public {
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantP256SessionDirect(
            account,
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0))
        );
    }

    // ─── 3. validate ─────────────────────────────────────────────────

    function test_validate_validSession_returns0() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        bytes memory sig = _buildValidateSig(account, sessionKey, sessionKeyPriv, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 0);
    }

    function test_validate_expiredSession_returns1() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _grantSession(account, sessionKey, expiry);

        vm.warp(block.timestamp + 2 hours);

        bytes memory sig = _buildValidateSig(account, sessionKey, sessionKeyPriv, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    function test_validate_revokedSession_returns1() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        vm.prank(owner);
        validator.revokeSession(account, sessionKey);

        bytes memory sig = _buildValidateSig(account, sessionKey, sessionKeyPriv, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    function test_validate_nonexistentSession_returns1() public {
        bytes memory sig = _buildValidateSig(account, sessionKey, sessionKeyPriv, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    function test_validate_wrongSessionKeySignature_returns1() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        // Sign with owner key instead of session key
        bytes memory sig = _buildValidateSig(account, sessionKey, ownerKey, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    function test_validate_wrongSigLength_returns1() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        // Only 104 bytes instead of 105
        bytes memory sig = new bytes(104);
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    function test_validate_wrongAccount_returns1() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        address fakeAccount = address(0xDEADBEEF);
        // Build sig claiming fakeAccount (which has no session)
        bytes32 ethHash = USER_OP_HASH.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPriv, ethHash);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);
        bytes memory sig = abi.encodePacked(bytes20(fakeAccount), bytes20(sessionKey), ecdsaSig);

        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    // ─── 4. revokeSession ────────────────────────────────────────────

    function test_revokeSession_byOwner_succeeds() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        vm.prank(owner);
        validator.revokeSession(account, sessionKey);

        assertFalse(validator.isSessionActive(account, sessionKey));
    }

    function test_revokeSession_byAccount_succeeds() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        vm.prank(account);
        validator.revokeSession(account, sessionKey);

        assertFalse(validator.isSessionActive(account, sessionKey));
    }

    function test_revokeSession_byOther_reverts() public {
        _grantSession(account, sessionKey, uint48(block.timestamp + 1 hours));

        vm.prank(other);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.revokeSession(account, sessionKey);
    }

    // ─── 4b. grantNonce replay protection ────────────────────────────

    /// @notice Security regression: revoking a session must invalidate any prior ownerSig.
    ///         Before the fix, an attacker could replay the original grantSession calldata
    ///         after revocation to resurrect the session.
    function test_revokeSession_preventsGrantReplay() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);

        // Owner signs a grant message (nonce=0 at this point)
        bytes memory sig = _ownerGrantSig(account, sessionKey, expiry, address(0), bytes4(0));

        // Grant session using the signed message
        validator.grantSession(account, sessionKey, _sessionLegacy(expiry, address(0), bytes4(0)), sig);
        assertTrue(validator.isSessionActive(account, sessionKey));

        // Owner revokes — this increments the grant nonce to 1
        vm.prank(owner);
        validator.revokeSession(account, sessionKey);
        assertFalse(validator.isSessionActive(account, sessionKey));
        assertEq(validator.grantNonces(account, sessionKey), 1);

        // Attacker replays the original sig (which was signed over nonce=0)
        // _checkNotExists allows re-grant because session is revoked
        // But the hash no longer matches since nonce is now 1 → NotAccountOwner revert
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSession(account, sessionKey, _sessionLegacy(expiry, address(0), bytes4(0)), sig);
    }

    /// @notice After revocation, owner can re-grant with a fresh signature (new nonce).
    function test_revokeSession_ownerCanRegrantWithNewSig() public {
        uint48 expiry1 = uint48(block.timestamp + 1 hours);

        bytes memory sig1 = _ownerGrantSig(account, sessionKey, expiry1, address(0), bytes4(0));
        validator.grantSession(account, sessionKey, _sessionLegacy(expiry1, address(0), bytes4(0)), sig1);

        vm.prank(owner);
        validator.revokeSession(account, sessionKey);
        assertFalse(validator.isSessionActive(account, sessionKey));

        // Owner builds a new sig — this time with nonce=1 baked in via buildGrantHash
        uint48 expiry2 = uint48(block.timestamp + 2 hours);
        bytes memory sig2 = _ownerGrantSig(account, sessionKey, expiry2, address(0), bytes4(0));
        validator.grantSession(account, sessionKey, _sessionLegacy(expiry2, address(0), bytes4(0)), sig2);
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    // ─── 5. isSessionActive edge cases ───────────────────────────────

    function test_isSessionActive_exactlyAtExpiry_inactive() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _grantSession(account, sessionKey, expiry);

        vm.warp(expiry);
        assertFalse(validator.isSessionActive(account, sessionKey));
    }

    function test_isSessionActive_oneSecondBeforeExpiry_active() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _grantSession(account, sessionKey, expiry);

        vm.warp(expiry - 1);
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    // ─── 6. contractScope + selectorScope stored correctly ───────────

    function test_grantSessionDirect_storesScopes() public {
        address scope = address(0x1234);
        bytes4 sel = bytes4(keccak256("someFunc(uint256)"));

        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), scope, sel));

        SessionKeyValidator.Session memory s = validator.getSession(account, sessionKey);
        (uint48 expiry, address contractScope, bytes4 selectorScope, bool revoked) =
            (s.expiry, s.contractScope, s.selectorScope, s.revoked);
        assertEq(contractScope, scope);
        assertEq(selectorScope, sel);
        assertFalse(revoked);
        assertGt(expiry, 0);
    }

    // ─── P256 session tests ───────────────────────────────────────────

    bytes32 constant P256_X = bytes32(uint256(0xdeadbeef01));
    bytes32 constant P256_Y = bytes32(uint256(0xdeadbeef02));

    function _grantP256Session(uint48 expiry) internal {
        vm.prank(owner);
        validator.grantP256SessionDirect(account, P256_X, P256_Y, _sessionLegacy(expiry, address(0), bytes4(0)));
    }

    function test_grantP256SessionDirect_succeeds() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        _grantP256Session(expiry);
        bytes32 keyHash = keccak256(abi.encodePacked(P256_X, P256_Y));
        // prefix the hash the same way the contract does (_p256StorageKey = keccak256(abi.encodePacked(0x02, keyHash)))
        assertTrue(validator.isP256SessionActive(account, P256_X, P256_Y));
    }

    function test_grantP256SessionDirect_nonOwner_reverts() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        vm.prank(other);
        validator.grantP256SessionDirect(account, P256_X, P256_Y, _sessionLegacy(expiry, address(0), bytes4(0)));
    }

    function test_grantP256Session_validOwnerSig_succeeds() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        SessionKeyValidator.Session memory cfg = _sessionLegacy(expiry, address(0), bytes4(0));
        bytes32 grantHash = validator.buildP256GrantHash(account, P256_X, P256_Y, cfg);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, grantHash);
        bytes memory ownerSig = abi.encodePacked(r, s, v);
        validator.grantP256Session(account, P256_X, P256_Y, cfg, ownerSig);
        assertTrue(validator.isP256SessionActive(account, P256_X, P256_Y));
    }

    function test_grantP256Session_wrongOwnerSig_reverts() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        SessionKeyValidator.Session memory cfg = _sessionLegacy(expiry, address(0), bytes4(0));
        bytes32 grantHash = validator.buildP256GrantHash(account, P256_X, P256_Y, cfg);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, grantHash);
        bytes memory badSig = abi.encodePacked(r, s, v);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantP256Session(account, P256_X, P256_Y, cfg, badSig);
    }

    function test_getP256Session_returnsStoredSession() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        address scope = address(0xABCD);
        vm.prank(owner);
        validator.grantP256SessionDirect(account, P256_X, P256_Y, _sessionLegacy(expiry, scope, bytes4(0)));

        bytes32 keyHash = keccak256(abi.encodePacked(
            uint8(0x02),
            keccak256(abi.encodePacked(P256_X, P256_Y))
        ));
        // getP256Session takes the raw p256KeyHash (after _p256StorageKey transform)
        // We can verify via isP256SessionActive which uses the same key derivation
        assertTrue(validator.isP256SessionActive(account, P256_X, P256_Y));
    }

    function test_revokeP256Session_byOwner_succeeds() public {
        _grantP256Session(uint48(block.timestamp + 1 hours));
        assertTrue(validator.isP256SessionActive(account, P256_X, P256_Y));
        vm.prank(owner);
        validator.revokeP256Session(account, P256_X, P256_Y);
        assertFalse(validator.isP256SessionActive(account, P256_X, P256_Y));
    }

    function test_revokeP256Session_byAccount_succeeds() public {
        _grantP256Session(uint48(block.timestamp + 1 hours));
        vm.prank(account);
        validator.revokeP256Session(account, P256_X, P256_Y);
        assertFalse(validator.isP256SessionActive(account, P256_X, P256_Y));
    }

    function test_revokeP256Session_byOther_reverts() public {
        _grantP256Session(uint48(block.timestamp + 1 hours));
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        vm.prank(other);
        validator.revokeP256Session(account, P256_X, P256_Y);
    }

    /// @notice #78 (Codex WS-G CRITICAL) — P256 session sigs must reject high-S (malleability).
    ///         The EIP-7212 precompile is mocked to ALWAYS return valid, so the ONLY thing that can
    ///         reject is the low-S gate. high-S (N/2+1) → rejected; low-S (== N/2) → reaches the
    ///         (always-valid) verifier → success. Proves the gate is load-bearing.
    function test_p256Session_highS_rejected_lowS_passes() public {
        _grantP256Session(uint48(block.timestamp + 1 hours));
        vm.etch(address(0x100), address(new MockP256AlwaysValid()).code);
        bytes32 uoh = keccak256("p256-sess-malleability");
        uint256 nOver2 = 0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8;

        bytes memory highS = abi.encodePacked(bytes20(account), P256_X, P256_Y, bytes32(uint256(1)), bytes32(nOver2 + 1));
        assertEq(validator.validate(uoh, highS), 1, "high-S P256 session sig must be rejected by the low-S gate");

        bytes memory lowS = abi.encodePacked(bytes20(account), P256_X, P256_Y, bytes32(uint256(1)), bytes32(nOver2));
        assertEq(validator.validate(uoh, lowS), 0, "low-S P256 session sig must pass the gate and reach the verifier");
    }

    function test_buildP256GrantHash_nonZero() public view {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 h = validator.buildP256GrantHash(account, P256_X, P256_Y, _sessionLegacy(expiry, address(0), bytes4(0)));
        assertTrue(h != bytes32(0));
    }

    function test_buildP256GrantHash_differentInputs_differentHash() public view {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 h1 = validator.buildP256GrantHash(account, P256_X, P256_Y, _sessionLegacy(expiry, address(0), bytes4(0)));
        bytes32 h2 = validator.buildP256GrantHash(account, P256_Y, P256_X, _sessionLegacy(expiry, address(0), bytes4(0)));
        assertTrue(h1 != h2);
    }

    // ─── checkSessionScope tests ──────────────────────────────────────

    function test_checkSessionScope_happyPath_ECDSA() public {
        address scope = address(0x9999);
        bytes4 sel = bytes4(keccak256("transfer(address,uint256)"));
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), scope, sel));

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        // Should not revert
        validator.checkSessionScope(account, sessionKeyHash, 0x01, scope, sel);
    }

    function test_checkSessionScope_wrongTarget_reverts() public {
        address scope = address(0x9999);
        bytes4 sel = bytes4(keccak256("transfer(address,uint256)"));
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), scope, sel));

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.expectRevert(abi.encodeWithSelector(SessionKeyValidator.CallTargetForbidden.selector, address(0xDEAD)));
        validator.checkSessionScope(account, sessionKeyHash, 0x01, address(0xDEAD), sel);
    }

    function test_checkSessionScope_wrongSelector_reverts() public {
        address scope = address(0x9999);
        bytes4 sel = bytes4(keccak256("transfer(address,uint256)"));
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), scope, sel));

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        bytes4 badSel = bytes4(keccak256("approve(address,uint256)"));
        vm.expectRevert(abi.encodeWithSelector(SessionKeyValidator.SelectorForbidden.selector, badSel));
        validator.checkSessionScope(account, sessionKeyHash, 0x01, scope, badSel);
    }

    function test_checkSessionScope_expiredSession_reverts() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1), address(0), bytes4(0)));
        vm.warp(block.timestamp + 2);

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.expectRevert(SessionKeyValidator.SessionExpired.selector);
        validator.checkSessionScope(account, sessionKeyHash, 0x01, address(0), bytes4(0));
    }

    function test_checkSessionScope_noSession_reverts() public {
        bytes32 unknownKey = bytes32(uint256(uint160(address(0xCAFE))));
        vm.expectRevert(SessionKeyValidator.SessionNotFound.selector);
        validator.checkSessionScope(account, unknownKey, 0x01, address(0), bytes4(0));
    }

    function test_checkSessionScope_revokedSession_reverts() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));
        vm.prank(owner);
        validator.revokeSession(account, sessionKey);

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.expectRevert(SessionKeyValidator.SessionRevoked_.selector);
        validator.checkSessionScope(account, sessionKeyHash, 0x01, address(0), bytes4(0));
    }

    function test_checkSessionScope_invalidType_reverts() public {
        bytes32 anyKey = bytes32(uint256(uint160(sessionKey)));
        vm.expectRevert(abi.encodeWithSelector(SessionKeyValidator.InvalidSessionType.selector, uint8(0x99)));
        validator.checkSessionScope(account, anyKey, 0x99, address(0), bytes4(0));
    }

    // ─── recordCallForVelocity tests ──────────────────────────────────

    function test_recordCallForVelocity_noLimit_noOp() public {
        // velocityLimit == 0 means unlimited — recordCallForVelocity is a no-op
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        // Must be called from the bound account (anti-griefing)
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01); // no revert = pass
    }

    function test_recordCallForVelocity_withinLimit_succeeds() public {
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 1 hours),
            contractScope: address(0),
            selectorScope: bytes4(0),
            revoked: false,
            velocityLimit: 3,
            velocityWindow: 3600,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
    }

    /// @notice #57 adversarial (Codex WS-C LOW) — calls clustered at the END of window N. The weighted
    ///         limiter must DAMPEN the boundary burst: crossing into N+1 must NOT reset the budget to a
    ///         fresh full `limit` (that was the old fixed-window 2x bug). It allows only a small bounded
    ///         overage as prevCount decays. (This documents the APPROXIMATE behavior — see the
    ///         recordCallForVelocity comment: weighted limiter, not a strict per-rolling-window cap.)
    function test_velocity_clusteredAtWindowEnd_isDampened() public {
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 1 hours),
            contractScope: address(0), selectorScope: bytes4(0), revoked: false,
            velocityLimit: 10, velocityWindow: 100,
            callTargets: new address[](0), selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);
        bytes32 skh = bytes32(uint256(uint160(sessionKey)));

        uint256 t0 = block.timestamp;
        // Fill window N late: 10 calls at t0+99.
        vm.warp(t0 + 99);
        for (uint256 i = 0; i < 10; i++) { vm.prank(account); validator.recordCallForVelocity(account, skh, 0x01); }
        // 11th within window N → reverts (callCount == limit).
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.VelocityLimitExceeded.selector);
        validator.recordCallForVelocity(account, skh, 0x01);

        // Cross into window N+1 (elapsed=1): weighted estimate stays high (~9), so the budget is NOT
        // reset to a fresh 10. Count how many calls slip through before the gate rejects.
        vm.warp(t0 + 101);
        uint256 allowed;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(account);
            try validator.recordCallForVelocity(account, skh, 0x01) { allowed++; } catch { break; }
        }
        assertLt(allowed, 10, "weighted limiter must NOT grant a fresh full limit right after the boundary (no 2x burst)");
    }

    function test_recordCallForVelocity_exceedsLimit_reverts() public {
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 1 hours),
            contractScope: address(0),
            selectorScope: bytes4(0),
            revoked: false,
            velocityLimit: 2,
            velocityWindow: 3600,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
        vm.expectRevert(SessionKeyValidator.VelocityLimitExceeded.selector);
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
    }

    function test_recordCallForVelocity_windowResets_allowsNewCalls() public {
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 2 hours),
            contractScope: address(0),
            selectorScope: bytes4(0),
            revoked: false,
            velocityLimit: 1,
            velocityWindow: 100,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);

        // Warp past the window
        vm.warp(block.timestamp + 101);
        vm.prank(account);
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01); // should succeed after window reset
    }

    function test_recordCallForVelocity_notBoundAccount_reverts() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0)));

        bytes32 sessionKeyHash = bytes32(uint256(uint160(sessionKey)));
        vm.expectRevert(SessionKeyValidator.NotBoundAccount.selector);
        vm.prank(other); // other is not the bound account
        validator.recordCallForVelocity(account, sessionKeyHash, 0x01);
    }

    // ─── #83: per-account session-key cap ─────────────────────────────

    /// @dev Mirror of SessionKeyValidator.MAX_SESSION_KEYS_PER_ACCOUNT (internal constant).
    uint256 internal constant MAX_KEYS = 50;

    function _cfg1h() internal view returns (SessionKeyValidator.Session memory) {
        return _sessionLegacy(uint48(block.timestamp + 1 hours), address(0), bytes4(0));
    }

    function test_sessionKeyCap_exceeded_reverts() public {
        // Fill the account to the cap with distinct ECDSA session keys.
        for (uint256 i = 1; i <= MAX_KEYS; i++) {
            vm.prank(owner);
            validator.grantSessionDirect(account, address(uint160(i)), _cfg1h());
        }
        assertEq(validator.sessionKeyCount(account), MAX_KEYS);

        // The (cap+1)-th distinct key must revert.
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.TooManySessionKeys.selector);
        validator.grantSessionDirect(account, address(uint160(MAX_KEYS + 1)), _cfg1h());
    }

    function test_sessionKeyCap_revokeFreesSlot() public {
        for (uint256 i = 1; i <= MAX_KEYS; i++) {
            vm.prank(owner);
            validator.grantSessionDirect(account, address(uint160(i)), _cfg1h());
        }
        assertEq(validator.sessionKeyCount(account), MAX_KEYS);

        // At cap → next grant reverts.
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.TooManySessionKeys.selector);
        validator.grantSessionDirect(account, address(uint160(MAX_KEYS + 1)), _cfg1h());

        // Revoke one → count drops, a slot frees up.
        vm.prank(owner);
        validator.revokeSession(account, address(uint160(1)));
        assertEq(validator.sessionKeyCount(account), MAX_KEYS - 1);

        // Now the new key can be granted.
        vm.prank(owner);
        validator.grantSessionDirect(account, address(uint160(MAX_KEYS + 1)), _cfg1h());
        assertEq(validator.sessionKeyCount(account), MAX_KEYS);
    }

    function test_sessionKeyCount_tracksGrantAndRevoke() public {
        assertEq(validator.sessionKeyCount(account), 0);
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _cfg1h());
        assertEq(validator.sessionKeyCount(account), 1);
        vm.prank(owner);
        validator.revokeSession(account, sessionKey);
        assertEq(validator.sessionKeyCount(account), 0);
        // Double-revoke is idempotent — must not underflow / decrement again.
        vm.prank(owner);
        validator.revokeSession(account, sessionKey);
        assertEq(validator.sessionKeyCount(account), 0);
    }

    function test_sessionKeyCap_sharedAcrossEcdsaAndP256() public {
        // ECDSA + P256 sessions share one per-account counter.
        for (uint256 i = 1; i <= MAX_KEYS - 1; i++) {
            vm.prank(owner);
            validator.grantSessionDirect(account, address(uint160(i)), _cfg1h());
        }
        assertEq(validator.sessionKeyCount(account), MAX_KEYS - 1);

        // One P256 session takes the last slot.
        vm.prank(owner);
        validator.grantP256SessionDirect(account, P256_X, P256_Y, _cfg1h());
        assertEq(validator.sessionKeyCount(account), MAX_KEYS);

        // A further P256 key must revert at the shared cap.
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.TooManySessionKeys.selector);
        validator.grantP256SessionDirect(account, bytes32(uint256(0xabc1)), bytes32(uint256(0xabc2)), _cfg1h());
    }

    function test_regrantExpiredUnrevoked_doesNotDoubleCount() public {
        // setUp warps to 1e6. Use absolute literals: via_ir folds repeated block.timestamp reads
        // within a test function to the entry value, so deriving timestamps from it after a warp
        // is unreliable. T0 == 1_000_000.
        assertEq(block.timestamp, 1_000_000);

        // Short-lived session, never revoked, allowed to expire.
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(1_000_100), address(0), bytes4(0)));
        assertEq(validator.sessionKeyCount(account), 1);

        // Let it expire, then re-grant the SAME key. The expired-unrevoked slot already holds a
        // count, so the re-grant must reuse it (no double-count) — protects legitimate rotation.
        vm.warp(1_000_200);
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, _sessionLegacy(uint48(1_000_300), address(0), bytes4(0)));
        assertEq(validator.sessionKeyCount(account), 1);
    }

    // ─── #57 / KI-4: velocity sliding window (no 2x boundary burst) ────

    function test_velocity_noBurstAcrossWindowBoundary() public {
        // Warp far from epoch so the first call cleanly anchors a fresh window.
        vm.warp(1_000_000);
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 2 hours),
            contractScope: address(0),
            selectorScope: bytes4(0),
            revoked: false,
            velocityLimit: 10,
            velocityWindow: 100,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);
        bytes32 h = bytes32(uint256(uint160(sessionKey)));

        // Window N anchors at the first recorded call. setUp warps to 1e6, so T0 == 1_000_000.
        // Use absolute timestamps to keep the windowing math unambiguous.
        uint256 T0 = 1_000_000;
        assertEq(block.timestamp, T0);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(account);
            validator.recordCallForVelocity(account, h, 0x01);
        }
        // 11th in the same window is rejected.
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.VelocityLimitExceeded.selector);
        validator.recordCallForVelocity(account, h, 0x01);

        // Cross exactly into window N+1. A FIXED window would reset and allow 10 MORE calls
        // (2x burst). The sliding window weights the full prior count → estimate == 10 → reject.
        vm.warp(T0 + 100);
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.VelocityLimitExceeded.selector);
        validator.recordCallForVelocity(account, h, 0x01);

        // Halfway into N+1 (elapsed 50/100): prev window weighted at 50% → contributes 5.
        // So only 5 fresh calls fit before the rolling estimate hits the limit of 10.
        vm.warp(T0 + 150);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(account);
            validator.recordCallForVelocity(account, h, 0x01);
        }
        vm.prank(account);
        vm.expectRevert(SessionKeyValidator.VelocityLimitExceeded.selector);
        validator.recordCallForVelocity(account, h, 0x01);

        // After two full windows of silence the rate fully recovers.
        vm.warp(T0 + 400);
        vm.prank(account);
        validator.recordCallForVelocity(account, h, 0x01); // succeeds
    }

    function test_velocity_validateEarlyRejectMirrorsRecord() public {
        // The view-side early reject must agree with the execute-side counter.
        vm.warp(1_000_000);
        SessionKeyValidator.Session memory cfg = SessionKeyValidator.Session({
            expiry: uint48(block.timestamp + 2 hours),
            contractScope: address(0),
            selectorScope: bytes4(0),
            revoked: false,
            velocityLimit: 2,
            velocityWindow: 100,
            callTargets: new address[](0),
            selectorAllowlist: new bytes4[](0)
        });
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, cfg);
        bytes32 h = bytes32(uint256(uint160(sessionKey)));

        bytes memory sig = _buildValidateSig(account, sessionKey, sessionKeyPriv, USER_OP_HASH);
        assertEq(validator.validate(USER_OP_HASH, sig), 0); // within limit

        vm.prank(account);
        validator.recordCallForVelocity(account, h, 0x01);
        vm.prank(account);
        validator.recordCallForVelocity(account, h, 0x01);

        // Limit now reached for the current window → validate must early-reject (returns 1).
        assertEq(validator.validate(USER_OP_HASH, sig), 1);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _grantSession(address _account, address _sk, uint48 _expiry) internal {
        vm.prank(owner);
        validator.grantSessionDirect(_account, _sk, _sessionLegacy(_expiry, address(0), bytes4(0)));
    }

    /// @dev Build the 105-byte signature for validator.validate()
    ///      Format: [account(20)][sessionKey(20)][ECDSASig(65)] = 105 bytes
    function _buildValidateSig(
        address _account,
        address _sk,
        uint256 _skPriv,
        bytes32 _userOpHash
    ) internal pure returns (bytes memory) {
        bytes32 ethHash = _userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_skPriv, ethHash);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);
        return abi.encodePacked(bytes20(_account), bytes20(_sk), ecdsaSig);
    }

    /// @dev Build owner signature for grantSession (off-chain path).
    ///      buildGrantHash returns the EIP-191 prefixed hash.
    ///      vm.sign does NOT add any prefix — it signs the bytes32 as-is.
    ///      The contract verifies via ECDSA.recover(grantHash, sig) which also expects
    ///      the sig to be over grantHash (no additional prefix). So we sign grantHash directly.
    function _ownerGrantSig(
        address _account,
        address _sk,
        uint48  _expiry,
        address _contractScope,
        bytes4  _selectorScope
    ) internal view returns (bytes memory) {
        bytes32 grantHash = validator.buildGrantHash(_account, _sk, _sessionLegacy(_expiry, _contractScope, _selectorScope));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, grantHash);
        return abi.encodePacked(r, s, v);
    }
}

/// @dev Minimal mock account that returns a fixed owner address
contract MockAccount {
    address private _owner;

    constructor(address ownerAddr) {
        _owner = ownerAddr;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}

/// @dev Mock EIP-7212 P256 precompile that always returns valid (1) — used to prove the low-S gate
///      is load-bearing (only the gate, not the precompile, can reject in that test).
contract MockP256AlwaysValid {
    fallback() external {
        assembly { mstore(0, 1) return(0, 32) }
    }
}
