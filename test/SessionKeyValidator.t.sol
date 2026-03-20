// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SessionKeyValidator} from "../src/validators/SessionKeyValidator.sol";

/// @title SessionKeyValidatorTest — Unit tests for M6.4 SessionKeyValidator
contract SessionKeyValidatorTest is Test {
    using MessageHashUtils for bytes32;

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
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp + 1 hours), address(0), bytes4(0));

        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSessionDirect_byNonOwner_reverts() public {
        vm.prank(other);
        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp + 1 hours), address(0), bytes4(0));
    }

    function test_grantSessionDirect_expiredTimestamp_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.ExpiryInPast.selector);
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp - 1), address(0), bytes4(0));
    }

    function test_grantSessionDirect_zeroExpiry_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.InvalidExpiry.selector);
        validator.grantSessionDirect(account, sessionKey, 0, address(0), bytes4(0));
    }

    function test_grantSessionDirect_expiryBeyond30Days_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.ExpiryTooFar.selector);
        validator.grantSessionDirect(
            account, sessionKey,
            uint48(block.timestamp + 31 days),
            address(0), bytes4(0)
        );
    }

    function test_grantSessionDirect_exactly24Hours_succeeds() public {
        vm.prank(owner);
        validator.grantSessionDirect(
            account, sessionKey,
            uint48(block.timestamp + 24 hours),
            address(0), bytes4(0)
        );
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSessionDirect_duplicate_active_reverts() public {
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp + 1 hours), address(0), bytes4(0));

        vm.prank(owner);
        vm.expectRevert(SessionKeyValidator.SessionAlreadyExists.selector);
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp + 2 hours), address(0), bytes4(0));
    }

    function test_grantSessionDirect_afterExpiry_canRegrant() public {
        // t=1_000_000: grant session expiring at t=1_003_600 (+1h, within 24h limit)
        vm.warp(1_000_000);
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, 1_003_600, address(0), bytes4(0));

        // Warp past first expiry
        vm.warp(1_003_601);
        assertFalse(validator.isSessionActive(account, sessionKey));

        // Re-grant same session key after expiry — new 1h session from t=1_003_601
        vm.prank(owner);
        validator.grantSessionDirect(account, sessionKey, 1_007_201, address(0), bytes4(0));
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    // ─── 2. grantSession (off-chain sig) ─────────────────────────────

    function test_grantSession_validOwnerSig_succeeds() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes memory sig = _ownerGrantSig(account, sessionKey, expiry, address(0), bytes4(0));

        validator.grantSession(account, sessionKey, expiry, address(0), bytes4(0), sig);
        assertTrue(validator.isSessionActive(account, sessionKey));
    }

    function test_grantSession_wrongSigner_reverts() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);

        // Sign with non-owner key (same hash, wrong signer)
        bytes32 grantHash = validator.buildGrantHash(account, sessionKey, expiry, address(0), bytes4(0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, grantHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(SessionKeyValidator.NotAccountOwner.selector);
        validator.grantSession(account, sessionKey, expiry, address(0), bytes4(0), badSig);
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
        validator.grantSessionDirect(account, sessionKey, uint48(block.timestamp + 1 hours), scope, sel);

        (uint48 expiry, address contractScope, bytes4 selectorScope, bool revoked) = validator.sessions(account, sessionKey);
        assertEq(contractScope, scope);
        assertEq(selectorScope, sel);
        assertFalse(revoked);
        assertGt(expiry, 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _grantSession(address _account, address _sk, uint48 _expiry) internal {
        vm.prank(owner);
        validator.grantSessionDirect(_account, _sk, _expiry, address(0), bytes4(0));
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
        bytes32 grantHash = validator.buildGrantHash(_account, _sk, _expiry, _contractScope, _selectorScope);
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
