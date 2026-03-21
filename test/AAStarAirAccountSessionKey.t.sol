// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {SessionKeyValidator} from "../src/validators/SessionKeyValidator.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Minimal mock EntryPoint
contract MockEPSK {
    receive() external payable {}
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 1 ether; }
    function withdrawTo(address payable, uint256) external {}
}

// ─── Helpers shared by both test suites ──────────────────────────────────────

function _buildUserOpFor(address sender) pure returns (PackedUserOperation memory) {
    return PackedUserOperation({
        sender: sender,
        nonce: 0,
        initCode: "",
        callData: "",
        accountGasLimits: bytes32(0),
        preVerificationGas: 0,
        gasFees: bytes32(0),
        paymasterAndData: "",
        signature: ""
    });
}

/// @title AAStarAirAccountSessionKeyTest
/// @notice Integration tests for ALG_SESSION_KEY (0x08) at the account level.
///         Covers cross-account binding fix (HIGH audit 2026-03-20) and expiry/revoke.
contract AAStarAirAccountSessionKeyTest is Test {
    using MessageHashUtils for bytes32;

    uint8 constant ALG_SESSION_KEY = 0x08;
    uint8 constant ALG_ECDSA       = 0x02;

    MockEPSK ep;
    AAStarValidator validator;
    SessionKeyValidator skValidator;

    AAStarAirAccountV7 accountA;
    uint256 ownerAKey = 0xA11CE_A;
    address ownerA;

    AAStarAirAccountV7 accountB;
    uint256 ownerBKey = 0xBAD1_B;
    address ownerB;

    uint256 sessionKeyPriv = 0x5E55;
    address sessionKey;

    // ─── Setup ───────────────────────────────────────────────────────

    function setUp() public {
        ep          = new MockEPSK();
        ownerA      = vm.addr(ownerAKey);
        ownerB      = vm.addr(ownerBKey);
        sessionKey  = vm.addr(sessionKeyPriv);

        validator   = new AAStarValidator();
        skValidator = new SessionKeyValidator();
        validator.registerAlgorithm(ALG_SESSION_KEY, address(skValidator));

        accountA = _deployAccount(ownerA, ALG_SESSION_KEY);
        accountB = _deployAccount(ownerB, ALG_SESSION_KEY);

        vm.warp(1_000_000);

        // Grant session key for account A only
        vm.prank(ownerA);
        skValidator.grantSessionDirect(
            address(accountA), sessionKey,
            uint48(block.timestamp + 1 hours),
            address(0), bytes4(0)
        );
    }

    function _deployAccount(address owner_, uint8 algId_) internal returns (AAStarAirAccountV7 acct) {
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = algId_;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians:           [address(0), address(0), address(0)],
            dailyLimit:          0,
            approvedAlgIds:      algIds,
            minDailyLimit:       0,
            initialTokens:       new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        acct = new AAStarAirAccountV7();
        address g = address(new AAStarGlobalGuard(
            address(acct), 0, algIds, 0,
            new address[](0), new AAStarGlobalGuard.TokenConfig[](0)
        ));
        acct.initialize(address(ep), owner_, cfg, g);

        vm.prank(owner_);
        acct.setValidator(address(validator));

        vm.deal(address(acct), 10 ether);
    }

    // ─── sig builder ─────────────────────────────────────────────────

    /// Format: [algId(1)][account(20)][sessionKey(20)][ECDSASig(65)] = 106 bytes
    function _skSig(address acct_, address sk, uint256 skPriv, bytes32 uopHash)
        internal pure returns (bytes memory)
    {
        bytes32 eth = uopHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(skPriv, eth);
        return abi.encodePacked(uint8(ALG_SESSION_KEY), bytes20(acct_), bytes20(sk), r, s, v);
    }

    // ─── 1. Valid session accepted ────────────────────────────────────

    function test_sessionKey_valid_returns0() public {
        PackedUserOperation memory uop = _buildUserOpFor(address(accountA));
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSig(address(accountA), sessionKey, sessionKeyPriv, h);

        vm.prank(address(ep));
        assertEq(accountA.validateUserOp(uop, h, 0), 0);
    }

    // ─── 2. Cross-account binding (HIGH audit fix) ────────────────────
    // Attacker builds sig with account=A but submits to accountB.validateUserOp.
    // The account checks sig[1:21] == address(this) and returns 1.

    function test_sessionKey_crossAccount_rejected() public {
        PackedUserOperation memory uop = _buildUserOpFor(address(accountB));
        bytes32 h = keccak256(abi.encode(uop));

        // Malicious sig: account field = accountA, but validated against accountB
        uop.signature = _skSig(address(accountA), sessionKey, sessionKeyPriv, h);

        vm.prank(address(ep));
        assertEq(accountB.validateUserOp(uop, h, 0), 1, "Cross-account must be rejected");
    }

    // ─── 3. No session for accountB ───────────────────────────────────

    function test_sessionKey_noSessionForB_rejected() public {
        PackedUserOperation memory uop = _buildUserOpFor(address(accountB));
        bytes32 h = keccak256(abi.encode(uop));

        // Sig correctly claims account=B, but no session was granted for B
        uop.signature = _skSig(address(accountB), sessionKey, sessionKeyPriv, h);

        vm.prank(address(ep));
        assertEq(accountB.validateUserOp(uop, h, 0), 1, "No session for B must return 1");
    }

    // ─── 4. Revoked session rejected ─────────────────────────────────

    function test_sessionKey_revoked_returns1() public {
        vm.prank(ownerA);
        skValidator.revokeSession(address(accountA), sessionKey);

        PackedUserOperation memory uop = _buildUserOpFor(address(accountA));
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSig(address(accountA), sessionKey, sessionKeyPriv, h);

        vm.prank(address(ep));
        assertEq(accountA.validateUserOp(uop, h, 0), 1, "Revoked session must return 1");
    }

    // ─── 5. Expired session rejected ─────────────────────────────────

    function test_sessionKey_expired_returns1() public {
        vm.warp(block.timestamp + 2 hours);

        PackedUserOperation memory uop = _buildUserOpFor(address(accountA));
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSig(address(accountA), sessionKey, sessionKeyPriv, h);

        vm.prank(address(ep));
        assertEq(accountA.validateUserOp(uop, h, 0), 1, "Expired session must return 1");
    }

    // ─── 6. Wrong signer rejected ────────────────────────────────────

    function test_sessionKey_wrongSigner_returns1() public {
        PackedUserOperation memory uop = _buildUserOpFor(address(accountA));
        bytes32 h = keccak256(abi.encode(uop));
        // Sign with different key than granted sessionKey
        uop.signature = _skSig(address(accountA), sessionKey, 0xDEAD, h);

        vm.prank(address(ep));
        assertEq(accountA.validateUserOp(uop, h, 0), 1, "Wrong signer must return 1");
    }
}

