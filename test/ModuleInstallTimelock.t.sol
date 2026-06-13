// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

// ─── Minimal mock EntryPoint ─────────────────────────────────────────────────
contract MockEP {
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function withdrawTo(address payable, uint256) external {}
    receive() external payable {}
}

// ─── Mock module tracking onInstall calls and the data it received ────────────
contract TrackingModule {
    uint256 public installCount;
    bytes public lastInitData;

    function onInstall(bytes calldata data) external { installCount++; lastInitData = data; }
    function onUninstall(bytes calldata) external {}
    function validateUserOp(PackedUserOperation calldata, bytes32) external pure returns (uint256) { return 0; }
    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
    receive() external payable {}
    fallback() external payable {}
}

// ─── Mock module that reverts on onInstall ────────────────────────────────────
contract RevertingModule {
    function onInstall(bytes calldata) external pure { revert("install failed"); }
    function onUninstall(bytes calldata) external pure {}
    receive() external payable {}
    fallback() external payable {}
}

// ─── Extension surface reached via the account's fallback (diamond-lite) ──────
interface IModuleTimelock {
    function moduleInstallTimelock() external view returns (uint256);
    function pendingModuleInstall()
        external
        view
        returns (address module, uint8 moduleTypeId, uint40 proposedAt, uint40 executeAfter, bytes32 initDataHash);
    function setModuleInstallTimelock(uint256 newTimelock, bytes calldata guardianSigs) external;
    function proposeModuleInstall(uint256 moduleTypeId, address module, bytes calldata initData) external;
    function executeModuleInstall(bytes calldata moduleInitData) external;
    function cancelModuleInstall() external;
}

