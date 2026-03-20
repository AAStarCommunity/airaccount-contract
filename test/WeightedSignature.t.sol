// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockEPW {
    mapping(address => uint256) public balances;

    function depositTo(address a) external payable { balances[a] += msg.value; }
    function balanceOf(address a) external view returns (uint256) { return balances[a]; }
    function withdrawTo(address payable to, uint256 amount) external {
        balances[msg.sender] -= amount;
        (bool s,) = to.call{value: amount}(""); require(s);
    }
    receive() external payable {}
}

contract MockBLSOk is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure returns (uint256) { return 0; }
}

contract MockP256OkW {
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(uint256(1)); }
}

contract MockP256FailW {
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(uint256(0)); }
}

// ─── Test Contract ────────────────────────────────────────────────────────────

/// @title WeightedSignatureTest — Unit tests for M6.1 (algId 0x07) + M6.2 (guardian weight governance)
contract WeightedSignatureTest is Test {
    function _initWithGuard(AAStarAirAccountV7 acct, address ep, address _owner, AAStarAirAccountBase.InitConfig memory cfg) internal {
        address g = address(0);
        if (cfg.dailyLimit > 0) {
            g = address(new AAStarGlobalGuard(address(acct), cfg.dailyLimit, cfg.approvedAlgIds, cfg.minDailyLimit, cfg.initialTokens, cfg.initialTokenConfigs));
        }
        acct.initialize(ep, _owner, cfg, g);
    }
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    MockEPW ep;
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockBLSOk blsMock;

    Vm.Wallet ownerW;
    Vm.Wallet guardian0W;
    Vm.Wallet guardian1W;
    Vm.Wallet guardian2W;
    Vm.Wallet otherW;

    /// @dev Safe default: no single source (max weight 2) reaches tier1Threshold (3).
    ///      Tier1: P256+ECDSA=4 ≥ 3 ✓,  P256+guardian=3 ✓
    ///      Tier2: P256+ECDSA+guardian=5 ≥ 4 ✓
    ///      Tier3: P256+ECDSA+guardian+BLS=7 ≥ 6 ✓  (or P256+ECDSA+BLS=6 ✓)
    AAStarAirAccountBase.WeightConfig safeConfig;

    function setUp() public {
        ownerW    = vm.createWallet("owner");
        guardian0W = vm.createWallet("g0");
        guardian1W = vm.createWallet("g1");
        guardian2W = vm.createWallet("g2");
        otherW    = vm.createWallet("other");

        ep = new MockEPW();

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [guardian0W.addr, guardian1W.addr, guardian2W.addr],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7();
        account.initialize(address(ep), ownerW.addr, cfg);


        router = new AAStarValidator();
        blsMock = new MockBLSOk();
        router.registerAlgorithm(0x01, address(blsMock));

        vm.startPrank(ownerW.addr);
        account.setValidator(address(router));
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();

        // Mock P256 precompile to always succeed
        MockP256OkW p256ok = new MockP256OkW();
        vm.etch(address(0x100), address(p256ok).code);

        vm.deal(address(account), 100 ether);

        safeConfig = AAStarAirAccountBase.WeightConfig({
            passkeyWeight:   2,
            ecdsaWeight:     2,
            blsWeight:       2,
            guardian0Weight: 1,
            guardian1Weight: 1,
            guardian2Weight: 1,
            _padding:        0,
            tier1Threshold:  3,
            tier2Threshold:  4,
            tier3Threshold:  6
        });
    }

    // ─── 1. setWeightConfig ───────────────────────────────────────────────────

    function test_setWeightConfig_firstTime_succeeds() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        (uint8 pk, uint8 ec,,,,,,uint8 t1, uint8 t2, uint8 t3) = account.weightConfig();
        assertEq(pk, 2);
        assertEq(ec, 2);
        assertEq(t1, 3);
        assertEq(t2, 4);
        assertEq(t3, 6);
    }

    function test_setWeightConfig_emitsEvent() public {
        vm.prank(ownerW.addr);
        vm.expectEmit(false, false, false, false);
        emit AAStarAirAccountBase.WeightConfigUpdated(safeConfig);
        account.setWeightConfig(safeConfig);
    }

    function test_setWeightConfig_zeroTier1Threshold_reverts() public {
        AAStarAirAccountBase.WeightConfig memory bad = safeConfig;
        bad.tier1Threshold = 0;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.InsecureWeightConfig.selector);
        account.setWeightConfig(bad);
    }

    function test_setWeightConfig_passkeyReachesThreshold_reverts() public {
        AAStarAirAccountBase.WeightConfig memory bad = safeConfig;
        bad.passkeyWeight = 3; // 3 >= tier1Threshold(3) → insecure
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.InsecureWeightConfig.selector);
        account.setWeightConfig(bad);
    }

    function test_setWeightConfig_ecdsaReachesThreshold_reverts() public {
        AAStarAirAccountBase.WeightConfig memory bad = safeConfig;
        bad.ecdsaWeight = 3;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.InsecureWeightConfig.selector);
        account.setWeightConfig(bad);
    }

    function test_setWeightConfig_blsReachesThreshold_reverts() public {
        AAStarAirAccountBase.WeightConfig memory bad = safeConfig;
        bad.blsWeight = 3;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.InsecureWeightConfig.selector);
        account.setWeightConfig(bad);
    }

    function test_setWeightConfig_strengthening_allowsDirect() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        // Increase tier1Threshold (harder to reach) → strengthening, direct set allowed
        AAStarAirAccountBase.WeightConfig memory stronger = safeConfig;
        stronger.tier1Threshold = 4; // increase → harder → strengthening
        // Guardian weights still < 4, ok. passkeyWeight=2<4, ecdsaWeight=2<4, blsWeight=2<4
        vm.prank(ownerW.addr);
        account.setWeightConfig(stronger);

        (,,,,,,,uint8 t1,,) = account.weightConfig();
        assertEq(t1, 4);
    }

    function test_setWeightConfig_weakenThreshold_reverts() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        // Decrease tier1Threshold → weakening → requires proposal
        AAStarAirAccountBase.WeightConfig memory weaker = safeConfig;
        weaker.tier1Threshold = 2;
        weaker.passkeyWeight = 1; // must keep < new threshold(2), ensure 1<2
        weaker.ecdsaWeight = 1;
        weaker.blsWeight = 1;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeakeningRequiresProposal.selector);
        account.setWeightConfig(weaker);
    }

    function test_setWeightConfig_weakenWeight_reverts() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        // Decrease passkeyWeight → weakening
        AAStarAirAccountBase.WeightConfig memory weaker = safeConfig;
        weaker.passkeyWeight = 1;
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeakeningRequiresProposal.selector);
        account.setWeightConfig(weaker);
    }

    function test_setWeightConfig_byNonOwner_reverts() public {
        vm.prank(otherW.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        account.setWeightConfig(safeConfig);
    }

    // ─── 2. validateUserOp with ALG_WEIGHTED ─────────────────────────────────

    function test_weighted_p256AndECDSA_returns0() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig); // p256(2)+ecdsa(2)=4 >= tier1(3)

        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(
            uint8(0x07),    // algId
            uint8(0x03),    // bitmap: P256 (bit0) + ECDSA (bit1)
            _dummyP256(),   // 64 bytes
            _signECDSA(ownerW, userOpHash) // 65 bytes
        );

        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 0);
    }

    function test_weighted_ecdsaOnly_belowThreshold_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig); // ecdsa(2) < tier1(3)

        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(
            uint8(0x07),
            uint8(0x02), // bitmap: ECDSA only
            _signECDSA(ownerW, userOpHash)
        );

        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_p256Only_belowThreshold_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig); // p256(2) < tier1(3)

        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(
            uint8(0x07),
            uint8(0x01), // bitmap: P256 only
            _dummyP256()
        );

        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_p256PlusGuardian0_meetsThreshold_returns0() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig); // p256(2)+g0(1)=3 == tier1(3)

        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(
            uint8(0x07),
            uint8(0x09), // bitmap: P256 (bit0) + guardian0 (bit3) = 0x09
            _dummyP256(),
            _signECDSA(guardian0W, userOpHash)
        );

        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 0);
    }

    function test_weighted_configNotInitialized_reverts() public {
        // tier1Threshold == 0 → revert WeightConfigNotInitialized
        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(uint8(0x07), uint8(0x01), _dummyP256());
        PackedUserOperation memory op = _buildOp(address(account), sig);

        vm.prank(address(ep));
        vm.expectRevert(AAStarAirAccountBase.WeightConfigNotInitialized.selector);
        account.validateUserOp(op, userOpHash, 0);
    }

    function test_weighted_p256Fails_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        MockP256FailW failMock = new MockP256FailW();
        vm.etch(address(0x100), address(failMock).code);

        bytes32 userOpHash = keccak256("test-op");
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x03), _dummyP256(), _signECDSA(ownerW, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_ecdsaWrongSigner_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        bytes32 userOpHash = keccak256("test-op");
        // Sign with 'other' instead of owner
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x02), _signECDSA(otherW, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_guardianWrongSigner_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        bytes32 userOpHash = keccak256("test-op");
        // Sign guardian slot with 'other' instead of guardian0
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x09), _dummyP256(), _signECDSA(otherW, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_reservedBitsSet_returns1() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        bytes32 userOpHash = keccak256("test-op");
        // bit 7 set (reserved) — must be rejected
        bytes memory sig = abi.encodePacked(uint8(0x07), uint8(0x81), _dummyP256());
        PackedUserOperation memory op = _buildOp(address(account), sig);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1);
    }

    function test_weighted_nonExistentGuardianBitSet_returns1() public {
        // Deploy account with only 1 guardian
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [guardian0W.addr, address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 acc1 = new AAStarAirAccountV7();
        acc1.initialize(address(ep), ownerW.addr, cfg);


        vm.startPrank(ownerW.addr);
        acc1.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        acc1.setWeightConfig(safeConfig);
        vm.stopPrank();

        bytes32 userOpHash = keccak256("test-op");
        // Try to use guardian1 slot (index 1) which doesn't exist
        bytes memory sig = abi.encodePacked(
            uint8(0x07),
            uint8(0x11), // P256(bit0) + guardian1(bit4)
            _dummyP256(),
            _signECDSA(guardian1W, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(acc1), sig);
        vm.prank(address(ep));
        assertEq(acc1.validateUserOp(op, userOpHash, 0), 1);
    }

    // ─── 3. execute integration with ALG_WEIGHTED ─────────────────────────────

    function test_execute_weighted_p256AndECDSA_noGuard_succeeds() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        bytes32 userOpHash = keccak256("test-exec");
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x03), _dummyP256(), _signECDSA(ownerW, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(account), sig);

        // Validation writes transient storage
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, userOpHash, 0), 0);

        // Execution reads transient storage, resolves weight → ALG_ECDSA (tier1 for weight=4≥3)
        address target = makeAddr("target");
        vm.prank(address(ep));
        account.execute(target, 0.1 ether, "");
        assertEq(target.balance, 0.1 ether);
    }

    function test_execute_weighted_resolvesTier2() public {
        // Setup account with tier limits and approved algs
        uint8[] memory algIds = new uint8[](4);
        algIds[0] = 0x02; algIds[1] = 0x04; algIds[2] = 0x07; algIds[3] = 0x01;
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [guardian0W.addr, guardian1W.addr, guardian2W.addr],
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 tieredAcc = new AAStarAirAccountV7();
        _initWithGuard(tieredAcc, address(ep), ownerW.addr, cfg);

        vm.deal(address(tieredAcc), 100 ether);

        vm.startPrank(ownerW.addr);
        tieredAcc.setValidator(address(router));
        tieredAcc.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        tieredAcc.setTierLimits(0.1 ether, 1 ether);
        tieredAcc.setWeightConfig(safeConfig); // p256+ecdsa=4 ≥ tier2Threshold(4) → resolves to T2
        vm.stopPrank();

        bytes32 userOpHash = keccak256("test-tier2");
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x03), _dummyP256(), _signECDSA(ownerW, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(tieredAcc), sig);

        vm.prank(address(ep));
        assertEq(tieredAcc.validateUserOp(op, userOpHash, 0), 0);

        // Execute 0.5 ETH (tier2 required: 0.1<0.5≤1.0) — weight resolves to T2 → passes
        address target = makeAddr("t2target");
        vm.prank(address(ep));
        tieredAcc.execute(target, 0.5 ether, "");
        assertEq(target.balance, 0.5 ether);
    }

    function test_execute_weighted_insufficientForRequiredTier_reverts() public {
        uint8[] memory algIds = new uint8[](3);
        algIds[0] = 0x02; algIds[1] = 0x04; algIds[2] = 0x07;
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [guardian0W.addr, guardian1W.addr, guardian2W.addr],
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 tieredAcc = new AAStarAirAccountV7();
        _initWithGuard(tieredAcc, address(ep), ownerW.addr, cfg);

        vm.deal(address(tieredAcc), 100 ether);

        vm.startPrank(ownerW.addr);
        tieredAcc.setValidator(address(router));
        tieredAcc.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        tieredAcc.setTierLimits(0.1 ether, 1 ether);
        tieredAcc.setWeightConfig(safeConfig); // p256(2)+g0(1)=3 → resolves to T1 (tier1Threshold=3)
        vm.stopPrank();

        bytes32 userOpHash = keccak256("test-insuf");
        // Use only P256+guardian0 → weight=3, resolves to ALG_ECDSA (tier1)
        bytes memory sig = abi.encodePacked(
            uint8(0x07), uint8(0x09), _dummyP256(), _signECDSA(guardian0W, userOpHash)
        );
        PackedUserOperation memory op = _buildOp(address(tieredAcc), sig);

        vm.prank(address(ep));
        assertEq(tieredAcc.validateUserOp(op, userOpHash, 0), 0);

        // Execute 0.5 ETH (tier2 required: >0.1ETH) but weight only resolves to tier1 → revert
        vm.prank(address(ep));
        // Full encoding needed since InsufficientTier has parameters (uint8, uint8)
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountBase.InsufficientTier.selector, uint8(2), uint8(1)));
        tieredAcc.execute(makeAddr("target"), 0.5 ether, "");
    }

    // ─── 4. M6.2: Guardian Consent for Weakening Changes ──────────────────────

    function test_proposeWeightChange_weakening_succeeds() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        AAStarAirAccountBase.WeightConfig memory weaker = _weakerConfig();
        vm.prank(ownerW.addr);
        vm.expectEmit(true, false, false, false);
        emit AAStarAirAccountBase.WeightChangeProposed(weaker, ownerW.addr);
        account.proposeWeightChange(weaker);

        // Confirm pending via a second propose attempt (proves state was written)
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeightChangePending.selector);
        account.proposeWeightChange(weaker);
    }

    function test_proposeWeightChange_notWeakening_reverts() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        // Strengthening: increase tier1Threshold
        AAStarAirAccountBase.WeightConfig memory stronger = safeConfig;
        stronger.tier1Threshold = 4;
        // All weights 2 < 4 → passes InsecureWeightConfig
        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeakeningRequiresProposal.selector);
        account.proposeWeightChange(stronger);
    }

    function test_proposeWeightChange_alreadyPending_reverts() public {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        AAStarAirAccountBase.WeightConfig memory weaker = _weakerConfig();
        vm.prank(ownerW.addr);
        account.proposeWeightChange(weaker);

        vm.prank(ownerW.addr);
        vm.expectRevert(AAStarAirAccountBase.WeightChangePending.selector);
        account.proposeWeightChange(weaker);
    }

    function test_approveWeightChange_byGuardian_succeeds() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        vm.expectEmit(true, false, false, true);
        emit AAStarAirAccountBase.WeightChangeApproved(guardian0W.addr, 1);
        account.approveWeightChange();
    }

    function test_approveWeightChange_duplicate_reverts() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.approveWeightChange();

        vm.prank(guardian0W.addr);
        vm.expectRevert(AAStarAirAccountBase.WeightChangeAlreadyApproved.selector);
        account.approveWeightChange();
    }

    function test_approveWeightChange_byNonGuardian_reverts() public {
        _setupWeakenProposal();

        vm.prank(otherW.addr);
        vm.expectRevert(AAStarAirAccountBase.NotGuardian.selector);
        account.approveWeightChange();
    }

    function test_approveWeightChange_noPending_reverts() public {
        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        account.approveWeightChange();
    }

    function test_executeWeightChange_afterTimelockAndThreshold_succeeds() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.approveWeightChange();
        vm.prank(guardian1W.addr);
        account.approveWeightChange();

        vm.warp(block.timestamp + 2 days + 1);
        account.executeWeightChange();

        (,,,,,,,uint8 t1,,) = account.weightConfig();
        assertEq(t1, 2); // applied the weaker config
    }

    function test_executeWeightChange_beforeTimelock_reverts() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.approveWeightChange();
        vm.prank(guardian1W.addr);
        account.approveWeightChange();

        vm.expectRevert(AAStarAirAccountBase.WeightChangeTimelockNotExpired.selector);
        account.executeWeightChange();
    }

    function test_executeWeightChange_insufficientApprovals_reverts() public {
        _setupWeakenProposal();

        // Only 1 approval, need 2
        vm.prank(guardian0W.addr);
        account.approveWeightChange();

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(AAStarAirAccountBase.WeightChangeNotApproved.selector);
        account.executeWeightChange();
    }

    function test_executeWeightChange_clearsPendingProposal() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.approveWeightChange();
        vm.prank(guardian1W.addr);
        account.approveWeightChange();

        vm.warp(block.timestamp + 2 days + 1);
        account.executeWeightChange();

        // Proposal cleared — executeWeightChange again should revert
        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        account.executeWeightChange();
    }

    function test_cancelWeightChange_byOwner_succeeds() public {
        _setupWeakenProposal();

        vm.prank(ownerW.addr);
        account.cancelWeightChange();

        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        account.cancelWeightChange();
    }

    function test_cancelWeightChange_byGuardian_succeeds() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.cancelWeightChange();

        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        account.cancelWeightChange();
    }

    function test_cancelWeightChange_byOther_reverts() public {
        _setupWeakenProposal();

        vm.prank(otherW.addr);
        vm.expectRevert(AAStarAirAccountBase.NotGuardian.selector);
        account.cancelWeightChange();
    }

    function test_cancelWeightChange_noPending_reverts() public {
        vm.expectRevert(AAStarAirAccountBase.NoWeightChangeProposal.selector);
        account.cancelWeightChange();
    }

    function test_allThreeGuardians_canApprove() public {
        _setupWeakenProposal();

        vm.prank(guardian0W.addr);
        account.approveWeightChange();
        vm.prank(guardian1W.addr);
        account.approveWeightChange();
        vm.prank(guardian2W.addr);
        account.approveWeightChange();

        vm.warp(block.timestamp + 2 days + 1);
        account.executeWeightChange(); // Should succeed with 3 approvals (>= threshold 2)

        (,,,,,,,uint8 t1,,) = account.weightConfig();
        assertEq(t1, 2);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _buildOp(address sender, bytes memory sig) internal pure returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }

    function _dummyP256() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(0xDEAD)), bytes32(uint256(0xBEEF)));
    }

    function _signECDSA(Vm.Wallet memory wallet, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A safe "weakening" config relative to safeConfig (lower tier1Threshold)
    function _weakerConfig() internal pure returns (AAStarAirAccountBase.WeightConfig memory) {
        return AAStarAirAccountBase.WeightConfig({
            passkeyWeight:   1,
            ecdsaWeight:     1,
            blsWeight:       1,
            guardian0Weight: 1,
            guardian1Weight: 1,
            guardian2Weight: 1,
            _padding:        0,
            tier1Threshold:  2, // decreased from 3 → weakening
            tier2Threshold:  3,
            tier3Threshold:  4
        });
    }

    /// @dev Set up account with safeConfig + submit a weakening proposal
    function _setupWeakenProposal() internal {
        vm.prank(ownerW.addr);
        account.setWeightConfig(safeConfig);

        vm.prank(ownerW.addr);
        account.proposeWeightChange(_weakerConfig());
    }
}