// ─── Parser try/catch integration test ───────────────────────────────────────

/// @dev Parser that always reverts
contract RevertingParser {
    function parseTokenTransfer(bytes calldata) external pure returns (address, uint256) {
        revert("parser exploded");
    }
}

/// @dev Registry that returns a fixed parser for any dest
contract MockParserReg {
    address public p;
    constructor(address p_) { p = p_; }
    function getParser(address) external view returns (address) { return p; }
}

/// @title ParserTryCatchTest
/// @notice Verifies that a reverting parser does NOT block execute() (LOW audit fix).
contract ParserTryCatchTest is Test {
    using MessageHashUtils for bytes32;

    uint8 constant ALG_ECDSA = 0x02;

    MockEPSK ep;
    AAStarAirAccountV7 account;
    uint256 ownerKey = 0xC0FFEE;
    address owner_;

    function setUp() public {
        ep     = new MockEPSK();
        owner_ = vm.addr(ownerKey);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians:           [address(0), address(0), address(0)],
            dailyLimit:          1 ether,
            approvedAlgIds:      algIds,
            minDailyLimit:       0,
            initialTokens:       new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        account = new AAStarAirAccountV7();
        address g = address(new AAStarGlobalGuard(
            address(account), 1 ether, algIds, 0,
            new address[](0), new AAStarGlobalGuard.TokenConfig[](0)
        ));
        account.initialize(address(ep), owner_, cfg, g);
        vm.deal(address(account), 10 ether);

        // Register reverting parser for ALL destinations
        RevertingParser rp  = new RevertingParser();
        MockParserReg   reg = new MockParserReg(address(rp));
        vm.prank(owner_);
        account.setParserRegistry(address(reg));
    }

    /// @notice execute() with reverting parser must succeed — falls back to native ERC20 parsing.
    function test_revertingParser_doesNotBlockExecute() public {
        // Build ERC20 transfer calldata (68 bytes — triggers parser)
        bytes memory calldata_ = abi.encodeWithSelector(
            bytes4(0xa9059cbb), // transfer(address,uint256)
            address(0xBEEF),
            uint256(0.001 ether)
        );

        // First: validateUserOp to set algId=0x02 in transient storage
        PackedUserOperation memory uop = _buildUserOpFor(address(account));
        uop.callData = abi.encodeWithSelector(
            AAStarAirAccountBase.execute.selector,
            address(0x1234), uint256(0), calldata_
        );
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _ecdsaSig(ownerKey, h);

        vm.prank(address(ep));
        uint256 vr = account.validateUserOp(uop, h, 0);
        assertEq(vr, 0, "validateUserOp must pass");

        // execute() — reverting parser must NOT block this
        vm.prank(address(ep));
        account.execute(address(0x1234), 0, calldata_);
        // reaching here = success
    }

    function _ecdsaSig(uint256 privKey, bytes32 uopHash) internal pure returns (bytes memory) {
        bytes32 eth = uopHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, eth);
        return abi.encodePacked(uint8(ALG_ECDSA), r, s, v);
    }
}