/// @title ModuleInstallTimelockTest — KI-6 / issue #58
contract ModuleInstallTimelockTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    AAStarAirAccountV7 public account;
    IModuleTimelock public ext;        // same address as `account`, extension ABI view
    MockEP public ep;

    Vm.Wallet ownerWallet;
    Vm.Wallet g0Wallet;
    Vm.Wallet g1Wallet;
    Vm.Wallet g2Wallet;
    Vm.Wallet randomWallet;

    TrackingModule public mod;

    uint8 internal constant GUARDIAN_SIG_VERSION = 4;
    uint256 internal constant TIMELOCK = 2 days;
    uint256 internal constant VALIDATOR = 1;

    // mirror events for expectEmit
    event ModuleInstalled(uint256 indexed moduleTypeId, address indexed module);
    event ModuleInstallProposed(uint256 indexed moduleTypeId, address indexed module, uint256 executeAfter);
    event ModuleInstallExecuted(uint256 indexed moduleTypeId, address indexed module);
    event ModuleInstallCancelled(uint256 indexed moduleTypeId, address indexed module, address cancelledBy);
    event ModuleInstallTimelockChanged(uint256 oldTimelock, uint256 newTimelock);

    function setUp() public {
        ownerWallet  = vm.createWallet("owner");
        g0Wallet     = vm.createWallet("g0");
        g1Wallet     = vm.createWallet("g1");
        g2Wallet     = vm.createWallet("g2");
        randomWallet = vm.createWallet("random");

        ep = new MockEP();
        mod = new TrackingModule();

        account = new AAStarAirAccountV7();
        ext = IModuleTimelock(address(account));
        uint8[] memory algs = new uint8[](0);
        account.initialize(address(ep), ownerWallet.addr, AAStarAirAccountBase.InitConfig({
            guardians: [g0Wallet.addr, g1Wallet.addr, g2Wallet.addr],
            dailyLimit: 0,
            approvedAlgIds: algs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }));
        vm.deal(address(account), 10 ether);
    }

    // ─── Signing helpers ──────────────────────────────────────────────────────

    function _installDigest(uint256 typeId, address module, bytes memory moduleInitData)
        internal view returns (bytes32)
    {
        uint256 nonce = account.moduleManagementNonce();
        bytes32 raw = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "INSTALL_MODULE",
            abi.encode(typeId, module, keccak256(moduleInitData), nonce)
        ));
        return raw.toEthSignedMessageHash();
    }

    function _installSig(Vm.Wallet memory w, uint256 typeId, address module, bytes memory moduleInitData)
        internal view returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, _installDigest(typeId, module, moduleInitData));
        return abi.encodePacked(r, s, v);
    }

    function _timelockDigest(uint256 newTimelock) internal view returns (bytes32) {
        uint256 nonce = account.moduleManagementNonce();
        bytes32 raw = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "SET_MODULE_TIMELOCK",
            abi.encode(newTimelock, nonce)
        ));
        return raw.toEthSignedMessageHash();
    }

    function _timelockSig2(uint256 newTimelock) internal view returns (bytes memory) {
        bytes32 d = _timelockDigest(newTimelock);
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(g0Wallet.privateKey, d);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(g1Wallet.privateKey, d);
        return abi.encodePacked(r0, s0, v0, r1, s1, v1);
    }

    function _enableTimelock(uint256 t) internal {
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(t, "");
    }

    // REMOVE_GUARDIAN sig (mirror AAStarAirAccountBase domain).
    function _removalSig(Vm.Wallet memory w, address guardianToRemove, uint256 nonce)
        internal view returns (bytes memory)
    {
        bytes32 raw = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "REMOVE_GUARDIAN",
            abi.encode(nonce, guardianToRemove)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, raw.toEthSignedMessageHash());
        return abi.encodePacked(r, s, v);
    }

    /// @dev Run a full social-recovery cycle that replaces the owner with `newOwner`.
    ///      RECOVERY_TIMELOCK is 2 days; this advances time accordingly.
    function _runOwnerRecovery(address newOwner) internal {
        vm.prank(g0Wallet.addr);
        account.proposeRecovery(newOwner);       // auto-approve #1
        vm.prank(g1Wallet.addr);
        account.approveRecovery();               // approval #2 → meets 2-of-3
        vm.warp(block.timestamp + 2 days + 1);   // past RECOVERY_TIMELOCK
        account.executeRecovery();               // owner := newOwner
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 1. timelock = 0 → immediate install still works (backward compat)
    // ───────────────────────────────────────────────────────────────────────────

    function test_timelockZero_immediateInstall_backwardCompat() public {
        assertEq(ext.moduleInstallTimelock(), 0);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        account.installModule(VALIDATOR, address(mod), sig);
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
        assertEq(mod.installCount(), 1);
    }

    function test_timelockZero_proposeReverts_disabled() public {
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // ModuleInstallTimelockDisabled
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 2. timelock > 0 → propose → execute-before-expiry reverts; after-expiry works
    // ───────────────────────────────────────────────────────────────────────────

    function test_propose_then_executeAfterExpiry_succeeds() public {
        _enableTimelock(TIMELOCK);

        bytes memory moduleInitData = hex"1234";
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), moduleInitData);
        bytes memory initData = abi.encodePacked(sig, moduleInitData);

        vm.expectEmit(true, true, false, true, address(account));
        emit ModuleInstallProposed(VALIDATOR, address(mod), block.timestamp + TIMELOCK);
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), initData);

        ( , , uint40 proposedAt, uint40 execAfter, bytes32 hash) = ext.pendingModuleInstall();
        assertEq(uint256(proposedAt), block.timestamp);
        assertEq(uint256(execAfter), block.timestamp + TIMELOCK);
        assertEq(hash, keccak256(moduleInitData));
        assertFalse(account.isModuleInstalled(VALIDATOR, address(mod), ""));

        // warp to just past expiry and execute (permissionless caller)
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(randomWallet.addr);
        ext.executeModuleInstall(moduleInitData);

        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
        assertEq(mod.installCount(), 1);
        assertEq(mod.lastInitData(), moduleInitData);
        // proposal cleared
        ( , , uint40 after_, , ) = ext.pendingModuleInstall();
        assertEq(uint256(after_), 0);
    }

    function test_execute_beforeExpiry_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        // one second before expiry
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(); // ModuleInstallTimelockNotExpired
        ext.executeModuleInstall("");

        // exactly at expiry boundary (proposedAt + timelock) succeeds (>=)
        vm.warp(block.timestamp + 1);
        ext.executeModuleInstall("");
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    function test_execute_dataMismatch_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory moduleInitData = hex"aabbcc";
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), moduleInitData);
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), abi.encodePacked(sig, moduleInitData));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(); // ModuleInstallDataMismatch
        ext.executeModuleInstall(hex"deadbeef");
    }

    function test_execute_noProposal_reverts() public {
        _enableTimelock(TIMELOCK);
        vm.expectRevert(); // NoModuleInstallProposal
        ext.executeModuleInstall("");
    }

    function test_execute_onInstallReverts_hardReverts() public {
        RevertingModule bad = new RevertingModule();
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(bad), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(bad), sig);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(); // ModuleInstallCallbackFailed → rolls back install + proposal
        ext.executeModuleInstall("");
        assertFalse(account.isModuleInstalled(VALIDATOR, address(bad), ""));
        // proposal still present (whole call reverted)
        ( , , uint40 proposedAt, , ) = ext.pendingModuleInstall();
        assertGt(uint256(proposedAt), 0);
    }

    function test_propose_whileProposalPending_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        bytes memory sig2 = _installSig(g1Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // ModuleInstallProposalExists
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig2);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 3. owner+2-guardian bypass installs immediately even with timelock>0;
    //    owner+1-guardian does NOT bypass.
    // ───────────────────────────────────────────────────────────────────────────

    function test_bypass_ownerPlus2Guardians_immediateInstall() public {
        _enableTimelock(TIMELOCK);
        bytes memory s0 = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        bytes memory s1 = _installSig(g1Wallet, VALIDATOR, address(mod), "");
        bytes memory sigs = abi.encodePacked(s0, s1);

        vm.prank(ownerWallet.addr);
        account.installModule(VALIDATOR, address(mod), sigs);
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
        assertEq(mod.installCount(), 1);
    }

    function test_bypass_ownerPlus1Guardian_reverts_whenTimelockEnabled() public {
        _enableTimelock(TIMELOCK);
        // only 1 guardian sig → with timelock on, immediate path now requires 2 → InstallModuleUnauthorized
        bytes memory s0 = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // InstallModuleUnauthorized
        account.installModule(VALIDATOR, address(mod), s0);
        assertFalse(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    function test_bypass_twoSameGuardianSigs_reverts() public {
        _enableTimelock(TIMELOCK);
        // two sigs from the SAME guardian must fail the distinct-guardian check
        bytes memory s0 = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        bytes memory sigs = abi.encodePacked(s0, s0);
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // InstallModuleUnauthorized (duplicate guardian)
        account.installModule(VALIDATOR, address(mod), sigs);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 4. cancel during window blocks execution; cancel authorization rules
    // ───────────────────────────────────────────────────────────────────────────

    function test_cancel_byGuardian_blocksExecute() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        // a DIFFERENT (honest) guardian cancels
        vm.expectEmit(true, true, false, true, address(account));
        emit ModuleInstallCancelled(uint8(VALIDATOR), address(mod), g2Wallet.addr);
        vm.prank(g2Wallet.addr);
        ext.cancelModuleInstall();

        ( , , uint40 proposedAt, , ) = ext.pendingModuleInstall();
        assertEq(uint256(proposedAt), 0);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(); // NoModuleInstallProposal
        ext.executeModuleInstall("");
    }

    function test_cancel_byOwner_allowed() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        vm.prank(ownerWallet.addr);
        ext.cancelModuleInstall();
        ( , , uint40 proposedAt, , ) = ext.pendingModuleInstall();
        assertEq(uint256(proposedAt), 0);
    }

    function test_cancel_byRandom_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        vm.prank(randomWallet.addr);
        vm.expectRevert(); // NotGuardian
        ext.cancelModuleInstall();
    }

    function test_cancel_noProposal_reverts() public {
        _enableTimelock(TIMELOCK);
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // NoModuleInstallProposal
        ext.cancelModuleInstall();
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 5. replay: a proposal can't be replayed after execute/cancel (nonce)
    // ───────────────────────────────────────────────────────────────────────────

    function test_replay_sigCannotBeReusedAfterPropose() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig); // consumes nonce

        // cancel, then try to re-propose with the SAME (now stale-nonce) signature
        vm.prank(ownerWallet.addr);
        ext.cancelModuleInstall();

        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // InstallModuleUnauthorized (nonce advanced → sig recovers wrong digest)
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
    }

    function test_nonce_advancesAfterPropose() public {
        _enableTimelock(TIMELOCK);
        uint256 n0 = account.moduleManagementNonce();
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
        assertEq(account.moduleManagementNonce(), n0 + 1);
    }

    function test_executeIsIdempotent_cannotDoubleInstall() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
        vm.warp(block.timestamp + TIMELOCK + 1);
        ext.executeModuleInstall("");

        // second execute has no proposal
        vm.expectRevert(); // NoModuleInstallProposal
        ext.executeModuleInstall("");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 6. adversarial: unauthorized actors can't propose/execute/cancel/shorten window
    // ───────────────────────────────────────────────────────────────────────────

    function test_propose_byNonOwner_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(randomWallet.addr);
        vm.expectRevert(); // NotOwnerOrEntryPoint
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
    }

    function test_propose_withoutGuardianSig_reverts() public {
        _enableTimelock(TIMELOCK);
        // no guardian sig bytes at all
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // InstallModuleUnauthorized
        ext.proposeModuleInstall(VALIDATOR, address(mod), "");
    }

    function test_propose_withForgedGuardianSig_reverts() public {
        _enableTimelock(TIMELOCK);
        // signed by a non-guardian wallet
        bytes memory sig = _installSig(randomWallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // NotGuardian inside _checkGuardianSigs
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
    }

    function test_attacker_cannotShortenWindow_byReducingTimelock() public {
        _enableTimelock(TIMELOCK);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);

        // owner alone tries to reduce the timelock (weakening) without guardian sigs → reverts
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // InstallModuleUnauthorized (weakening needs 2 guardian sigs)
        ext.setModuleInstallTimelock(0, "");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 7. setModuleInstallTimelock authorization (strengthen vs weaken)
    // ───────────────────────────────────────────────────────────────────────────

    function test_setTimelock_strengthen_ownerOnly() public {
        vm.expectEmit(false, false, false, true, address(account));
        emit ModuleInstallTimelockChanged(0, TIMELOCK);
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(TIMELOCK, "");
        assertEq(ext.moduleInstallTimelock(), TIMELOCK);

        // increasing further is also owner-only
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(TIMELOCK * 2, "");
        assertEq(ext.moduleInstallTimelock(), TIMELOCK * 2);
    }

    function test_setTimelock_weaken_requires2Guardians() public {
        _enableTimelock(TIMELOCK);
        // owner-only weaken reverts
        vm.prank(ownerWallet.addr);
        vm.expectRevert();
        ext.setModuleInstallTimelock(1 hours, "");

        // owner + 2 guardian sigs succeeds
        bytes memory sigs = _timelockSig2(1 hours);
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(1 hours, sigs);
        assertEq(ext.moduleInstallTimelock(), 1 hours);
    }

    function test_setTimelock_weaken_byNonOwner_reverts() public {
        _enableTimelock(TIMELOCK);
        bytes memory sigs = _timelockSig2(0);
        vm.prank(randomWallet.addr);
        vm.expectRevert(); // NotOwnerOrEntryPoint
        ext.setModuleInstallTimelock(0, sigs);
    }

    function test_setTimelock_disable_withGuardians_thenImmediateInstallWorks() public {
        _enableTimelock(TIMELOCK);
        bytes memory sigs = _timelockSig2(0);
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(0, sigs);
        assertEq(ext.moduleInstallTimelock(), 0);

        // back to immediate single-guardian install
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        account.installModule(VALIDATOR, address(mod), sig);
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 8. [Medium fix] stale proposal rejected after auth-config change during window
    // ───────────────────────────────────────────────────────────────────────────

    function test_stale_rejectedAfterOwnerRecovery() public {
        _enableTimelock(TIMELOCK); // 2 days
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig); // executeAfter = t0 + 2d

        // Replace the owner via social recovery during the window (recovery also takes 2 days, so by the
        // time it completes the module proposal is mature but its auth snapshot is now stale).
        Vm.Wallet memory newOwner = vm.createWallet("newOwner");
        _runOwnerRecovery(newOwner.addr);
        assertEq(account.owner(), newOwner.addr);

        // Past executeAfter and within grace, but the owner changed → AuthChanged.
        vm.expectRevert(); // ModuleInstallAuthChanged
        ext.executeModuleInstall("");
        assertFalse(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    function test_stale_rejectedAfterSigningGuardianRemoved() public {
        _enableTimelock(1 hours);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig); // executeAfter = t0 + 1h

        // mature the proposal (within grace)
        vm.warp(block.timestamp + 1 hours + 1);

        // Remove the guardian that signed the proposal (index 0 = g0). removeGuardian needs 2 distinct
        // guardian sigs over the REMOVE_GUARDIAN domain at removalNonce 0.
        bytes[] memory rsigs = new bytes[](2);
        rsigs[0] = _removalSig(g1Wallet, g0Wallet.addr, 0);
        rsigs[1] = _removalSig(g2Wallet, g0Wallet.addr, 0);
        vm.prank(ownerWallet.addr);
        account.removeGuardian(0, rsigs);
        assertEq(account.guardianCount(), 2);

        // The guardian set changed → AuthChanged, even though the proposal is otherwise executable.
        vm.expectRevert(); // ModuleInstallAuthChanged
        ext.executeModuleInstall("");
        assertFalse(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 9. [Low fix] raising the timelock after propose does NOT move executeAfter
    // ───────────────────────────────────────────────────────────────────────────

    function test_raisingTimelockAfterPropose_doesNotMoveExecuteAfter() public {
        _enableTimelock(1 days);
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        uint256 t0 = block.timestamp;
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig);
        ( , , , uint40 execAfter0, ) = ext.pendingModuleInstall();
        assertEq(uint256(execAfter0), t0 + 1 days);

        // Strengthen the timelock to 30 days AFTER proposing (owner-only).
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(30 days, "");
        // executeAfter is unchanged — bound at propose time.
        ( , , , uint40 execAfter1, ) = ext.pendingModuleInstall();
        assertEq(uint256(execAfter1), t0 + 1 days);

        // Executable at the ORIGINAL deadline, not the raised one.
        vm.warp(t0 + 1 days);
        ext.executeModuleInstall("");
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 10. [Low fix] setModuleInstallTimelock cap at 30 days
    // ───────────────────────────────────────────────────────────────────────────

    function test_setTimelock_aboveMax_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // ModuleInstallTimelockTooLong
        ext.setModuleInstallTimelock(30 days + 1, "");
    }

    function test_setTimelock_atMax_passes() public {
        vm.prank(ownerWallet.addr);
        ext.setModuleInstallTimelock(30 days, "");
        assertEq(ext.moduleInstallTimelock(), 30 days);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // 11. [Q3] proposal expiry: past grace → execute reverts and it can be re-proposed
    // ───────────────────────────────────────────────────────────────────────────

    function test_proposal_pastExpiry_reverts_andCanRepropose() public {
        _enableTimelock(TIMELOCK); // 2 days
        bytes memory sig = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig); // executeAfter = t0 + 2d, grace +30d

        // Warp past executeAfter + 30-day grace → expired.
        vm.warp(block.timestamp + TIMELOCK + 30 days + 1);
        vm.expectRevert(); // ModuleInstallProposalExpired
        ext.executeModuleInstall("");

        // The expired proposal can be overwritten by a fresh propose (new nonce → new sig).
        uint256 t1 = block.timestamp;
        bytes memory sig2 = _installSig(g0Wallet, VALIDATOR, address(mod), "");
        vm.prank(ownerWallet.addr);
        ext.proposeModuleInstall(VALIDATOR, address(mod), sig2);
        ( , , uint40 proposedAt, uint40 execAfter, ) = ext.pendingModuleInstall();
        assertEq(uint256(proposedAt), t1);
        assertEq(uint256(execAfter), uint256(proposedAt) + TIMELOCK);

        // and the re-proposed one executes normally after its own window
        vm.warp(uint256(execAfter) + 1);
        ext.executeModuleInstall("");
        assertTrue(account.isModuleInstalled(VALIDATOR, address(mod), ""));
    }
}
