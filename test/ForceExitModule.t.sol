// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ForceExitModule} from "../src/core/ForceExitModule.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ─── Mocks ─────────────────────────────────────────────────────────────────

/// @dev Records calls to initiateWithdrawal so tests can verify invocation
contract MockL2MessagePasser {
    address public lastTarget;
    uint256 public lastGasLimit;
    bytes   public lastData;
    uint256 public callCount;

    function initiateWithdrawal(address _target, uint256 _gasLimit, bytes calldata _data) external payable {
        lastTarget   = _target;
        lastGasLimit = _gasLimit;
        lastData     = _data;
        callCount++;
    }
}

/// @dev Records calls to sendTxToL1 so tests can verify Arbitrum invocation
contract MockArbSys {
    address public lastDest;
    bytes   public lastData;
    uint256 public callCount;

    function sendTxToL1(address dest, bytes calldata data) external payable returns (uint256) {
        lastDest  = dest;
        lastData  = data;
        callCount++;
        return callCount;
    }
}

/// @dev A bare contract with no guardians() getter — simulates non-standard ERC-7579 account
contract NoGuardiansAccount {
    ForceExitModule internal _module;
    constructor(ForceExitModule m) { _module = m; }
    function tryInstall() external {
        _module.onInstall(abi.encode(uint8(1)));
    }
    receive() external payable {}
}

/// @dev Simulates an AirAccount that exposes guardians(i) and owner()
contract MockAirAccount {
    address public owner;
    address[3] private _guardianSlots;

    constructor(address _owner, address[3] memory g) {
        owner = _owner;
        _guardianSlots = g;
    }

    /// @dev ERC-7579-compatible guardian getter (matches AAStarAirAccountBase.guardians)
    function guardians(uint256 i) external view returns (address) {
        if (i < 3) return _guardianSlots[i];
        return address(0);
    }

    /// @dev Test helper: simulate guardian rotation (owner replaces guardian at slot i).
    ///      Matches the on-chain `removeGuardian` + `addGuardian` sequence behaviorally:
    ///      the slot is overwritten with the new guardian address. Used to verify the
    ///      v0.17.2-beta.2 stale-guardian check in `approveForceExit`.
    function rotateGuardian(uint256 i, address newGuardian) external {
        require(i < 3, "slot out of range");
        _guardianSlots[i] = newGuardian;
    }

    /// @dev Install the module (calls onInstall on msg.sender = module)
    function installModule(ForceExitModule module, bytes calldata data) external {
        module.onInstall(data);
    }

    /// @dev Uninstall the module
    function uninstallModule(ForceExitModule module) external {
        module.onUninstall("");
    }

    /// @dev Propose force exit through the module
    function proposeExit(ForceExitModule module, address target, uint256 value, bytes calldata data) external {
        module.proposeForceExit(target, value, data);
    }

    /// @dev Cancel force exit (as the account itself, msg.sender = account)
    function cancelExit(ForceExitModule module) external {
        module.cancelForceExit(address(this));
    }

    /// @dev Execute force exit (as a third party calling on the account)
    function executeExit(ForceExitModule module) external {
        module.executeForceExit(address(this));
    }

    /// @dev v0.17.2: ForceExitModule now routes the bridge call through this function
    ///      (the real V7's executeFromExecutor entry point). The mock just performs the call
    ///      from its own balance, mimicking real V7 behaviour.
    function executeFromExecutor(bytes32 /* mode */, bytes calldata executionCalldata)
        external returns (bytes[] memory returnData)
    {
        // Layout: [target(20)][value(32)][data...]
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value  = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];

        returnData = new bytes[](1);
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "executor call failed");
        returnData[0] = ret;
    }

    /// @dev Receive ETH (needed for value-forwarding tests)
    receive() external payable {}
}