// ─── executeBatch session key scope bypass regression ────────────────────────

/// @dev Minimal ETH receiver used as "allowed" and "disallowed" batch targets.
contract ETHSink { receive() external payable {} }

/// @title SessionKeyBatchScopeTest
/// @notice Regression for M6 security fix: session key contractScope must be
///         enforced on EVERY call in executeBatch, not just the first.
///
///         Before fix: _consumeSessionKey() was called inside _enforceGuard()
///         (per-call). Call 0 consumed the session key; calls 1+ got bytes32(0)
///         and skipped scope checks entirely — allowing arbitrary targets.
///
///         After fix: session key is consumed ONCE by executeBatch() and passed
///         to _enforceGuard() as a parameter. All calls in the batch are subject
///         to the same contractScope/selectorScope restriction.
contract SessionKeyBatchScopeTest is Test {
    using MessageHashUtils for bytes32;

    uint8 constant ALG_SESSION_KEY = 0x08;

    MockEPSK       ep;
    AAStarValidator validator;
    SessionKeyValidator skValidator;
    AAStarAirAccountV7  account;

    address owner_;
    uint256 ownerKey = 0xA11CE_C;

    address sessionKey_;
    uint256 sessionKeyPriv_ = 0x5E55_C;

    ETHSink allowedTarget;
    ETHSink disallowedTarget;

    function setUp() public {
        ep          = new MockEPSK();
        owner_      = vm.addr(ownerKey);
        sessionKey_ = vm.addr(sessionKeyPriv_);

        validator   = new AAStarValidator();
        skValidator = new SessionKeyValidator();
        validator.registerAlgorithm(ALG_SESSION_KEY, address(skValidator));

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_SESSION_KEY;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians:           [address(0), address(0), address(0)],
            dailyLimit:          0,
            approvedAlgIds:      algIds,
            minDailyLimit:       0,
            initialTokens:       new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        account = new AAStarAirAccountV7();
        address g = address(new AAStarGlobalGuard(
            address(account), 0, algIds, 0,
            new address[](0), new AAStarGlobalGuard.TokenConfig[](0)
        ));
        account.initialize(address(ep), owner_, cfg, g);
        vm.prank(owner_);
        account.setValidator(address(validator));
        vm.deal(address(account), 10 ether);

        allowedTarget    = new ETHSink();
        disallowedTarget = new ETHSink();

        vm.warp(1_000_000);

        // Grant session key scoped to allowedTarget only
        vm.prank(owner_);
        skValidator.grantSessionDirect(
            address(account), sessionKey_,
            uint48(block.timestamp + 1 hours),
            address(allowedTarget), // contractScope = allowedTarget only
            bytes4(0)
        );
    }

    /// @notice executeBatch with 1 allowed call must succeed.
    function test_executeBatch_singleScopedCall_passes() public {
        address[] memory dests  = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[]   memory funcs  = new bytes[](1);
        dests[0]  = address(allowedTarget);
        values[0] = 0.001 ether;
        funcs[0]  = "";

        bytes memory callData = abi.encodeWithSelector(
            AAStarAirAccountBase.executeBatch.selector, dests, values, funcs
        );
        PackedUserOperation memory uop = _buildUserOpFor(address(account));
        uop.callData = callData;
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSigBatch(address(account), sessionKey_, sessionKeyPriv_, h);

        vm.prank(address(ep));
        assertEq(account.validateUserOp(uop, h, 0), 0);

        vm.prank(address(ep));
        account.executeBatch(dests, values, funcs);
    }

    /// @notice executeBatch where call[1] targets a disallowed contract must revert.
    ///         This is the regression: before the fix call[1] skipped scope check.
    function test_executeBatch_secondCallOutOfScope_reverts() public {
        address[] memory dests  = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[]   memory funcs  = new bytes[](2);
        dests[0]  = address(allowedTarget);
        values[0] = 0.001 ether;
        funcs[0]  = "";
        dests[1]  = address(disallowedTarget); // outside scope
        values[1] = 0.001 ether;
        funcs[1]  = "";

        bytes memory callData = abi.encodeWithSelector(
            AAStarAirAccountBase.executeBatch.selector, dests, values, funcs
        );
        PackedUserOperation memory uop = _buildUserOpFor(address(account));
        uop.callData = callData;
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSigBatch(address(account), sessionKey_, sessionKeyPriv_, h);

        vm.prank(address(ep));
        assertEq(account.validateUserOp(uop, h, 0), 0);

        // Must revert — disallowedTarget is outside contractScope
        vm.prank(address(ep));
        vm.expectRevert(AAStarAirAccountBase.SessionScopeViolation.selector);
        account.executeBatch(dests, values, funcs);
    }

    /// @notice executeBatch with all calls to allowed target must succeed.
    function test_executeBatch_allCallsInScope_passes() public {
        address[] memory dests  = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[]   memory funcs  = new bytes[](3);
        for (uint i; i < 3; i++) {
            dests[i]  = address(allowedTarget);
            values[i] = 0.001 ether;
            funcs[i]  = "";
        }

        bytes memory callData = abi.encodeWithSelector(
            AAStarAirAccountBase.executeBatch.selector, dests, values, funcs
        );
        PackedUserOperation memory uop = _buildUserOpFor(address(account));
        uop.callData = callData;
        bytes32 h = keccak256(abi.encode(uop));
        uop.signature = _skSigBatch(address(account), sessionKey_, sessionKeyPriv_, h);

        vm.prank(address(ep));
        assertEq(account.validateUserOp(uop, h, 0), 0);

        vm.prank(address(ep));
        account.executeBatch(dests, values, funcs);
    }

    function _skSigBatch(address acct_, address sk, uint256 skPriv, bytes32 uopHash)
        internal pure returns (bytes memory)
    {
        bytes32 eth = uopHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(skPriv, eth);
        return abi.encodePacked(uint8(ALG_SESSION_KEY), bytes20(acct_), bytes20(sk), r, s, v);
    }
}
