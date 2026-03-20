// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {AirAccountDelegate} from "../src/core/AirAccountDelegate.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/**
 * @title AirAccountDelegateTest — Unit tests for M6-7702 AirAccountDelegate
 *
 * Test strategy: AirAccountDelegate is deployed normally (as a regular contract),
 * then we simulate 7702 delegation by using vm.etch() to set its code on an EOA address.
 * This lets us test all logic paths without requiring a 7702-enabled client.
 *
 * EIP-7702 simulation via vm.etch:
 *   - Deploy AirAccountDelegate (get implementation bytecode)
 *   - vm.etch(eoaAddress, runtimeCode) — sets EOA's code to the implementation
 *   - Now calling eoaAddress invokes AirAccountDelegate logic
 *   - address(this) inside the delegate = eoaAddress (not the impl address)
 *
 * Note: vm.etch sets code but not the ERC-7201 storage. Tests use the eoaAddress directly.
 */
contract AirAccountDelegateTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Test Actors ──────────────────────────────────────────────────────────

    uint256 constant EOA_KEY = 0xEE0A;       // the delegating EOA's private key
    uint256 constant G1_KEY  = 0x6A4D;       // guardian 1 private key
    uint256 constant G2_KEY  = 0x6B5E;       // guardian 2 private key
    uint256 constant G3_KEY  = 0x6C6F;       // guardian 3 private key (not default guardian)
    uint256 constant OTHER_KEY = 0xBAD1;

    address eoa;           // the "delegating" EOA address
    address guardian1;
    address guardian2;
    address guardian3;
    address other;

    address ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // The delegate instance bound to eoa address (after vm.etch)
    AirAccountDelegate delegate;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        eoa       = vm.addr(EOA_KEY);
        guardian1 = vm.addr(G1_KEY);
        guardian2 = vm.addr(G2_KEY);
        guardian3 = vm.addr(G3_KEY);
        other     = vm.addr(OTHER_KEY);

        // Simulate EIP-7702: deploy implementation, etch its runtime code onto the EOA
        AirAccountDelegate impl = new AirAccountDelegate();
        bytes memory runtimeCode = address(impl).code;
        vm.etch(eoa, runtimeCode);

        // Now address(eoa) has AirAccountDelegate code — cast it
        delegate = AirAccountDelegate(payable(eoa));

        // Fund EOA with some ETH (EIP-7702 EOAs hold native ETH)
        vm.deal(eoa, 10 ether);

        // Advance past block.timestamp = 0
        vm.warp(1_000_000);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Build guardian acceptance signature for the eoa.
    function _guardianSig(uint256 guardianKey, address guardianAddr) internal view returns (bytes memory) {
        // Domain: keccak256(abi.encodePacked("ACCEPT_GUARDIAN_7702", chainId, eoa, guardian))
        bytes32 inner = keccak256(abi.encodePacked(
            "ACCEPT_GUARDIAN_7702",
            block.chainid,
            eoa,           // address(this) inside delegate = eoa
            guardianAddr
        ));
        bytes32 ethHash = inner.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Initialize the delegate with default guardians and 1 ETH daily limit.
    function _initialize(uint256 dailyLimit) internal {
        bytes memory g1sig = _guardianSig(G1_KEY, guardian1);
        bytes memory g2sig = _guardianSig(G2_KEY, guardian2);
        vm.prank(eoa); // msg.sender must be eoa (the "self" call)
        delegate.initialize(guardian1, g1sig, guardian2, g2sig, dailyLimit);
    }

    /// @dev Build a minimal PackedUserOperation for testing.
    function _userOp(bytes memory signature) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: eoa,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    /// @dev Build ECDSA signature for a UserOp hash (65-byte raw format).
    function _signUserOp(bytes32 userOpHash) internal pure returns (bytes memory) {
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build prefixed [0x02][r][s][v] format.
    function _signUserOpPrefixed(bytes32 userOpHash) internal pure returns (bytes memory) {
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, ethHash);
        return abi.encodePacked(uint8(0x02), r, s, v);
    }

    // ─── 1. Initialize ────────────────────────────────────────────────────────

    function test_initialize_success() public {
        _initialize(1 ether);
        assertTrue(delegate.isInitialized());
        assertEq(delegate.getGuardians()[0], guardian1);
        assertEq(delegate.getGuardians()[1], guardian2);
    }

    function test_initialize_deploysGuard() public {
        _initialize(1 ether);
        address guard = delegate.getGuard();
        assertTrue(guard != address(0));
        // Guard is bound to eoa
        assertEq(AAStarGlobalGuard(guard).account(), eoa);
    }

    function test_initialize_onlySelf_reverts() public {
        bytes memory g1sig = _guardianSig(G1_KEY, guardian1);
        bytes memory g2sig = _guardianSig(G2_KEY, guardian2);
        // Caller is 'other', not the EOA itself
        vm.prank(other);
        vm.expectRevert(AirAccountDelegate.OnlySelf.selector);
        delegate.initialize(guardian1, g1sig, guardian2, g2sig, 1 ether);
    }

    function test_initialize_doubleInit_reverts() public {
        _initialize(1 ether);
        bytes memory g1sig = _guardianSig(G1_KEY, guardian1);
        bytes memory g2sig = _guardianSig(G2_KEY, guardian2);
        vm.prank(eoa);
        vm.expectRevert(AirAccountDelegate.AlreadyInitialized.selector);
        delegate.initialize(guardian1, g1sig, guardian2, g2sig, 1 ether);
    }

    function test_initialize_badGuardianSig_reverts() public {
        // Sign with OTHER_KEY but claim it's guardian1
        bytes32 inner = keccak256(abi.encodePacked(
            "ACCEPT_GUARDIAN_7702", block.chainid, eoa, guardian1
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_KEY, inner.toEthSignedMessageHash());
        bytes memory badSig = abi.encodePacked(r, s, v);
        bytes memory g2sig = _guardianSig(G2_KEY, guardian2);

        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(AirAccountDelegate.InvalidGuardianSignature.selector, guardian1));
        delegate.initialize(guardian1, badSig, guardian2, g2sig, 1 ether);
    }

    function test_initialize_zeroGuardian_reverts() public {
        bytes memory g2sig = _guardianSig(G2_KEY, guardian2);
        vm.prank(eoa);
        vm.expectRevert(AirAccountDelegate.InvalidAddress.selector);
        delegate.initialize(address(0), "", guardian2, g2sig, 1 ether);
    }

    // ─── 2. owner() ───────────────────────────────────────────────────────────

    function test_owner_returnsEOA() public view {
        // owner() must return address(this) = eoa
        assertEq(delegate.owner(), eoa);
    }

    // ─── 3. validateUserOp ────────────────────────────────────────────────────

    function test_validateUserOp_validECDSA_returns0() public {
        _initialize(1 ether);
        bytes32 userOpHash = keccak256("test-userop-hash");

        bytes memory sig = _signUserOp(userOpHash);
        PackedUserOperation memory op = _userOp(sig);

        // Only callable by EntryPoint
        vm.prank(ENTRY_POINT);
        uint256 result = delegate.validateUserOp(op, userOpHash, 0);
        assertEq(result, 0);
    }

    function test_validateUserOp_prefixedECDSA_returns0() public {
        _initialize(1 ether);
        bytes32 userOpHash = keccak256("test-userop-prefixed");
        bytes memory sig = _signUserOpPrefixed(userOpHash);
        PackedUserOperation memory op = _userOp(sig);

        vm.prank(ENTRY_POINT);
        uint256 result = delegate.validateUserOp(op, userOpHash, 0);
        assertEq(result, 0);
    }

    function test_validateUserOp_wrongSigner_returns1() public {
        _initialize(1 ether);
        bytes32 userOpHash = keccak256("test-userop");

        // Sign with OTHER_KEY, not EOA_KEY
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_KEY, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(ENTRY_POINT);
        uint256 result = delegate.validateUserOp(_userOp(sig), userOpHash, 0);
        assertEq(result, 1);
    }

    function test_validateUserOp_emptySignature_returns1() public {
        _initialize(1 ether);
        bytes32 userOpHash = keccak256("test");

        vm.prank(ENTRY_POINT);
        uint256 result = delegate.validateUserOp(_userOp(""), userOpHash, 0);
        assertEq(result, 1);
    }

    function test_validateUserOp_onlyEntryPoint_reverts() public {
        _initialize(1 ether);
        bytes32 userOpHash = keccak256("test");
        bytes memory sig = _signUserOp(userOpHash);

        vm.prank(other); // not EntryPoint
        vm.expectRevert(AirAccountDelegate.OnlySelfOrEntryPoint.selector);
        delegate.validateUserOp(_userOp(sig), userOpHash, 0);
    }

    function test_validateUserOp_notInitialized_reverts() public {
        bytes32 userOpHash = keccak256("test");
        bytes memory sig = _signUserOp(userOpHash);

        vm.prank(ENTRY_POINT);
        vm.expectRevert(AirAccountDelegate.NotInitialized.selector);
        delegate.validateUserOp(_userOp(sig), userOpHash, 0);
    }

    // ─── 4. execute ───────────────────────────────────────────────────────────

    function test_execute_bySelf_succeeds() public {
        _initialize(1 ether);
        address target = makeAddr("target");

        // Owner (eoa) calls execute directly — transfers 0.1 ETH
        vm.prank(eoa);
        delegate.execute(target, 0.1 ether, "");

        assertEq(target.balance, 0.1 ether);
    }

    function test_execute_byOther_reverts() public {
        _initialize(1 ether);
        vm.prank(other);
        vm.expectRevert(AirAccountDelegate.OnlySelfOrEntryPoint.selector);
        delegate.execute(other, 0.01 ether, "");
    }

    function test_execute_guardEnforcesEthLimit() public {
        _initialize(0.5 ether); // daily limit = 0.5 ETH
        address target = makeAddr("target");

        // 0.6 ETH > daily limit → guard reverts
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.DailyLimitExceeded.selector, 0.6 ether, 0.5 ether
        ));
        delegate.execute(target, 0.6 ether, "");
    }

    function test_execute_withinGuardLimit_passes() public {
        _initialize(1 ether); // daily limit = 1 ETH
        address target = makeAddr("target");

        vm.prank(eoa);
        delegate.execute(target, 0.3 ether, ""); // within limit
        assertEq(target.balance, 0.3 ether);
    }

    // ─── 5. executeBatch ─────────────────────────────────────────────────────

    function test_executeBatch_succeeds() public {
        _initialize(2 ether);
        address t1 = makeAddr("t1");
        address t2 = makeAddr("t2");

        address[] memory dests = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[]   memory data   = new bytes[](2);
        dests[0] = t1; values[0] = 0.1 ether;
        dests[1] = t2; values[1] = 0.2 ether;

        vm.prank(eoa);
        delegate.executeBatch(dests, values, data);

        assertEq(t1.balance, 0.1 ether);
        assertEq(t2.balance, 0.2 ether);
    }

    // ─── 6. Guardian Rescue ───────────────────────────────────────────────────

    function test_rescue_initiateByGuardian_succeeds() public {
        _initialize(1 ether);
        address rescueTo = makeAddr("newAddress");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueTo);

        (address to, uint256 ts,, ) = delegate.getRescueState();
        assertEq(to, rescueTo);
        assertGt(ts, 0);
    }

    function test_rescue_initiate_byNonGuardian_reverts() public {
        _initialize(1 ether);
        vm.prank(other);
        vm.expectRevert(AirAccountDelegate.OnlyGuardian.selector);
        delegate.initiateRescue(makeAddr("new"));
    }

    function test_rescue_twoGuardians_reachThreshold() public {
        _initialize(1 ether);
        address rescueTo = makeAddr("newAddress");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueTo);

        vm.prank(guardian2);
        delegate.approveRescue();

        (,,, bool approved) = delegate.getRescueState();
        assertTrue(approved);
    }

    function test_rescue_executeAfterTimelock() public {
        _initialize(1 ether);
        address rescueTo = makeAddr("rescueTarget");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueTo);
        vm.prank(guardian2);
        delegate.approveRescue();

        // Warp past 2-day timelock
        vm.warp(block.timestamp + 2 days + 1);

        uint256 balanceBefore = rescueTo.balance;
        uint256 eoaBalance = eoa.balance; // should be 10 ether from setUp

        delegate.executeRescue();

        assertEq(rescueTo.balance, balanceBefore + eoaBalance);
        assertEq(eoa.balance, 0);
    }

    function test_rescue_executeBeforeTimelock_reverts() public {
        _initialize(1 ether);
        address rescueTo = makeAddr("new");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueTo);
        vm.prank(guardian2);
        delegate.approveRescue();

        // Still within timelock
        vm.expectRevert(AirAccountDelegate.RescueTimelockNotExpired.selector);
        delegate.executeRescue();
    }

    function test_rescue_cancelBySelf() public {
        _initialize(1 ether);
        vm.prank(guardian1);
        delegate.initiateRescue(makeAddr("new"));

        vm.prank(eoa); // EOA still has key, can cancel
        delegate.cancelRescue();

        (, uint256 ts,,) = delegate.getRescueState();
        assertEq(ts, 0);
    }

    function test_rescue_cancelByOther_reverts() public {
        _initialize(1 ether);
        vm.prank(guardian1);
        delegate.initiateRescue(makeAddr("new"));

        vm.prank(other);
        vm.expectRevert(AirAccountDelegate.OnlySelf.selector);
        delegate.cancelRescue();
    }

    function test_rescue_duplicateApproval_reverts() public {
        _initialize(1 ether);
        vm.prank(guardian1);
        delegate.initiateRescue(makeAddr("new"));

        vm.prank(guardian1); // same guardian trying to approve twice
        vm.expectRevert(AirAccountDelegate.GuardianAlreadyApproved.selector);
        delegate.approveRescue();
    }

    // ─── 6b. ExecuteBatch edge cases ──────────────────────────────────────────

    function test_executeBatch_arrayMismatch_reverts() public {
        _initialize(5 ether);
        address[] memory dests  = new address[](2);
        uint256[] memory values = new uint256[](3); // mismatch
        bytes[]   memory data   = new bytes[](2);
        vm.prank(eoa);
        vm.expectRevert(AirAccountDelegate.InvalidAddress.selector);
        delegate.executeBatch(dests, values, data);
    }

    function test_executeBatch_dataMismatch_reverts() public {
        _initialize(5 ether);
        address[] memory dests  = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[]   memory data   = new bytes[](3); // mismatch
        vm.prank(eoa);
        vm.expectRevert(AirAccountDelegate.InvalidAddress.selector);
        delegate.executeBatch(dests, values, data);
    }

    // ─── 6c. Rescue completeness ─────────────────────────────────────────────

    /// @notice executeRescue should actually transfer ETH to rescueTo
    function test_rescue_executeTransfersETH() public {
        _initialize(1 ether);
        address rescueDest = makeAddr("safeWallet");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueDest);
        vm.prank(guardian2);
        delegate.approveRescue();

        vm.warp(block.timestamp + 2 days + 1);

        uint256 eoaBalBefore  = address(eoa).balance;
        uint256 destBalBefore = rescueDest.balance;

        delegate.executeRescue(); // anyone can call after timelock

        assertEq(address(eoa).balance, 0,                                  "EOA should be drained");
        assertEq(rescueDest.balance,   destBalBefore + eoaBalBefore,        "rescueDest should receive all ETH");
    }

    /// @notice executeRescue with zero balance completes without revert
    function test_rescue_executeWithZeroBalance() public {
        _initialize(1 ether);
        address rescueDest = makeAddr("safeWallet");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueDest);
        vm.prank(guardian2);
        delegate.approveRescue();
        vm.warp(block.timestamp + 2 days + 1);

        // Drain EOA first (simulate attacker taking ETH via direct call)
        vm.deal(eoa, 0);

        delegate.executeRescue(); // should not revert even with 0 balance
        assertEq(rescueDest.balance, 0);
    }

    /// @notice cancelRescue after approval clears all state (not just timestamp)
    function test_rescue_cancelAfterApproval_clearsState() public {
        _initialize(1 ether);
        address rescueDest = makeAddr("safeWallet");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueDest);
        vm.prank(guardian2);
        delegate.approveRescue(); // now approved

        (, uint256 ts, uint8 approvals, bool approved) = delegate.getRescueState();
        assertTrue(approved, "should be approved before cancel");

        vm.prank(eoa); // EOA self-cancels
        delegate.cancelRescue();

        (address to2, uint256 ts2, uint8 ap2, bool appr2) = delegate.getRescueState();
        assertEq(to2,   address(0), "rescueTo cleared");
        assertEq(ts2,   0,          "timestamp cleared");
        assertEq(ap2,   0,          "approvals cleared");
        assertFalse(appr2,          "approved flag cleared");
    }

    /// @notice After cancel, executeRescue should revert
    function test_rescue_executeAfterCancel_reverts() public {
        _initialize(1 ether);
        address rescueDest = makeAddr("safeWallet");

        vm.prank(guardian1);
        delegate.initiateRescue(rescueDest);
        vm.prank(guardian2);
        delegate.approveRescue();

        vm.prank(eoa);
        delegate.cancelRescue();

        vm.expectRevert(AirAccountDelegate.NoRescuePending.selector);
        delegate.executeRescue();
    }

    /// @notice Guardian can override a pending rescue with a different destination
    ///         (resets timer and approvals — design decision)
    function test_rescue_overrideWithDifferentDestination() public {
        _initialize(1 ether);
        address dest1 = makeAddr("dest1");
        address dest2 = makeAddr("dest2");

        vm.prank(guardian1);
        delegate.initiateRescue(dest1);

        // guardian1 changes their mind
        vm.prank(guardian1);
        delegate.initiateRescue(dest2);

        (address to,, uint8 approvals,) = delegate.getRescueState();
        assertEq(to, dest2, "destination should be updated");
        // approvals reset to initiator's vote only (bit0 = 1)
        assertEq(approvals, 1, "approvals reset to initiator only");
    }

    // ─── 6d. WithdrawDepositTo access control ────────────────────────────────

    function test_withdrawDepositTo_notSelf_reverts() public {
        _initialize(1 ether);
        vm.prank(other);
        vm.expectRevert(AirAccountDelegate.OnlySelf.selector);
        delegate.withdrawDepositTo(payable(other), 0);
    }

    // ─── 7. Deposit management ────────────────────────────────────────────────

    function test_addDeposit_forwardsToEntryPoint() public {
        _initialize(1 ether);
        // This would revert if EntryPoint isn't deployed on the test fork.
        // We mock the call to avoid network dependency.
        vm.mockCall(
            address(0x0000000071727De22E5E9d8BAf0edAc6f37da032),
            abi.encodeWithSignature("depositTo(address)", eoa),
            ""
        );
        delegate.addDeposit{value: 0.01 ether}();
    }
}
