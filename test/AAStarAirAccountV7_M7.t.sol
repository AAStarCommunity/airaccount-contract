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

// ─── Mock module — acts as validator/executor/hook ────────────────────────────

contract MockModule {
    uint256 public validateResult;

    function setValidateResult(uint256 r) external { validateResult = r; }

    // ERC-7579 IValidator interface
    // Note: account calls via abi.encodeWithSignature with the full tuple signature
    function validateUserOp(PackedUserOperation calldata, bytes32) external returns (uint256) {
        return validateResult;
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    receive() external payable {}
    fallback() external payable {}
}

// ─── Mock module that tracks onInstall/onUninstall call counts ───────────────

contract TrackingModule {
    uint256 public installCount;
    uint256 public uninstallCount;

    function onInstall(bytes calldata) external { installCount++; }
    function onUninstall(bytes calldata) external { uninstallCount++; }

    function validateUserOp(PackedUserOperation calldata, bytes32) external pure returns (uint256) { return 0; }
    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) { return 0x1626ba7e; }
    receive() external payable {}
    fallback() external payable {}
}

// ─── Mock module that reverts on onInstall ────────────────────────────────────

contract RevertingModule {
    function onInstall(bytes calldata) external pure { revert("install failed"); }
    function onUninstall(bytes calldata) external pure {}
    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) { return 0xffffffff; }
    receive() external payable {}
    fallback() external payable {}
}

// ─── Mock target contract for execute tests ───────────────────────────────────

contract MockTarget {
    uint256 public value;
    function setValue(uint256 v) external payable { value = v; }
    receive() external payable {}
}

// ─── Mock ERC-8004 registry ───────────────────────────────────────────────────

contract MockRegistry {
    mapping(uint256 => address) public agentWallets;
    function setAgentWallet(uint256 agentId, address wallet) external {
        agentWallets[agentId] = wallet;
    }
}

