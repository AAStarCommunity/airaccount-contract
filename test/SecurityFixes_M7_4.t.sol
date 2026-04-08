// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AirAccountCompositeValidator} from "../src/validators/AirAccountCompositeValidator.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title SecurityFixes_M7_4Test
 * @notice Edge-case and extreme-scenario unit tests for M7.4 security fixes:
 *
 *   H-4: uninstallModule requires onlyOwnerOrEntryPoint
 *   H-5: CompositeValidator uses validateCompositeSignature (not isValidSignature)
 *   H-6: nonce-key routing stores algId so Guard receives correct tier
 *   M-9: parserRegistry.getParser() wrapped in try/catch
 *   M-10: installModule calls onInstall(); uninstallModule calls onUninstall()
 */

// ─── Minimal mock EntryPoint ──────────────────────────────────────────────────

contract MockEP_SF {
    receive() external payable {}
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function withdrawTo(address payable, uint256) external {}
}

// ─── Mock module with onInstall/onUninstall tracking ─────────────────────────

contract TrackingModule {
    mapping(address => bool) public initialized;
    mapping(address => bytes) public lastInitData;
    bool public revertOnInstall;
    bool public revertOnUninstall;
    uint256 public validateResult; // 0 = pass, 1 = fail

    function setRevertOnInstall(bool v) external { revertOnInstall = v; }
    function setRevertOnUninstall(bool v) external { revertOnUninstall = v; }
    function setValidateResult(uint256 v) external { validateResult = v; }

    function onInstall(bytes calldata data) external {
        if (revertOnInstall) revert("onInstall: forced revert");
        initialized[msg.sender] = true;
        lastInitData[msg.sender] = data;
    }

    function onUninstall(bytes calldata) external {
        if (revertOnUninstall) revert("onUninstall: forced revert");
        initialized[msg.sender] = false;
    }

    function isInitialized(address account) external view returns (bool) {
        return initialized[account];
    }

    // ERC-7579 Validator interface
    function validateUserOp(PackedUserOperation calldata, bytes32) external returns (uint256) {
        return validateResult;
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    receive() external payable {}
    fallback() external payable {}
}

// ─── Malicious registry that reverts on getParser() ──────────────────────────

contract RevertingRegistry {
    function getParser(address) external pure returns (address) {
        revert("malicious getParser revert");
    }
}

// ─── Registry that returns an address with no code ───────────────────────────

contract BogusParserRegistry {
    address public bogus;
    constructor() { bogus = address(0xDEAD); } // EOA, no code
    function getParser(address) external view returns (address) { return bogus; }
}

// HandleOpsSim removed — simulation is done via _simHandleOps() in the test contract
// using vm.prank(address(ep)) so msg.sender passes the onlyEntryPoint check.

// ─── Test suite ──────────────────────────────────────────────────────────────

contract SecurityFixes_M7_4Test is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    uint8 constant ALG_ECDSA         = 0x02;
    uint8 constant ALG_CUMULATIVE_T2 = 0x04;
    uint8 constant ALG_CUMULATIVE_T3 = 0x05;
    uint8 constant ALG_WEIGHTED      = 0x07;
    uint8 constant ALG_SESSION_KEY   = 0x08;

    MockEP_SF ep;
    AAStarAirAccountV7 account;
    TrackingModule trackingModule;
    AirAccountCompositeValidator compositeValidator;

    Vm.Wallet ownerWallet;
    Vm.Wallet g0Wallet;
    Vm.Wallet g1Wallet;
    Vm.Wallet g2Wallet;

    address recipient = makeAddr("recipient");

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        g0Wallet    = vm.createWallet("guardian0");
        g1Wallet    = vm.createWallet("guardian1");
        g2Wallet    = vm.createWallet("guardian2");

        ep             = new MockEP_SF();
        trackingModule = new TrackingModule();
        compositeValidator = new AirAccountCompositeValidator();

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;

        account = new AAStarAirAccountV7();
        address guard = address(new AAStarGlobalGuard(
            address(account),
            1 ether,
            algIds,
            0,
            new address[](0),
            new AAStarGlobalGuard.TokenConfig[](0)
        ));

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians:           [g0Wallet.addr, g1Wallet.addr, g2Wallet.addr],
            dailyLimit:          1 ether,
            approvedAlgIds:      algIds,
            minDailyLimit:       0,
            initialTokens:       new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account.initialize(address(ep), ownerWallet.addr, cfg, guard);
        vm.deal(address(account), 10 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Simulate EntryPoint.handleOps: validateUserOp then execute in the same transaction.
    ///      Uses vm.prank(address(ep)) so msg.sender == entryPoint for both calls.
    ///      Transient storage set during validateUserOp persists to execute() within
    ///      the same Foundry test transaction.
    function _simHandleOps(
        PackedUserOperation memory userOp,
        bytes32 userOpHash,
        address dest,
        uint256 value,
        bytes memory data
    ) internal returns (bool execSuccess) {
        vm.prank(address(ep));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        if (validationData != 0) return false;

        vm.prank(address(ep));
        (execSuccess,) = address(account).call(
            abi.encodeWithSignature("execute(address,uint256,bytes)", dest, value, data)
        );
    }

    function _installSig(Vm.Wallet memory wallet, address acc, uint256 moduleTypeId, address module)
        internal view returns (bytes memory)
    {
        return _installSigWithData(wallet, acc, moduleTypeId, module, "");
    }

    function _installSigWithData(Vm.Wallet memory wallet, address acc, uint256 moduleTypeId, address module, bytes memory moduleInitData)
        internal view returns (bytes memory)
    {
        bytes32 hash = keccak256(
            abi.encodePacked("INSTALL_MODULE", block.chainid, acc, moduleTypeId, module, keccak256(moduleInitData))
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, hash);
        return abi.encodePacked(r, s, v);
    }

    function _uninstallSig(Vm.Wallet memory wallet, address acc, uint256 moduleTypeId, address module)
        internal view returns (bytes memory)
    {
        bytes32 hash = keccak256(
            abi.encodePacked("UNINSTALL_MODULE", block.chainid, acc, moduleTypeId, module)
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Install trackingModule as validator with 1 guardian sig (default threshold=70)
    function _installTracking() internal {
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(trackingModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(trackingModule), sig);
    }

    // ─── H-4: uninstallModule access control edge cases ──────────────────────

    /// @notice Guardian cannot bypass access control by calling uninstallModule directly,
    ///         even when providing valid guardian signatures.
    function test_H4_guardian_directCall_reverts_evenWithValidSigs() public {
        _installTracking();

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        // g0 is a guardian, NOT the owner — should be rejected at the access control check
        vm.prank(g0Wallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwnerOrEntryPoint.selector);
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));
    }

    /// @notice Random address cannot call uninstallModule even with valid sigs
    function test_H4_randomAddress_directCall_reverts() public {
        _installTracking();

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AAStarAirAccountBase.NotOwnerOrEntryPoint.selector);
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));
    }

    /// @notice EntryPoint (approved caller) CAN call uninstallModule with valid guardian sigs
    function test_H4_entryPoint_canUninstall_withValidSigs() public {
        _installTracking();
        assertTrue(account.isModuleInstalled(1, address(trackingModule), ""));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        // EntryPoint address calls uninstallModule
        vm.prank(address(ep));
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));

        assertFalse(account.isModuleInstalled(1, address(trackingModule), ""));
    }

    /// @notice Dual-factor: even owner needs valid guardian sigs; owner alone is not enough.
    function test_H4_ownerAlone_noGuardianSig_reverts() public {
        _installTracking();

        // Owner calls but provides no guardian sigs
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        account.uninstallModule(1, address(trackingModule), "");
    }

    // ─── H-5: validateCompositeSignature access control ──────────────────────

    /// @notice validateCompositeSignature reverts if caller is not an installed validator
    function test_H5_validateCompositeSignature_notInstalledValidator_reverts() public {
        // trackingModule not installed yet
        vm.expectRevert(AAStarAirAccountBase.ModuleNotInstalled.selector);
        vm.prank(address(trackingModule));
        account.validateCompositeSignature(bytes32(0), "");
    }

    /// @notice Arbitrary address cannot call validateCompositeSignature
    function test_H5_validateCompositeSignature_arbitraryAddress_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AAStarAirAccountBase.ModuleNotInstalled.selector);
        account.validateCompositeSignature(bytes32(0), "");
    }

    /// @notice Once installed, a validator module CAN call validateCompositeSignature
    function test_H5_validateCompositeSignature_installedValidator_canCall() public {
        _installTracking();

        // trackingModule is now installed as a validator
        // Call validateCompositeSignature AS the trackingModule — should not revert with ModuleNotInstalled
        // (it will return 1 because sig is invalid ECDSA, but that's correct behavior)
        vm.prank(address(trackingModule));
        uint256 result = account.validateCompositeSignature(bytes32(0), "");
        // Empty sig → will fail crypto checks, return 1 (failure), but NOT revert with NotInstalled
        assertEq(result, 1);
    }

    /// @notice CompositeValidator itself cannot call validateCompositeSignature unless installed
    function test_H5_compositeValidator_notInstalled_callsReverts() public {
        // CompositeValidator is NOT installed on account
        // When compositeValidator tries to call validateCompositeSignature it will revert
        // (this would happen inside validateUserOp when account routes to compositeValidator)
        vm.prank(address(compositeValidator));
        vm.expectRevert(AAStarAirAccountBase.ModuleNotInstalled.selector);
        account.validateCompositeSignature(bytes32(0), "");
    }

    /// @notice End-to-end: CompositeValidator installed, validates via account callback
    function test_H5_compositeValidator_installed_delegatesCorrectly() public {
        // Install compositeValidator as a validator
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(compositeValidator));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(compositeValidator), sig);

        // Verify compositeValidator is initialized via onInstall
        assertTrue(compositeValidator.isInitialized(address(account)));

        // CompositeValidator can now call validateCompositeSignature
        // Passing an invalid sig for an invalid algId will return 1 (not a ModuleNotInstalled revert)
        bytes memory badSig = abi.encodePacked(ALG_CUMULATIVE_T2, bytes32(0), bytes32(0));
        vm.prank(address(compositeValidator));
        uint256 result = account.validateCompositeSignature(bytes32(0), badSig);
        // Will return 1 (validation failure for bad cumulative sig) — not revert
        assertEq(result, 1, "bad T2 sig should return 1 (not revert)");
    }

    // ─── H-6: nonce-key routing stores algId for Guard ───────────────────────

    /// @notice Guard is bypassed if algId=0 reaches execute() — this test verifies the fix
    ///         ensures guard gets the correct algId from sig[0], not 0.
    ///
    ///         Setup: guard approves ONLY ALG_ECDSA (0x02). Module path sends sig[0]=0x02.
    ///         With fix: guard gets 0x02 → approve → execute succeeds.
    function test_H6_nonceKeyRouting_storesAlgId_guardReceivesCorrectTier() public {
        // Install trackingModule as validator (returns 0 = success for all sigs)
        _installTracking();

        // Build UserOp: nonce high bits = trackingModule address
        // sig[0] = ALG_ECDSA (0x02) — the guard approves ALG_ECDSA
        bytes memory sig = abi.encodePacked(ALG_ECDSA, bytes32(0), bytes32(0));
        uint192 validatorId = uint192(uint160(address(trackingModule)));
        uint256 nonce = uint256(validatorId) << 64;

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        // Simulate EntryPoint: validateUserOp + execute in same transaction
        bool ok = _simHandleOps(userOp, keccak256("test"), recipient, 0.001 ether, "");
        assertTrue(ok, "execution should succeed: ALG_ECDSA is approved in guard");
    }

    /// @notice Guard rejects if sig[0] is an unapproved algId — verifies algId IS read from sig.
    ///         If algId were stuck at 0 (pre-fix), this test would behave differently.
    function test_H6_nonceKeyRouting_unapprovedAlgId_guardRejects() public {
        _installTracking();

        // sig[0] = ALG_WEIGHTED (0x07) — NOT approved in guard setup (only ECDSA is approved)
        bytes memory sig = abi.encodePacked(ALG_WEIGHTED, bytes32(0), bytes32(0));
        uint192 validatorId = uint192(uint160(address(trackingModule)));

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: uint256(validatorId) << 64,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        // Guard should reject ALG_WEIGHTED since it's not in approvedAlgIds
        bool ok = _simHandleOps(userOp, keccak256("test2"), recipient, 0.001 ether, "");
        assertFalse(ok, "execution should fail: ALG_WEIGHTED not approved in guard");
    }

    /// @notice Validation failure: module returns 1 → algId NOT stored → execute is never called.
    function test_H6_moduleValidationFail_algIdNotStored_executeNotCalled() public {
        _installTracking();
        trackingModule.setValidateResult(1); // module rejects all

        bytes memory sig = abi.encodePacked(ALG_ECDSA, bytes32(0));
        uint192 validatorId = uint192(uint160(address(trackingModule)));

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: uint256(validatorId) << 64,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        // _simHandleOps checks validationData and returns false without calling execute
        bool ok = _simHandleOps(userOp, keccak256("test3"), recipient, 0.001 ether, "");
        assertFalse(ok, "validation failed, execute never called, returns false");
    }

    /// @notice Batch simulation: two UserOps in same tx, each gets the correct algId.
    ///         First op uses trackingModule (algId=ALG_ECDSA), second uses direct ECDSA path.
    ///         Tests that the transient storage queue is not corrupted.
    function test_H6_batchConsistency_twoModuleOps_correctAlgIds() public {
        _installTracking();

        // Two independent simulate calls — each UserOp is independent in Foundry tests.
        // Both should succeed.

        // UserOp 1: module path with ALG_ECDSA
        bytes memory sig1 = abi.encodePacked(ALG_ECDSA, bytes32(0));
        uint192 validatorId = uint192(uint160(address(trackingModule)));
        PackedUserOperation memory op1 = PackedUserOperation({
            sender: address(account),
            nonce: uint256(validatorId) << 64,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig1
        });

        bool ok1 = _simHandleOps(op1, keccak256("op1"), recipient, 0 ether, "");
        assertTrue(ok1, "op1 (module + ALG_ECDSA) should succeed");

        // UserOp 2: direct path (nonce-key=0), owner signs with explicit ECDSA prefix
        // Build valid ECDSA sig for direct path
        bytes32 directHash = keccak256("op2").toEthSignedMessageHash();
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(ownerWallet, directHash);
        bytes memory sig2 = abi.encodePacked(ALG_ECDSA, r2, s2, v2); // 66 bytes

        PackedUserOperation memory op2 = PackedUserOperation({
            sender: address(account),
            nonce: 0, // direct path
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig2
        });
        bool ok2 = _simHandleOps(op2, keccak256("op2"), recipient, 0 ether, "");
        assertTrue(ok2, "op2 (direct ECDSA path) should succeed");
    }

    // ─── M-9: parserRegistry.getParser() try/catch ───────────────────────────

    /// @notice A registry whose getParser() reverts must NOT block execute()
    function test_M9_revertingRegistry_getParser_doesNotBlockExecute() public {
        RevertingRegistry badRegistry = new RevertingRegistry();
        vm.prank(ownerWallet.addr);
        account.setParserRegistry(address(badRegistry));

        // Build ECDSA UserOp
        bytes32 hash = keccak256("tx").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet, hash);
        bytes memory sig = abi.encodePacked(ALG_ECDSA, r, s, v); // 66 bytes

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        // execute() should still work despite registry reverting on getParser
        bool ok = _simHandleOps(userOp, keccak256("tx"), recipient, 0.001 ether, "");
        assertTrue(ok, "reverting getParser() must not block execute()");
    }

    /// @notice Registry returning an address with no code for the parser must not block execute()
    function test_M9_bogusParserAddress_doesNotBlockExecute() public {
        BogusParserRegistry bogusReg = new BogusParserRegistry();
        vm.prank(ownerWallet.addr);
        account.setParserRegistry(address(bogusReg));

        bytes32 hash = keccak256("tx2").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet, hash);
        bytes memory sig = abi.encodePacked(ALG_ECDSA, r, s, v);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        bool ok = _simHandleOps(userOp, keccak256("tx2"), recipient, 0.001 ether, "");
        assertTrue(ok, "bogus parser address must not block execute()");
    }

    /// @notice Direct execute() (owner path) also works with reverting registry
    function test_M9_revertingRegistry_ownerDirectCall_succeeds() public {
        RevertingRegistry badRegistry = new RevertingRegistry();
        vm.prank(ownerWallet.addr);
        account.setParserRegistry(address(badRegistry));

        // Direct owner call to execute — should not revert despite bad registry
        vm.prank(ownerWallet.addr);
        account.execute(recipient, 0.001 ether, "");
        assertEq(recipient.balance, 0.001 ether);
    }

    // ─── M-10: onInstall / onUninstall called correctly ──────────────────────

    /// @notice After installModule, onInstall is called → module is initialized
    function test_M10_installModule_callsOnInstall() public {
        assertFalse(trackingModule.isInitialized(address(account)));

        _installTracking();

        assertTrue(
            trackingModule.isInitialized(address(account)),
            "onInstall must be called, module must be initialized after install"
        );
    }

    /// @notice Bytes after guardian sigs are passed as actual initData to onInstall.
    ///         HIGH-2 fix: installModule now extracts sigsRequired*65 bytes as guardian sigs,
    ///         then passes the remainder to onInstall(bytes).
    function test_M10_installModule_passesInitDataToOnInstall() public {
        bytes memory extraData = abi.encodePacked("extra-init-data-for-module");
        // v3-MEDIUM fix: guardian sig must bind keccak256(moduleInitData)
        bytes memory guardianSig = _installSigWithData(g0Wallet, address(account), 1, address(trackingModule), extraData);
        bytes memory fullInitData = abi.encodePacked(guardianSig, extraData);

        vm.prank(ownerWallet.addr);
        account.installModule(1, address(trackingModule), fullInitData);

        // After HIGH-2 fix: onInstall is called with actual initData (bytes after guardian sig)
        assertTrue(
            trackingModule.isInitialized(address(account)),
            "module must be initialized after install (onInstall called)"
        );
        assertEq(
            trackingModule.lastInitData(address(account)),
            extraData,
            "actual initData (beyond guardian sig) must be passed to onInstall"
        );
    }

    /// @notice If onInstall reverts, installModule hard-reverts and module is NOT registered
    function test_M10_installModule_revertingOnInstall_reverts() public {
        trackingModule.setRevertOnInstall(true);

        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(trackingModule));
        vm.prank(ownerWallet.addr);
        // Hard-revert: onInstall failure rolls back the entire install
        vm.expectRevert(
            abi.encodeWithSelector(
                AAStarAirAccountBase.ModuleInstallCallbackFailed.selector,
                uint256(1),
                address(trackingModule)
            )
        );
        account.installModule(1, address(trackingModule), sig);
        assertFalse(account.isModuleInstalled(1, address(trackingModule), ""));
    }

    /// @notice After uninstallModule, onUninstall is called → module is de-initialized
    function test_M10_uninstallModule_callsOnUninstall() public {
        _installTracking();
        assertTrue(trackingModule.isInitialized(address(account)));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));

        assertFalse(
            trackingModule.isInitialized(address(account)),
            "onUninstall must be called, module must be de-initialized after uninstall"
        );
    }

    /// @notice If onUninstall reverts, uninstallModule still succeeds (best-effort)
    function test_M10_uninstallModule_revertingOnUninstall_stillUninstalls() public {
        _installTracking();
        trackingModule.setRevertOnUninstall(true);

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        // Should NOT revert even though onUninstall reverts
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));

        // Module MUST be removed from registry regardless of onUninstall outcome
        assertFalse(
            account.isModuleInstalled(1, address(trackingModule), ""),
            "module must be unregistered even if onUninstall reverted"
        );
    }

    /// @notice After revert on onUninstall, the module can be re-installed (state is cleared in registry)
    function test_M10_afterRevertingUninstall_moduleCanBeReinstalled() public {
        _installTracking();
        trackingModule.setRevertOnUninstall(true);

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(trackingModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(trackingModule));

        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(trackingModule), abi.encodePacked(sig0, sig1));

        // Fix the revert flag and reinstall
        trackingModule.setRevertOnUninstall(false);
        bytes memory sigRe = _installSig(g0Wallet, address(account), 1, address(trackingModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(trackingModule), sigRe);

        assertTrue(account.isModuleInstalled(1, address(trackingModule), ""));
    }

    /// @notice Multiple modules can be installed independently; each gets onInstall called.
    ///         Best-effort: onInstall is called with empty data (initData beyond guardian sigs is ignored).
    function test_M10_multipleModules_eachGetCorrectInitData() public {
        // Deploy a second tracking module
        TrackingModule trackingModule2 = new TrackingModule();

        // v3-MEDIUM fix: sigs bind their respective moduleInitData
        bytes memory extra1 = bytes("data-for-module1");
        bytes memory extra2 = bytes("data-for-module2");
        bytes memory sig1 = _installSigWithData(g0Wallet, address(account), 2, address(trackingModule), extra1);
        bytes memory sig2 = _installSigWithData(g0Wallet, address(account), 3, address(trackingModule2), extra2);
        bytes memory initData1 = abi.encodePacked(sig1, extra1);
        bytes memory initData2 = abi.encodePacked(sig2, extra2);

        vm.prank(ownerWallet.addr);
        account.installModule(2, address(trackingModule), initData1);
        vm.prank(ownerWallet.addr);
        account.installModule(3, address(trackingModule2), initData2);

        // After HIGH-2 fix: onInstall receives actual initData (bytes after guardian sigs)
        assertTrue(trackingModule.isInitialized(address(account)),  "module1 must be initialized");
        assertTrue(trackingModule2.isInitialized(address(account)), "module2 must be initialized");
        assertEq(trackingModule.lastInitData(address(account)),  bytes("data-for-module1"), "module1 initData");
        assertEq(trackingModule2.lastInitData(address(account)), bytes("data-for-module2"), "module2 initData");
    }

    // ─── Combined: install + validate + execute flow ──────────────────────────

    /// @notice Full flow: install module → validate via module (nonce-key) → guard accepts → execute succeeds
    function test_combined_installModule_nonceKeyRoute_guardAccepts_executeSucceeds() public {
        // Install trackingModule
        _installTracking();

        // Send UserOp via nonce-key routing with ALG_ECDSA sig prefix (guard approves ECDSA)
        bytes memory sig = abi.encodePacked(ALG_ECDSA, bytes32(0), bytes32(0));
        uint192 validatorId = uint192(uint160(address(trackingModule)));

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: uint256(validatorId) << 64,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        uint256 balBefore = recipient.balance;
        bool ok = _simHandleOps(userOp, keccak256("combined"), recipient, 0.1 ether, "");
        assertTrue(ok, "full flow should succeed");
        assertEq(recipient.balance - balBefore, 0.1 ether, "ETH transferred correctly");
    }

    /// @notice Extreme case: module installed with no initData — onInstall called with empty bytes
    function test_combined_installModule_emptyInitData_onInstallCalledWithEmpty() public {
        // With default threshold=70, exactly 65 bytes of guardian sig needed.
        // No extra bytes → onInstall called with empty bytes ""
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(trackingModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(trackingModule), sig); // exactly 65 bytes, no extra

        assertTrue(trackingModule.isInitialized(address(account)));
        assertEq(trackingModule.lastInitData(address(account)), bytes(""), "empty initData passed to onInstall");
    }
}