/// @dev An account that exposes guardians()/owner() normally but can be toggled to revert
///      its guardians(uint256) getter — simulates a non-standard / broken account that passes
///      onInstall (guardians valid at install) but later fails the getter. Used to prove the
///      v0.18 issue #77 fix: `_readGuardians` reverts IncompatibleAccount instead of silently
///      degrading to address(0).
contract MockBreakableAccount {
    address public owner;
    address[3] private _guardianSlots;
    bool public broken;

    constructor(address _owner, address[3] memory g) {
        owner = _owner;
        _guardianSlots = g;
    }

    function setBroken(bool b) external { broken = b; }

    function guardians(uint256 i) external view returns (address) {
        require(!broken, "guardians getter broken");
        if (i < 3) return _guardianSlots[i];
        return address(0);
    }

    function installModule(ForceExitModule module, bytes calldata data) external {
        module.onInstall(data);
    }

    function proposeExit(ForceExitModule module, address target, uint256 value, bytes calldata data) external {
        module.proposeForceExit(target, value, data);
    }

    function executeFromExecutor(bytes32 /* mode */, bytes calldata executionCalldata)
        external returns (bytes[] memory returnData)
    {
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value  = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];
        returnData = new bytes[](1);
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "executor call failed");
        returnData[0] = ret;
    }

    receive() external payable {}
}

// ─── Test ──────────────────────────────────────────────────────────────────