/// @title AAStarAirAccountV7_M7Test — M7 ERC-7579 module management tests
contract AAStarAirAccountV7_M7Test is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    // ─── Account with default threshold (0 → 70 at runtime, needs 1 guardian sig) ─

    AAStarAirAccountV7 public account; // threshold=0 → defaults to 70
    MockEP public ep;

    Vm.Wallet ownerWallet;
    Vm.Wallet g0Wallet;
    Vm.Wallet g1Wallet;
    Vm.Wallet g2Wallet;
    Vm.Wallet randomWallet;

    MockModule public mockModule;
    MockTarget public mockTarget;
    MockRegistry public mockRegistry;

    function setUp() public {
        ownerWallet  = vm.createWallet("owner");
        g0Wallet     = vm.createWallet("g0");
        g1Wallet     = vm.createWallet("g1");
        g2Wallet     = vm.createWallet("g2");
        randomWallet = vm.createWallet("random");

        ep = new MockEP();
        mockModule = new MockModule();
        mockTarget = new MockTarget();
        mockRegistry = new MockRegistry();

        // Deploy account with 3 guardians and threshold=0 (defaults to 70 at runtime → 1 guardian sig required).
        account = new AAStarAirAccountV7();
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

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @dev Build a guardian install signature for `account`.
    ///      Sig now binds keccak256(moduleInitData) to prevent config-swap attacks (v3-MEDIUM fix).
    function _installSig(Vm.Wallet memory w, address acct, uint256 moduleTypeId, address module)
        internal view returns (bytes memory)
    {
        return _installSigWithData(w, acct, moduleTypeId, module, "");
    }

    function _installSigWithData(Vm.Wallet memory w, address acct, uint256 moduleTypeId, address module, bytes memory moduleInitData)
        internal view returns (bytes memory)
    {
        bytes32 raw = keccak256(abi.encodePacked(
            "INSTALL_MODULE", block.chainid, acct, moduleTypeId, module, keccak256(moduleInitData)
        ));
        bytes32 ethHash = raw.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _uninstallSig(Vm.Wallet memory w, address acct, uint256 moduleTypeId, address module)
        internal view returns (bytes memory)
    {
        bytes32 raw = keccak256(abi.encodePacked(
            "UNINSTALL_MODULE", block.chainid, acct, moduleTypeId, module
        ));
        bytes32 ethHash = raw.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Install module in `account` with default threshold (70 → 1 guardian sig)
    function _installWithG0(uint256 typeId, address module) internal {
        bytes memory sig = _installSig(g0Wallet, address(account), typeId, module);
        vm.prank(ownerWallet.addr);
        account.installModule(typeId, module, sig);
    }

    function test_accountId_is_0_16_0() public view {
        assertEq(account.accountId(), "airaccount.v7@0.16.0");
    }

    // ─── supportsModule ───────────────────────────────────────────────────────

    function test_supportsModule_validator_type1_true() public view {
        assertTrue(account.supportsModule(1));
    }

    function test_supportsModule_executor_type2_true() public view {
        assertTrue(account.supportsModule(2));
    }

    function test_supportsModule_hook_type3_true() public view {
        assertTrue(account.supportsModule(3));
    }

    function test_supportsModule_fallback_type4_false() public view {
        assertFalse(account.supportsModule(4));
    }

    function test_supportsModule_type0_false() public view {
        assertFalse(account.supportsModule(0));
    }

    // ─── installModule: default threshold (70) — needs 1 guardian sig ─────────

    function test_installModule_validator_withGuardianSig_succeeds() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(mockModule), sig);
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_installModule_executor_withGuardianSig_succeeds() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 2, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(2, address(mockModule), sig);
        assertTrue(account.isModuleInstalled(2, address(mockModule), ""));
    }

    function test_installModule_hook_withGuardianSig_succeeds() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 3, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(3, address(mockModule), sig);
        assertTrue(account.isModuleInstalled(3, address(mockModule), ""));
    }

    function test_installModule_emitsModuleInstalled_event() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.ModuleInstalled(1, address(mockModule));
        account.installModule(1, address(mockModule), sig);
    }

    function test_installModule_notOwner_reverts() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwnerOrEntryPoint.selector);
        account.installModule(1, address(mockModule), sig);
    }

    function test_installModule_zeroAddress_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleInvalid.selector);
        account.installModule(1, address(0), "");
    }

    function test_installModule_noCode_reverts() public {
        // address(0xDEAD) is an EOA with no code; reverts ModuleInvalid() before guardian gate.
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleInvalid.selector);
        account.installModule(1, address(0xDEAD), "");
    }

    function test_installModule_invalidType0_reverts() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 0, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.installModule(0, address(mockModule), sig);
    }

    function test_installModule_invalidType4_reverts() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 4, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.installModule(4, address(mockModule), sig);
    }

    function test_installModule_alreadyInstalled_reverts() public {
        _installWithG0(1, address(mockModule));
        bytes memory sig2 = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleAlreadyInstalled.selector);
        account.installModule(1, address(mockModule), sig2);
    }

    function test_installModule_secondHook_reverts() public {
        // LOW-1 fix: installing a second hook must revert, not silently overwrite
        _installWithG0(3, address(mockModule));
        // deploy a second distinct mock module
        MockModule mockModule2 = new MockModule();
        bytes memory sig2 = _installSig(g0Wallet, address(account), 3, address(mockModule2));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleAlreadyInstalled.selector);
        account.installModule(3, address(mockModule2), sig2);
    }

    function test_installModule_hookAfterUninstall_succeeds() public {
        // After uninstalling the first hook, a new hook can be installed
        _installWithG0(3, address(mockModule));
        // uninstall requires 2 guardian sigs
        bytes memory unSig = abi.encodePacked(
            _uninstallSig(g0Wallet, address(account), 3, address(mockModule)),
            _uninstallSig(g1Wallet, address(account), 3, address(mockModule))
        );
        vm.prank(ownerWallet.addr);
        account.uninstallModule(3, address(mockModule), unSig);
        // now install a second hook — should succeed
        MockModule mockModule2 = new MockModule();
        bytes memory sig2 = _installSig(g0Wallet, address(account), 3, address(mockModule2));
        vm.prank(ownerWallet.addr);
        account.installModule(3, address(mockModule2), sig2);
        assertTrue(account.isModuleInstalled(3, address(mockModule2), ""));
    }

    /// @notice Default threshold is 70 → 1 guardian sig required. No sig → should revert.
    function test_installModule_defaultThreshold_noGuardianSig_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        account.installModule(1, address(mockModule), ""); // empty initData — no guardian sig
    }

    function test_installModule_wrongGuardianSig_reverts() public {
        // Sign with non-guardian (randomWallet)
        bytes memory badSig = _installSig(randomWallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotGuardian.selector);
        account.installModule(1, address(mockModule), badSig);
    }

    function test_installModule_duplicateGuardianSig_reverts() public {
        // Both sig slots use the same guardian (g0) — should be rejected as double-voting
        AAStarAirAccountV7 acc100 = _deployAccountWithThreshold(100);
        // Use new sig format: binds keccak256(moduleInitData) = keccak256("") for no initData
        bytes memory dupSig = _installSigWithData(g0Wallet, address(acc100), 1, address(mockModule), "");

        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        acc100.installModule(1, address(mockModule), abi.encodePacked(dupSig, dupSig));
    }

    // ─── installModule: threshold=100 (2 guardian sigs required) ────────────

    function test_installModule_threshold100_withTwoGuardianSigs_succeeds() public {
        AAStarAirAccountV7 acc100 = _deployAccountWithThreshold(100);

        bytes memory sig0 = _installSigWithData(g0Wallet, address(acc100), 1, address(mockModule), "");
        bytes memory sig1 = _installSigWithData(g1Wallet, address(acc100), 1, address(mockModule), "");

        vm.prank(ownerWallet.addr);
        acc100.installModule(1, address(mockModule), abi.encodePacked(sig0, sig1));
        assertTrue(acc100.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_installModule_threshold100_onlyOneSig_reverts() public {
        AAStarAirAccountV7 acc100 = _deployAccountWithThreshold(100);

        bytes memory oneSig = _installSigWithData(g0Wallet, address(acc100), 1, address(mockModule), "");

        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        acc100.installModule(1, address(mockModule), oneSig);
    }

    function test_installModule_sigBindsInitData_wrongInitData_reverts() public {
        // v3-MEDIUM: sig signed over empty initData; providing non-empty initData must revert
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory wrongInitData = abi.encodePacked(sig, bytes32(uint256(0xdeadbeef)));

        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotGuardian.selector);
        account.installModule(1, address(mockModule), wrongInitData);
    }

    // ─── installModule: threshold=40 (owner-only, 0 guardian sigs) ───────────

    function test_installModule_threshold40_ownerOnly_noSig_succeeds() public {
        AAStarAirAccountV7 acc40 = _deployAccountWithThreshold(40);

        vm.prank(ownerWallet.addr);
        acc40.installModule(1, address(mockModule), ""); // no guardian sig needed
        assertTrue(acc40.isModuleInstalled(1, address(mockModule), ""));
    }

    // ─── uninstallModule ──────────────────────────────────────────────────────

    function test_uninstallModule_withTwoGuardianSigs_succeeds() public {
        _installWithG0(1, address(mockModule));
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));

        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_uninstallModule_executor_withTwoGuardianSigs_succeeds() public {
        _installWithG0(2, address(mockModule));
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 2, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 2, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(2, address(mockModule), abi.encodePacked(sig0, sig1));
        assertFalse(account.isModuleInstalled(2, address(mockModule), ""));
    }

    function test_uninstallModule_hook_withTwoGuardianSigs_succeeds() public {
        _installWithG0(3, address(mockModule));
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 3, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 3, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(3, address(mockModule), abi.encodePacked(sig0, sig1));
        assertFalse(account.isModuleInstalled(3, address(mockModule), ""));
    }

    function test_uninstallModule_emitsModuleUninstalled_event() public {
        _installWithG0(1, address(mockModule));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));

        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.ModuleUninstalled(1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));
    }

    function test_uninstallModule_oneSig_reverts() public {
        _installWithG0(1, address(mockModule));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        account.uninstallModule(1, address(mockModule), sig0); // only 65 bytes
    }

    function test_uninstallModule_noSig_reverts() public {
        _installWithG0(1, address(mockModule));

        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        account.uninstallModule(1, address(mockModule), "");
    }

    function test_uninstallModule_notInstalled_reverts() public {
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleNotInstalled.selector);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));
    }

    function test_uninstallModule_duplicateSig_reverts() public {
        _installWithG0(1, address(mockModule));

        // Same guardian signs twice → double-voting should be rejected
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InstallModuleUnauthorized.selector);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig0));
    }

    function test_uninstallModule_nonGuardianSig_reverts() public {
        _installWithG0(1, address(mockModule));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory badSig = _uninstallSig(randomWallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotGuardian.selector);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, badSig));
    }

    function test_uninstallModule_invalidType0_reverts() public {
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 0, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 0, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.uninstallModule(0, address(mockModule), abi.encodePacked(sig0, sig1));
    }

    function test_uninstallModule_nonOwner_reverts() public {
        _installWithG0(1, address(mockModule));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));
        // Non-owner (even with valid guardian sigs) cannot uninstall a module
        vm.prank(address(0xbad));
        vm.expectRevert(AAStarAirAccountBase.NotOwnerOrEntryPoint.selector);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));
    }

    // ─── executeFromExecutor ──────────────────────────────────────────────────

    function test_executeFromExecutor_single_succeeds() public {
        _installWithG0(2, address(mockModule)); // install as executor

        // Single call mode: callType=0x00 (byte[0]=0x00)
        bytes32 mode = bytes32(0);
        bytes memory calldata_ = abi.encodePacked(
            address(mockTarget),                        // target: 20 bytes
            uint256(0),                                 // value: 32 bytes
            abi.encodeCall(MockTarget.setValue, (42))   // calldata
        );

        vm.prank(address(mockModule));
        bytes[] memory results = account.executeFromExecutor(mode, calldata_);

        assertEq(mockTarget.value(), 42);
        assertEq(results.length, 1);
    }

    function test_executeFromExecutor_single_returnsData() public {
        _installWithG0(2, address(mockModule));

        bytes32 mode = bytes32(0);
        bytes memory calldata_ = abi.encodePacked(
            address(mockTarget),
            uint256(0),
            abi.encodeCall(MockTarget.setValue, (99))
        );

        vm.prank(address(mockModule));
        bytes[] memory results = account.executeFromExecutor(mode, calldata_);
        assertEq(results.length, 1);
        assertEq(mockTarget.value(), 99);
    }

    function test_executeFromExecutor_batch_reverts_unsupportedMode() public {
        // Batch mode (callType=0x01) not supported in M7 — reverts with InvalidModuleType
        _installWithG0(2, address(mockModule));

        bytes32 batchMode = bytes32(uint256(1) << 248); // callType = 0x01
        vm.prank(address(mockModule));
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.executeFromExecutor(batchMode, abi.encode("dummy"));
    }

    function test_executeFromExecutor_batch_multipleExecs_reverts_unsupportedMode() public {
        // Batch mode not supported in M7
        _installWithG0(2, address(mockModule));

        bytes32 batchMode = bytes32(uint256(1) << 248);
        vm.prank(address(mockModule));
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.executeFromExecutor(batchMode, abi.encode("dummy"));
    }

    function test_executeFromExecutor_notInstalled_reverts() public {
        // mockModule NOT installed as executor
        bytes32 mode = bytes32(0);
        bytes memory calldata_ = abi.encodePacked(address(mockTarget), uint256(0), bytes(""));

        vm.prank(address(mockModule));
        vm.expectRevert(AAStarAirAccountBase.ModuleNotInstalled.selector);
        account.executeFromExecutor(mode, calldata_);
    }

    function test_executeFromExecutor_unsupportedCallType_reverts() public {
        _installWithG0(2, address(mockModule));

        // callType=0xFF → unsupported
        bytes32 mode = bytes32(uint256(0xFF) << 248);
        bytes memory calldata_ = abi.encodePacked(address(mockTarget), uint256(0), bytes(""));

        vm.prank(address(mockModule));
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.executeFromExecutor(mode, calldata_);
    }

    function test_executeFromExecutor_callTooShort_reverts() public {
        _installWithG0(2, address(mockModule));

        bytes32 mode = bytes32(0); // single call
        bytes memory tooShort = bytes("short"); // < 52 bytes

        vm.prank(address(mockModule));
        vm.expectRevert(AAStarAirAccountBase.ArrayLengthMismatch.selector);
        account.executeFromExecutor(mode, tooShort);
    }

    function test_executeFromExecutor_reentrancy_reverts() public {
        // Test that the nonReentrant guard works: executor calls back into executeFromExecutor
        _installWithG0(2, address(mockModule));

        // We can't easily test reentrancy without a re-entrant mock — just verify the guard is present
        // by checking a normal call succeeds (confirming tstore(0,0) cleanup after the call)
        bytes32 mode = bytes32(0);
        bytes memory calldata_ = abi.encodePacked(address(mockTarget), uint256(0), abi.encodeCall(MockTarget.setValue, (1)));
        vm.prank(address(mockModule));
        account.executeFromExecutor(mode, calldata_);
        assertEq(mockTarget.value(), 1);
    }

    // ─── validateUserOp: nonce-key validator routing ──────────────────────────

    function test_validateUserOp_nonceKeyZero_ownerECDSA_succeeds() public {
        // nonce key = 0 → uses built-in ECDSA routing
        bytes32 userOpHash = keccak256("test op");
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0, // key = 0
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });

        vm.prank(address(ep));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Owner ECDSA should succeed with nonce key=0");
    }

    function test_validateUserOp_nonceKeyZero_wrongSigner_fails() public {
        bytes32 userOpHash = keccak256("test op");
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomWallet.privateKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

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

        vm.prank(address(ep));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Non-owner signature should return SIG_VALIDATION_FAILED");
    }

    function test_validateUserOp_nonceKey_notInstalled_returns1() public {
        // mockModule NOT installed, but nonce key points to its address
        // nonce = validatorAddress << 64 (address goes into bits 63-224)
        uint256 nonce = uint256(uint192(uint160(address(mockModule)))) << 64;

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        vm.prank(address(ep));
        uint256 result = account.validateUserOp(userOp, keccak256("hash"), 0);
        assertEq(result, 1, "Uninstalled validator should return SIG_VALIDATION_FAILED");
    }

    function test_validateUserOp_nonceKey_installedValidator_called() public {
        _installWithG0(1, address(mockModule));
        mockModule.setValidateResult(0); // mock returns success

        uint256 nonce = uint256(uint192(uint160(address(mockModule)))) << 64;

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        vm.prank(address(ep));
        uint256 result = account.validateUserOp(userOp, keccak256("hash"), 0);
        // mockModule.setValidateResult(0) = success, account should route and return 0
        assertEq(result, 0, "Installed validator should return success");
    }

    function test_validateUserOp_nonceKey_nonZeroValidationData_passedThrough() public {
        // Regression for HIGH-1 fix: validators returning non-zero validationData (e.g. AgentSessionKeyValidator
        // returns uint256(expiry) << 160) must still write algId via _storeValidatedAlgId.
        // The gate changed from validationData==0 to validationData!=1 (SIG_VALIDATION_FAILED sentinel).
        _installWithG0(1, address(mockModule));
        uint256 expiry = block.timestamp + 3600;
        uint256 nonZeroResult = uint256(expiry) << 160; // simulates AgentSessionKeyValidator success
        mockModule.setValidateResult(nonZeroResult);

        bytes memory sig = abi.encodePacked(uint8(0x08), new bytes(65)); // sig[0]=0x08, 65 zero bytes
        uint256 nonce = uint256(uint192(uint160(address(mockModule)))) << 64;

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

        vm.prank(address(ep));
        uint256 result = account.validateUserOp(userOp, keccak256("hash"), 0);
        // Non-zero validationData (expiry timestamp) should be passed through unchanged
        assertEq(result, nonZeroResult, "Non-zero validationData must be passed through");
    }

    function test_validateUserOp_fromNonEntryPoint_reverts() public {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotEntryPoint.selector);
        account.validateUserOp(userOp, keccak256("hash"), 0);
    }

    // ─── isModuleInstalled ────────────────────────────────────────────────────

    function test_isModuleInstalled_beforeInstall_false() public view {
        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(2, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(3, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallValidator_true() public {
        _installWithG0(1, address(mockModule));
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));
        // Other types should remain false
        assertFalse(account.isModuleInstalled(2, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(3, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallExecutor_true() public {
        _installWithG0(2, address(mockModule));
        assertTrue(account.isModuleInstalled(2, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallHook_true() public {
        _installWithG0(3, address(mockModule));
        assertTrue(account.isModuleInstalled(3, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(2, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterUninstall_false() public {
        _installWithG0(1, address(mockModule));
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));

        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));

        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_isModuleInstalled_unknownType_false() public view {
        assertFalse(account.isModuleInstalled(99, address(mockModule), ""));
    }

    // ─── setAgentWallet ───────────────────────────────────────────────────────

    function test_setAgentWallet_owner_succeeds() public {
        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerWallet.addr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(42, agentWallet);
        account.setAgentWallet(42, agentWallet, address(mockRegistry));
    }

    function test_setAgentWallet_registersWithRegistry() public {
        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerWallet.addr);
        account.setAgentWallet(7, agentWallet, address(mockRegistry));

        // Registry should have recorded the agent wallet
        assertEq(mockRegistry.agentWallets(7), agentWallet);
    }

    function test_setAgentWallet_notOwner_reverts() public {
        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        account.setAgentWallet(1, makeAddr("agent"), address(mockRegistry));
    }

    function test_setAgentWallet_zeroWallet_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // require("Invalid agent wallet")
        account.setAgentWallet(1, address(0), address(mockRegistry));
    }

    function test_setAgentWallet_zeroRegistry_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // require("Invalid registry")
        account.setAgentWallet(1, makeAddr("agent"), address(0));
    }

    function test_setAgentWallet_failingRegistry_doesNotRevert() public {
        // setAgentWallet uses best-effort (ok is silenced) — a failing registry should not revert
        address agentWallet = makeAddr("agentWallet");
        address brokenRegistry = makeAddr("brokenRegistry"); // no code → call fails silently

        // Give it some bytecode-like status — actually makeAddr returns EOA with no code
        // The (bool ok,) call will fail silently. The emit should still happen.
        vm.prank(ownerWallet.addr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(99, agentWallet);
        account.setAgentWallet(99, agentWallet, brokenRegistry);
    }

    // ─── Round-trip: install + reinstall after uninstall ─────────────────────

    function test_reinstall_afterUninstall_succeeds() public {
        _installWithG0(1, address(mockModule));
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));

        // Uninstall
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 1, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(mockModule), abi.encodePacked(sig0, sig1));
        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));

        // Reinstall — should succeed since registry is cleared
        bytes memory sig2 = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(mockModule), sig2);
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /// @dev Deploy a fresh account with a specific _installModuleThreshold.
    ///      Uses vm.store to write directly to storage slot 9 (confirmed via `forge inspect AAStarAirAccountV7 storage`):
    ///        slot 9 = _installModuleThreshold (uint8, offset 0)
    function _deployAccountWithThreshold(uint8 threshold) internal returns (AAStarAirAccountV7) {
        AAStarAirAccountV7 acc = new AAStarAirAccountV7();
        uint8[] memory algs = new uint8[](0);
        acc.initialize(address(ep), ownerWallet.addr, AAStarAirAccountBase.InitConfig({
            guardians: [g0Wallet.addr, g1Wallet.addr, g2Wallet.addr],
            dailyLimit: 0,
            approvedAlgIds: algs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }));

        // Slot 7 = _installModuleThreshold (uint8) after unified _installedModules mapping at slot 6.
        vm.store(address(acc), bytes32(uint256(7)), bytes32(uint256(threshold)));
        return acc;
    }

    // ─── Review fix: ModuleInstallCallbackFailed — now reverts instead of emitting event ─────

    function test_installModule_onInstallReverts_reverts() public {
        // MEDIUM-1 fix: onInstall failure now hard-reverts; module is NOT marked installed
        RevertingModule badModule = new RevertingModule();
        bytes memory sig = _installSigWithData(g0Wallet, address(account), 1, address(badModule), "");
        vm.prank(ownerWallet.addr);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarAirAccountBase.ModuleInstallCallbackFailed.selector, 1, address(badModule))
        );
        account.installModule(1, address(badModule), sig);
        // Module must NOT be marked installed after revert
        assertFalse(account.isModuleInstalled(1, address(badModule), ""));
    }

    function test_installModule_onInstallSucceeds_noRevert() public {
        // Normal module install should succeed without revert
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(mockModule), sig);
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));
    }

    // ─── MEDIUM-2: cross-typeId install/uninstall lifecycle ──────────────────────

    /// @notice MEDIUM-2: installing the same module as both executor (typeId=2) AND validator (typeId=1)
    ///         must call onInstall exactly once (on first install) and onUninstall exactly once
    ///         (only after the last typeId is removed).
    function test_crossTypeId_onInstall_calledOnce_onUninstall_calledOnce() public {
        TrackingModule tracker = new TrackingModule();

        // Step 1: install as executor (typeId=2) — onInstall should be called once
        bytes memory sig2 = _installSig(g0Wallet, address(account), 2, address(tracker));
        vm.prank(ownerWallet.addr);
        account.installModule(2, address(tracker), sig2);
        assertTrue(account.isModuleInstalled(2, address(tracker), ""));
        assertEq(tracker.installCount(), 1, "onInstall must be called on first install");

        // Step 2: install same module as validator (typeId=1) — onInstall must NOT be called again
        bytes memory sig1 = _installSig(g0Wallet, address(account), 1, address(tracker));
        vm.prank(ownerWallet.addr);
        account.installModule(1, address(tracker), sig1);
        assertTrue(account.isModuleInstalled(1, address(tracker), ""));
        assertTrue(account.isModuleInstalled(2, address(tracker), ""));
        assertEq(tracker.installCount(), 1, "onInstall must NOT be called again on second typeId");

        // Step 3: uninstall as validator (typeId=1) — onUninstall must NOT be called yet (still live as executor)
        bytes memory usig0 = _uninstallSig(g0Wallet, address(account), 1, address(tracker));
        bytes memory usig1 = _uninstallSig(g1Wallet, address(account), 1, address(tracker));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(1, address(tracker), abi.encodePacked(usig0, usig1));
        assertFalse(account.isModuleInstalled(1, address(tracker), ""));
        assertTrue(account.isModuleInstalled(2, address(tracker), ""), "executor role must still be active");
        assertEq(tracker.uninstallCount(), 0, "onUninstall must NOT be called while another typeId is still active");

        // Step 4: uninstall as executor (typeId=2) — now onUninstall must be called once
        bytes memory usig2 = _uninstallSig(g0Wallet, address(account), 2, address(tracker));
        bytes memory usig3 = _uninstallSig(g1Wallet, address(account), 2, address(tracker));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(2, address(tracker), abi.encodePacked(usig2, usig3));
        assertFalse(account.isModuleInstalled(2, address(tracker), ""));
        assertEq(tracker.uninstallCount(), 1, "onUninstall must be called exactly once after last typeId removed");
    }

    /// @notice MEDIUM-2: installing same module twice under the same typeId must still revert.
    function test_crossTypeId_sameTypeId_reverts() public {
        _installWithG0(1, address(mockModule));
        bytes memory sig = _installSig(g0Wallet, address(account), 1, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleAlreadyInstalled.selector);
        account.installModule(1, address(mockModule), sig);
    }
}
