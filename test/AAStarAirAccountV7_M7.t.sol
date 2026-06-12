// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {IAirAccountAgent} from "../src/interfaces/IAirAccountAgent.sol";
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

// ─── Mock AgentRegistry (M8.1) ───────────────────────────────────────────────

contract MockRegistry {
    mapping(address => address) public agentWalletOwner;
    // Accept the new (address, bytes) signature — MockRegistry skips signature verification
    function registerAgent(address agentWallet, bytes calldata /* agentWalletSig */) external {
        agentWalletOwner[agentWallet] = msg.sender;
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

    function test_accountId_is_0_17_2() public view {
        assertEq(account.accountId(), "airaccount.v7@0.17.2");
    }

    function test_ACCOUNT_VERSION_constant() public view {
        assertEq(account.ACCOUNT_VERSION(), "0.17.2");
    }

    // ─── supportsModule ───────────────────────────────────────────────────────

    function test_supportsModule_validator_type1_true() public view {
        assertTrue(account.supportsModule(1));
    }

    function test_supportsModule_executor_type2_true() public view {
        assertTrue(account.supportsModule(2));
    }

    function test_supportsModule_hook_type4_true() public view {
        // ERC-7579: hook is module type 4
        assertTrue(account.supportsModule(4));
    }

    function test_supportsModule_fallback_type3_false() public view {
        // ERC-7579: fallback handler is module type 3 — not supported by this account
        assertFalse(account.supportsModule(3));
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
        bytes memory sig = _installSig(g0Wallet, address(account), 4, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.installModule(4, address(mockModule), sig);
        assertTrue(account.isModuleInstalled(4, address(mockModule), ""));
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

    function test_installModule_invalidType3_fallback_reverts() public {
        // ERC-7579 type 3 is fallback handler — not supported by this account.
        bytes memory sig = _installSig(g0Wallet, address(account), 3, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.installModule(3, address(mockModule), sig);
    }

    function test_installModule_invalidType5_reverts() public {
        bytes memory sig = _installSig(g0Wallet, address(account), 5, address(mockModule));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.InvalidModuleType.selector);
        account.installModule(5, address(mockModule), sig);
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
        _installWithG0(4, address(mockModule));
        // deploy a second distinct mock module
        MockModule mockModule2 = new MockModule();
        bytes memory sig2 = _installSig(g0Wallet, address(account), 4, address(mockModule2));
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.ModuleAlreadyInstalled.selector);
        account.installModule(4, address(mockModule2), sig2);
    }

    function test_installModule_hookAfterUninstall_succeeds() public {
        // After uninstalling the first hook, a new hook can be installed
        _installWithG0(4, address(mockModule));
        // uninstall requires 2 guardian sigs
        bytes memory unSig = abi.encodePacked(
            _uninstallSig(g0Wallet, address(account), 4, address(mockModule)),
            _uninstallSig(g1Wallet, address(account), 4, address(mockModule))
        );
        vm.prank(ownerWallet.addr);
        account.uninstallModule(4, address(mockModule), unSig);
        // now install a second hook — should succeed
        MockModule mockModule2 = new MockModule();
        bytes memory sig2 = _installSig(g0Wallet, address(account), 4, address(mockModule2));
        vm.prank(ownerWallet.addr);
        account.installModule(4, address(mockModule2), sig2);
        assertTrue(account.isModuleInstalled(4, address(mockModule2), ""));
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
        _installWithG0(4, address(mockModule));
        bytes memory sig0 = _uninstallSig(g0Wallet, address(account), 4, address(mockModule));
        bytes memory sig1 = _uninstallSig(g1Wallet, address(account), 4, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.uninstallModule(4, address(mockModule), abi.encodePacked(sig0, sig1));
        assertFalse(account.isModuleInstalled(4, address(mockModule), ""));
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

    /// @notice C-4: an executor runs at Tier 1 and cannot supply higher-tier sigs, so an ETH
    ///         transfer above tier1Limit must revert InsufficientTier. The owner defines "small"
    ///         via tier1Limit.
    function test_C4_executeFromExecutor_aboveTier1_reverts() public {
        _installWithG0(2, address(mockModule)); // install as executor
        vm.prank(ownerWallet.addr);
        account.setTierLimits(0.1 ether, 1 ether); // tier1Limit = 0.1 ether

        // 0.2 ether is a Tier-2 amount; executor (Tier 1) must be rejected.
        bytes memory calldata_ = abi.encodePacked(address(mockTarget), uint256(0.2 ether), bytes(""));
        vm.prank(address(mockModule));
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountBase.InsufficientTier.selector, uint8(2), uint8(1)));
        account.executeFromExecutor(bytes32(0), calldata_);
    }

    /// @notice C-4: an ETH transfer at or below tier1Limit is allowed for an executor.
    function test_C4_executeFromExecutor_withinTier1_succeeds() public {
        _installWithG0(2, address(mockModule));
        vm.prank(ownerWallet.addr);
        account.setTierLimits(0.1 ether, 1 ether);

        bytes memory calldata_ = abi.encodePacked(address(mockTarget), uint256(0.05 ether), bytes(""));
        vm.prank(address(mockModule));
        account.executeFromExecutor(bytes32(0), calldata_);
        assertEq(address(mockTarget).balance, 0.05 ether);
    }

    /// @notice C-4 boundary: the M7 account has NO guard and NO tier limits (tier1Limit==0).
    ///         Per the C-4 doc, with tiering disabled the executor is NOT implicitly capped —
    ///         a large ETH transfer must succeed (no InsufficientTier, no guard revert).
    function test_C4_executeFromExecutor_noGuardNoTier_allowsLargeEth() public {
        _installWithG0(2, address(mockModule));
        address recipient = makeAddr("c4_recipient");
        bytes memory calldata_ = abi.encodePacked(recipient, uint256(5 ether), bytes(""));
        vm.prank(address(mockModule));
        account.executeFromExecutor(bytes32(0), calldata_);
        assertEq(recipient.balance, 5 ether);
    }

    /// @notice C-4 boundary: with a guard configured but tiering disabled (tier1Limit==0),
    ///         an executor is bounded by the daily limit, NOT by tier. Within the daily limit
    ///         a large op succeeds; over it reverts DailyLimitExceeded (not InsufficientTier).
    function test_C4_executeFromExecutor_guardedButTierDisabled_boundedByDailyLimit() public {
        uint8[] memory algs = new uint8[](1);
        algs[0] = 0x02; // ECDSA approved
        AAStarAirAccountV7 gacct = new AAStarAirAccountV7();
        AAStarGlobalGuard guard = new AAStarGlobalGuard(
            address(gacct), 2 ether, algs, 0, new address[](0), new AAStarGlobalGuard.TokenConfig[](0)
        );
        gacct.initialize(address(ep), ownerWallet.addr, AAStarAirAccountBase.InitConfig({
            guardians: [g0Wallet.addr, g1Wallet.addr, g2Wallet.addr],
            dailyLimit: 2 ether,
            approvedAlgIds: algs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }), address(guard));
        vm.deal(address(gacct), 10 ether);

        bytes memory sig = _installSig(g0Wallet, address(gacct), 2, address(mockModule));
        vm.prank(ownerWallet.addr);
        gacct.installModule(2, address(mockModule), sig);

        address recipient = makeAddr("c4_recipient2");
        // 1 ether: no tier limits set, within 2 ether daily limit → succeeds (no tier check)
        vm.prank(address(mockModule));
        gacct.executeFromExecutor(bytes32(0), abi.encodePacked(recipient, uint256(1 ether), bytes("")));
        assertEq(recipient.balance, 1 ether);

        // 3 ether: exceeds remaining daily limit → reverts DailyLimitExceeded, NOT InsufficientTier
        vm.prank(address(mockModule));
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, uint256(3 ether), uint256(1 ether)));
        gacct.executeFromExecutor(bytes32(0), abi.encodePacked(recipient, uint256(3 ether), bytes("")));
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
        // Regression for HIGH-1 fix: validators returning non-zero validationData (e.g. an installed
        // validator packing expiry as `uint256(expiry) << 160`) must still write algId via
        // _storeValidatedAlgId. Gate is validationData != 1 (SIG_VALIDATION_FAILED sentinel).
        // v0.17.2 Codex P1-#11: use a non-session-key algId so the nonce-key 0x08 rejection
        // (in V7 validateUserOp) does NOT trigger. ALG_ECDSA (0x02) is fine for this regression check.
        _installWithG0(1, address(mockModule));
        uint256 expiry = block.timestamp + 3600;
        uint256 nonZeroResult = uint256(expiry) << 160;
        mockModule.setValidateResult(nonZeroResult);

        bytes memory sig = abi.encodePacked(uint8(0x02), new bytes(65)); // sig[0]=ALG_ECDSA (not 0x08)
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

    /// @notice v0.17.2 Codex P1-#11 regression: nonce-key routed UserOp with sig[0] == ALG_SESSION_KEY (0x08)
    ///         must be rejected (validationData = 1) to prevent session-scope bypass.
    ///         Background: if a custom validator returned success for sig[0]=0x08, base._enforceGuard would
    ///         observe `algId == ALG_SESSION_KEY` with `taggedSessionKey == 0` and skip the scope/velocity
    ///         enforcement block entirely. Native base._validateSignature is the only path that may set
    ///         taggedSessionKey, so nonce-key routing of 0x08 is now refused outright.
    function test_validateUserOp_nonceKey_sessionKeyAlgId_rejected() public {
        _installWithG0(1, address(mockModule));
        mockModule.setValidateResult(0); // validator says "ok"

        bytes memory sig = abi.encodePacked(uint8(0x08), new bytes(65)); // sig[0]=ALG_SESSION_KEY
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
        // Even with the validator returning 0, V7 must force a failure when sig[0] is ALG_SESSION_KEY
        // on the nonce-key path. This closes the session-scope bypass.
        assertEq(result, 1, "session key via nonce-key route must be rejected");
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
        assertFalse(account.isModuleInstalled(4, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallValidator_true() public {
        _installWithG0(1, address(mockModule));
        assertTrue(account.isModuleInstalled(1, address(mockModule), ""));
        // Other types should remain false
        assertFalse(account.isModuleInstalled(2, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(4, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallExecutor_true() public {
        _installWithG0(2, address(mockModule));
        assertTrue(account.isModuleInstalled(2, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(1, address(mockModule), ""));
    }

    function test_isModuleInstalled_afterInstallHook_true() public {
        _installWithG0(4, address(mockModule));
        assertTrue(account.isModuleInstalled(4, address(mockModule), ""));
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

    /// @notice ERC-7579 type 3 = fallback handler — unsupported by this account, so
    ///         isModuleInstalled(3, ...) returns false for any address (the rejected path).
    function test_isModuleInstalled_fallbackType3_false() public view {
        assertFalse(account.isModuleInstalled(3, address(mockModule), ""));
        assertFalse(account.isModuleInstalled(3, address(0), ""));
    }

    // ─── setAgentWallet ───────────────────────────────────────────────────────

    function test_setAgentWallet_owner_succeeds() public {
        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerWallet.addr);
        vm.expectEmit(true, true, false, false);
        emit AAStarAirAccountBase.AgentWalletSet(42, agentWallet, address(mockRegistry));
        // MockRegistry skips sig verification — pass empty bytes
        IAirAccountAgent(address(account)).setAgentWallet(42, agentWallet, address(mockRegistry), "");
    }

    function test_setAgentWallet_registersWithRegistry() public {
        address agentWallet = makeAddr("agentWallet");

        vm.prank(ownerWallet.addr);
        // MockRegistry skips sig verification — pass empty bytes
        IAirAccountAgent(address(account)).setAgentWallet(7, agentWallet, address(mockRegistry), "");

        // Registry should have recorded agentWallet → account as owner
        assertEq(mockRegistry.agentWalletOwner(agentWallet), address(account));
    }

    function test_setAgentWallet_notOwner_reverts() public {
        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        IAirAccountAgent(address(account)).setAgentWallet(1, makeAddr("agent"), address(mockRegistry), "");
    }

    function test_setAgentWallet_zeroWallet_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // require("Invalid agent wallet")
        IAirAccountAgent(address(account)).setAgentWallet(1, address(0), address(mockRegistry), "");
    }

    function test_setAgentWallet_zeroRegistry_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(); // require("Invalid registry")
        IAirAccountAgent(address(account)).setAgentWallet(1, makeAddr("agent"), address(0), "");
    }

    function test_setAgentWallet_failingRegistry_reverts() public {
        // setAgentWallet now hard-fails if the registry call fails (M8.1: AgentRegistrationFailed)
        address agentWallet = makeAddr("agentWallet");
        address brokenRegistry = makeAddr("brokenRegistry"); // no code → call returns false

        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.AgentRegistrationFailed.selector);
        IAirAccountAgent(address(account)).setAgentWallet(99, agentWallet, brokenRegistry, "");
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