/// @title ForceExitModuleTest — Unit tests for ForceExitModule (C10)
contract ForceExitModuleTest is Test {
    using MessageHashUtils for bytes32;

    // Mirror module constants for use in tests (contract-level constants cannot be accessed as Type.CONST)
    uint8 internal constant L2_TYPE_OPTIMISM = 1;
    uint8 internal constant L2_TYPE_ARBITRUM = 2;
    address internal constant L2_TO_L1_MESSAGE_PASSER_OP = 0x4200000000000000000000000000000000000016;

    ForceExitModule public module;
    MockAirAccount  public account;
    MockL2MessagePasser public mockPasser;
    MockArbSys       public mockArbSys;

    // Guardian private keys (deterministic test keys)
    uint256 internal constant G0_KEY = 0xA11CE00000000000000000000000000000000000000000000000000000000001;
    uint256 internal constant G1_KEY = 0xB0B0000000000000000000000000000000000000000000000000000000000002;
    uint256 internal constant G2_KEY = 0xCA11000000000000000000000000000000000000000000000000000000000003;

    address internal g0;
    address internal g1;
    address internal g2;
    address internal owner;

    function setUp() public {
        g0    = vm.addr(G0_KEY);
        g1    = vm.addr(G1_KEY);
        g2    = vm.addr(G2_KEY);
        owner = makeAddr("owner");

        module = new ForceExitModule();
        mockPasser = new MockL2MessagePasser();
        mockArbSys = new MockArbSys();

        address[3] memory guardians = [g0, g1, g2];
        account = new MockAirAccount(owner, guardians);
    }

    // ─── Helper: install module via account ──────────────────────────────────

    function _install(uint8 l2Type) internal {
        account.installModule(module, abi.encode(l2Type));
    }

    function _installOp() internal {
        _install(L2_TYPE_OPTIMISM);
    }

    function _installArb() internal {
        account.installModule(module, abi.encode(L2_TYPE_ARBITRUM));
    }

    /// @dev Build a guardian signature over the proposal hash
    function _guardianSig(
        uint256 privKey,
        address acc,
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposedAt
    ) internal view returns (bytes memory) {
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "FORCE_EXIT",
                block.chainid,
                acc,
                target,
                value,
                data,
                proposedAt
            )
        );
        bytes32 ethHash = msgHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── onInstall ────────────────────────────────────────────────────────────

    function test_onInstall_setsL2Type() public {
        _install(L2_TYPE_OPTIMISM);
        assertEq(module.accountL2Type(address(account)), L2_TYPE_OPTIMISM);
    }

    function test_onInstall_arbitrum_setsL2Type() public {
        _install(L2_TYPE_ARBITRUM);
        assertEq(module.accountL2Type(address(account)), L2_TYPE_ARBITRUM);
    }

    function test_onInstall_setsInitialized() public {
        assertFalse(module.isInitialized(address(account)));
        _installOp();
        assertTrue(module.isInitialized(address(account)));
    }

    function test_onInstall_incompatibleAccount_reverts() public {
        NoGuardiansAccount bad = new NoGuardiansAccount(module);
        vm.expectRevert(ForceExitModule.IncompatibleAccount.selector);
        bad.tryInstall();
    }

    function test_onInstall_zeroGuardian_reverts() public {
        // Account has guardians() getter but returns address(0) for index 0.
        // Without the return-value check this would install silently, creating a zombie module.
        MockAirAccount zeroGuard = new MockAirAccount(owner, [address(0), address(0), address(0)]);
        vm.expectRevert(ForceExitModule.IncompatibleAccount.selector);
        vm.prank(address(zeroGuard));
        module.onInstall(abi.encode(uint8(1)));
    }

    // ─── onUninstall ─────────────────────────────────────────────────────────

    function test_onUninstall_clearsState() public {
        _installOp();
        assertTrue(module.isInitialized(address(account)));

        account.uninstallModule(module);

        assertFalse(module.isInitialized(address(account)));
        assertEq(module.accountL2Type(address(account)), 0);
    }

    function test_onUninstall_clearsPendingProposal() public {
        _installOp();
        // Create a proposal
        account.proposeExit(module, makeAddr("l1target"), 0.1 ether, "");

        // Uninstall should clear it
        account.uninstallModule(module);

        // After uninstall, pendingExit should be gone (proposedAt = 0)
        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    // ─── isInitialized ────────────────────────────────────────────────────────

    function test_isInitialized_beforeInstall_false() public view {
        assertFalse(module.isInitialized(address(account)));
    }

    function test_isInitialized_afterInstall_true() public {
        _installOp();
        assertTrue(module.isInitialized(address(account)));
    }

    function test_isInitialized_differentAccounts_isolated() public {
        address[3] memory g = [g0, g1, g2];
        MockAirAccount accountB = new MockAirAccount(makeAddr("ownerB"), g);

        _installOp();
        accountB.installModule(module, abi.encode(L2_TYPE_ARBITRUM));

        assertTrue(module.isInitialized(address(account)));
        assertTrue(module.isInitialized(address(accountB)));
        assertEq(module.accountL2Type(address(account)), L2_TYPE_OPTIMISM);
        assertEq(module.accountL2Type(address(accountB)), L2_TYPE_ARBITRUM);
    }

    // ─── proposeForceExit ─────────────────────────────────────────────────────

    function test_proposeForceExit_storesProposal() public {
        _installOp();
        address l1target = makeAddr("l1target");

        vm.warp(1000); // Set a known timestamp
        account.proposeExit(module, l1target, 0.5 ether, "");

        (address target, uint256 value,, uint256 proposedAt, uint256 bitmap,) =
            _pendingExitFields(address(account));

        assertEq(target, l1target);
        assertEq(value, 0.5 ether);
        assertEq(proposedAt, 1000);
        assertEq(bitmap, 0);
    }

    function test_proposeForceExit_snapshotsGuardians() public {
        _installOp();
        account.proposeExit(module, makeAddr("l1target"), 0, "");

        // Read the guardians from the proposal via the public mapping
        // pendingExit returns a struct — access by destructuring
        (,,,,, address[3] memory guardians) = _pendingExitFields(address(account));
        assertEq(guardians[0], g0);
        assertEq(guardians[1], g1);
        assertEq(guardians[2], g2);
    }

    function test_proposeForceExit_emitsEvent() public {
        _installOp();
        address l1target = makeAddr("l1target");

        vm.expectEmit(true, true, false, true);
        emit ForceExitModule.ExitProposed(address(account), l1target, 0.3 ether);

        account.proposeExit(module, l1target, 0.3 ether, "");
    }

    function test_proposeForceExit_alreadyProposed_reverts() public {
        _installOp();
        account.proposeExit(module, makeAddr("l1target"), 0, "");

        vm.expectRevert(ForceExitModule.AlreadyProposed.selector);
        account.proposeExit(module, makeAddr("l1target2"), 0, "");
    }

    // ─── approveForceExit ─────────────────────────────────────────────────────

    function test_approveForceExit_validGuardianSig_incrementsBitmap() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(1000);
        account.proposeExit(module, l1target, 0.1 ether, "");

        bytes memory sig = _guardianSig(G0_KEY, address(account), l1target, 0.1 ether, "", 1000);
        module.approveForceExit(address(account), sig);

        (,,,, uint256 bitmap,) = _pendingExitFields(address(account));
        assertEq(bitmap, 1); // bit 0 set
    }

    function test_approveForceExit_secondGuardian_setsBit1() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(2000);
        account.proposeExit(module, l1target, 0.2 ether, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0.2 ether, "", 2000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0.2 ether, "", 2000);

        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        (,,,, uint256 bitmap,) = _pendingExitFields(address(account));
        assertEq(bitmap, 3); // bits 0 and 1 set
    }

    function test_approveForceExit_duplicateApproval_reverts() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(3000);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig = _guardianSig(G0_KEY, address(account), l1target, 0, "", 3000);
        module.approveForceExit(address(account), sig);

        vm.expectRevert(ForceExitModule.AlreadyApproved.selector);
        module.approveForceExit(address(account), sig);
    }

    // ─── v0.17.2-beta.2 LOW-3 stale-guardian fix tests ────────────────────

    /// @dev After owner rotates a guardian (Bob removed, replaced by Carol), Bob's old
    ///      signature should NO LONGER pass approveForceExit — even though the snapshot
    ///      still contains Bob's address.
    function test_approveForceExit_rotatedGuardian_reverts() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(5000);
        account.proposeExit(module, l1target, 0.1 ether, "");

        // Bob (g0 in the snapshot) signs while still being a guardian
        bytes memory bobSig = _guardianSig(G0_KEY, address(account), l1target, 0.1 ether, "", 5000);

        // Owner rotates g0: Bob → Carol
        address carol = makeAddr("carol");
        account.rotateGuardian(0, carol);

        // Bob's signature should now fail SignerNoLongerGuardian
        vm.expectRevert(ForceExitModule.SignerNoLongerGuardian.selector);
        module.approveForceExit(address(account), bobSig);
    }

    /// @dev Renamed 2026-06-02 (David PR #68 NIT-2): name was `..._succeeds` but actually asserts a
    ///      revert. Behavior under test: rotating a guardian after propose locks the proposal
    ///      entirely — old guardian fails SignerNoLongerGuardian, new guardian fails
    ///      InvalidGuardianSig (not in snapshot). Owner must re-propose with fresh snapshot.
    ///      See docs/forceexit-design-notes.md §5.
    function test_approveForceExit_postRotation_newGuardian_revertsInvalidGuardianSig() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(5001);
        account.proposeExit(module, l1target, 0.1 ether, "");

        // Owner rotates g0 BEFORE Bob signs
        uint256 CAROL_KEY = 0xCA401;
        address carol = vm.addr(CAROL_KEY);
        account.rotateGuardian(0, carol);

        // Carol signs the SAME proposal hash (snapshot still has Bob in slot 0,
        // but Carol now occupies that current-guardian slot)
        // Wait — the snapshot still contains Bob, so Carol's recovered signer won't be
        // in the snapshot. This test demonstrates the rotation invalidates the proposal
        // entirely (Carol can't sign because she's not in the snapshot).
        bytes memory carolSig = _guardianSig(CAROL_KEY, address(account), l1target, 0.1 ether, "", 5001);

        vm.expectRevert(ForceExitModule.InvalidGuardianSig.selector);
        module.approveForceExit(address(account), carolSig);

        // This is by design: rotating a guardian after propose invalidates the entire
        // proposal (Bob can't sign per `SignerNoLongerGuardian`, Carol can't sign per
        // `InvalidGuardianSig` because she's not in the snapshot). Owner must propose
        // a fresh exit with the new guardian set.
    }

    /// @dev Sanity: stale-guardian check does NOT regress legitimate same-slot reuse
    ///      where the guardian is unchanged.
    function test_approveForceExit_unchangedGuardian_succeeds() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(5002);
        account.proposeExit(module, l1target, 0.1 ether, "");

        // No rotation; Bob (still g0) signs
        bytes memory sig = _guardianSig(G0_KEY, address(account), l1target, 0.1 ether, "", 5002);
        module.approveForceExit(address(account), sig);

        (,,,, uint256 bitmap,) = _pendingExitFields(address(account));
        assertEq(bitmap, 1, "bit 0 set as before");
    }

    function test_approveForceExit_nonGuardian_reverts() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(4000);
        account.proposeExit(module, l1target, 0, "");

        // Sign with a non-guardian key
        uint256 strangerKey = 0xDEAD;
        bytes memory sig = _guardianSig(strangerKey, address(account), l1target, 0, "", 4000);

        vm.expectRevert(ForceExitModule.InvalidGuardianSig.selector);
        module.approveForceExit(address(account), sig);
    }

    function test_approveForceExit_noProposal_reverts() public {
        _installOp();

        bytes memory dummySig = new bytes(65);
        vm.expectRevert(ForceExitModule.NoProposal.selector);
        module.approveForceExit(address(account), dummySig);
    }

    function test_approveForceExit_emitsEvent() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(5000);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig = _guardianSig(G1_KEY, address(account), l1target, 0, "", 5000);

        vm.expectEmit(true, true, false, false);
        emit ForceExitModule.ExitApproved(address(account), g1, 2);

        module.approveForceExit(address(account), sig);
    }

    // ─── executeForceExit ─────────────────────────────────────────────────────

    function test_executeForceExit_notEnoughApprovals_reverts() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(6000);
        account.proposeExit(module, l1target, 0, "");

        // Only 1 approval — below threshold of 2
        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 6000);
        module.approveForceExit(address(account), sig0);

        vm.expectRevert(ForceExitModule.NotEnoughApprovals.selector);
        module.executeForceExit(address(account));
    }

    function test_executeForceExit_noProposal_reverts() public {
        _installOp();

        vm.expectRevert(ForceExitModule.NoProposal.selector);
        module.executeForceExit(address(account));
    }

    function test_executeForceExit_unsupportedL2Type_reverts() public {
        // Install with l2Type=0 (unsupported)
        account.installModule(module, abi.encode(uint8(0)));

        address l1target = makeAddr("l1target");
        vm.warp(7000);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 7000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, "", 7000);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        vm.expectRevert(ForceExitModule.UnsupportedL2Type.selector);
        module.executeForceExit(address(account));
    }

    function test_executeForceExit_opStack_callsPrecompile() public {
        // Override the OP precompile address with our mock using vm.etch
        address opPrecompile = L2_TO_L1_MESSAGE_PASSER_OP;
        vm.etch(opPrecompile, address(mockPasser).code);

        // Store mockPasser storage into the etch target so callCount etc. work.
        // Since vm.etch copies only bytecode, we use a wrapper approach:
        // Deploy a separate mock and redirect calls via the etched bytecode.

        _installOp();
        address l1target = makeAddr("l1recipient");
        bytes memory exitData = hex"1234";
        vm.warp(8000);

        account.proposeExit(module, l1target, 0, exitData);

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, exitData, 8000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, exitData, 8000);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        // Execute — should call opPrecompile. Since the etch target uses MockL2MessagePasser
        // bytecode, it will record the call without reverting.
        module.executeForceExit(address(account));

        // Proposal should be cleared after execution
        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    function test_executeForceExit_emitsEvent() public {
        address opPrecompile = L2_TO_L1_MESSAGE_PASSER_OP;
        vm.etch(opPrecompile, address(mockPasser).code);

        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(9000);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 9000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, "", 9000);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        vm.expectEmit(true, true, false, true);
        emit ForceExitModule.ExitExecuted(address(account), l1target, 0);

        module.executeForceExit(address(account));
    }

    function test_executeForceExit_arbitrum_callsArbSys() public {
        // Etch MockArbSys bytecode at the ARB_SYS precompile address
        address arbSys = 0x0000000000000000000000000000000000000064;
        vm.etch(arbSys, address(mockArbSys).code);

        _installArb();
        address l1target = makeAddr("l1recipient_arb");
        bytes memory exitData = hex"abcd";
        vm.warp(10000);

        account.proposeExit(module, l1target, 0, exitData);

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, exitData, 10000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, exitData, 10000);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        module.executeForceExit(address(account));

        // Proposal cleared after execution
        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    // ─── v0.18 issue #70: TOCTOU re-verification at execute ───────────────────

    /// @dev 2 approvals recorded, then one approver is rotated out before execute.
    ///      Live approver count drops to 1 (< threshold) → ApproverNoLongerGuardian.
    ///      Proves the fix the approve-time check cannot cover (bit already set).
    function test_executeForceExit_revertsIfApproverRotatedOut() public {
        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(20000);
        account.proposeExit(module, l1target, 0, "");

        // g0 and g1 both approve while still current → bitmap = 3, threshold met.
        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 20000);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, "", 20000);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        // Owner rotates g1 out (slot 1 → Carol) AFTER the approval bit was set.
        account.rotateGuardian(1, makeAddr("carol"));

        // Only g0 is still a current guardian → liveApprovals = 1 < APPROVAL_THRESHOLD.
        vm.expectRevert(ForceExitModule.ApproverNoLongerGuardian.selector);
        module.executeForceExit(address(account));
    }

    /// @dev No rotation between approve and execute → live approver count unchanged → succeeds.
    function test_executeForceExit_unchangedApprovers_succeeds() public {
        vm.etch(L2_TO_L1_MESSAGE_PASSER_OP, address(mockPasser).code);

        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(20100);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 20100);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, "", 20100);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);

        module.executeForceExit(address(account));

        // Proposal cleared → execution went through.
        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    /// @dev 3 approvals, then ONE approver rotated out → 2 live approvers still ≥ threshold.
    ///      Confirms the fix is count-based (intersection ≥ threshold), NOT
    ///      revert-on-any-rotation. With 3-of-3 approved, losing 1 still executes.
    function test_executeForceExit_threeApprovals_oneRotatedOut_stillSucceeds() public {
        vm.etch(L2_TO_L1_MESSAGE_PASSER_OP, address(mockPasser).code);

        _installOp();
        address l1target = makeAddr("l1target");
        vm.warp(20200);
        account.proposeExit(module, l1target, 0, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(account), l1target, 0, "", 20200);
        bytes memory sig1 = _guardianSig(G1_KEY, address(account), l1target, 0, "", 20200);
        bytes memory sig2 = _guardianSig(G2_KEY, address(account), l1target, 0, "", 20200);
        module.approveForceExit(address(account), sig0);
        module.approveForceExit(address(account), sig1);
        module.approveForceExit(address(account), sig2);

        // Rotate g2 out — g0 and g1 remain → 2 live approvers ≥ threshold.
        account.rotateGuardian(2, makeAddr("dave"));

        module.executeForceExit(address(account));

        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    // ─── v0.18 issue #77: _readGuardians fails loudly on non-standard accounts ─

    /// @dev Account passes onInstall (guardians valid) but its guardians() getter later reverts.
    ///      `_readGuardians` (reached via approveForceExit) must revert IncompatibleAccount
    ///      explicitly rather than silently returning address(0) for every slot.
    function test_approveForceExit_brokenGuardiansGetter_revertsIncompatibleAccount() public {
        address[3] memory g = [g0, g1, g2];
        MockBreakableAccount broken = new MockBreakableAccount(owner, g);
        broken.installModule(module, abi.encode(L2_TYPE_OPTIMISM));

        address l1target = makeAddr("l1target");
        vm.warp(21000);
        broken.proposeExit(module, l1target, 0, "");

        // Break the getter after propose snapshot is taken.
        broken.setBroken(true);

        bytes memory sig0 = _guardianSig(G0_KEY, address(broken), l1target, 0, "", 21000);
        vm.expectRevert(ForceExitModule.IncompatibleAccount.selector);
        module.approveForceExit(address(broken), sig0);
    }

    /// @dev Same incompatibility surfaced at execute time: the live-approver re-check reads
    ///      guardians via `_readGuardians`, which must revert IncompatibleAccount, not silently
    ///      treat the account as having an empty guardian set.
    function test_executeForceExit_brokenGuardiansGetter_revertsIncompatibleAccount() public {
        address[3] memory g = [g0, g1, g2];
        MockBreakableAccount broken = new MockBreakableAccount(owner, g);
        broken.installModule(module, abi.encode(L2_TYPE_OPTIMISM));

        address l1target = makeAddr("l1target");
        vm.warp(21100);
        broken.proposeExit(module, l1target, 0, "");

        bytes memory sig0 = _guardianSig(G0_KEY, address(broken), l1target, 0, "", 21100);
        bytes memory sig1 = _guardianSig(G1_KEY, address(broken), l1target, 0, "", 21100);
        module.approveForceExit(address(broken), sig0);
        module.approveForceExit(address(broken), sig1);

        // Break the getter after approvals are recorded; execute must fail loudly.
        broken.setBroken(true);

        vm.expectRevert(ForceExitModule.IncompatibleAccount.selector);
        module.executeForceExit(address(broken));
    }

    function test_getPendingExit_afterPropose_returnsGuardians() public {
        _installOp();
        address l1target = makeAddr("l1target_view");
        vm.warp(11000);

        account.proposeExit(module, l1target, 1 ether, hex"cafe");

        (address target, uint256 value, bytes memory data, uint256 proposedAt,, address[3] memory guardians) =
            _pendingExitFields(address(account));

        assertEq(target, l1target);
        assertEq(value, 1 ether);
        assertEq(data, hex"cafe");
        assertEq(proposedAt, 11000);
        assertEq(guardians[0], g0);
        assertEq(guardians[1], g1);
        assertEq(guardians[2], g2);
    }

    // ─── cancelForceExit ──────────────────────────────────────────────────────

    function test_cancelForceExit_clearsProposal() public {
        _installOp();
        address l1target = makeAddr("l1target");
        account.proposeExit(module, l1target, 0, "");

        // Cancel via account (msg.sender == account)
        account.cancelExit(module);

        (address target, uint256 value,, uint256 proposedAt,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
        assertEq(value, 0);
        assertEq(proposedAt, 0);
    }

    function test_cancelForceExit_byOwner_succeeds() public {
        _installOp();
        address l1target = makeAddr("l1target");
        account.proposeExit(module, l1target, 0, "");

        // Cancel from owner EOA directly
        vm.prank(owner);
        module.cancelForceExit(address(account));

        (address target,,,,,) = _pendingExitFields(address(account));
        assertEq(target, address(0));
    }

    function test_cancelForceExit_notOwner_reverts() public {
        _installOp();
        account.proposeExit(module, makeAddr("l1target"), 0, "");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ForceExitModule.NotOwner.selector);
        module.cancelForceExit(address(account));
    }

    function test_cancelForceExit_noProposal_reverts() public {
        _installOp();

        vm.expectRevert(ForceExitModule.NoProposal.selector);
        account.cancelExit(module);
    }

    function test_cancelForceExit_emitsEvent() public {
        _installOp();
        account.proposeExit(module, makeAddr("l1target"), 0, "");

        vm.expectEmit(true, false, false, false);
        emit ForceExitModule.ExitCancelled(address(account));

        account.cancelExit(module);
    }

    // ─── Cross-account isolation ──────────────────────────────────────────────

    function test_multipleAccounts_isolated() public {
        address[3] memory g = [g0, g1, g2];
        MockAirAccount accountB = new MockAirAccount(makeAddr("ownerB"), g);

        account.installModule(module, abi.encode(L2_TYPE_OPTIMISM));
        accountB.installModule(module, abi.encode(L2_TYPE_ARBITRUM));

        account.proposeExit(module, makeAddr("t1"), 1 ether, "");
        accountB.proposeExit(module, makeAddr("t2"), 2 ether, "");

        (address targetA,,,,,) = _pendingExitFields(address(account));
        (address targetB,,,,,) = _pendingExitFields(address(accountB));
        assertEq(targetA, makeAddr("t1"));
        assertEq(targetB, makeAddr("t2"));
    }

    // ─── Internal helper: destructure pendingExit mapping ────────────────────

    /// @dev Expose pendingExit fields since Solidity returns a struct from public mapping
    function _pendingExitFields(address acc) internal view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposedAt,
        uint256 approvalBitmap,
        address[3] memory guardians
    ) {
        (target, value, data, proposedAt, approvalBitmap, guardians) = _decodePendingExit(acc);
    }

    function _decodePendingExit(address acc) internal view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposedAt,
        uint256 approvalBitmap,
        address[3] memory guardians
    ) {
        // Use the explicit getPendingExit() getter — the auto-generated pendingExit()
        // mapping getter omits bytes and address[3] fields.
        (bool ok, bytes memory result) = address(module).staticcall(
            abi.encodeWithSignature("getPendingExit(address)", acc)
        );
        require(ok, "getPendingExit call failed");
        (target, value, data, proposedAt, approvalBitmap, guardians) =
            abi.decode(result, (address, uint256, bytes, uint256, uint256, address[3]));
    }
}
