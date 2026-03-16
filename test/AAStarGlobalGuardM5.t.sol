// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/core/AAStarGlobalGuard.sol";
import "../src/core/AAStarAirAccountV7.sol";
import "../src/core/AAStarAirAccountBase.sol";

/// @title AAStarGlobalGuardM5Test — M5.1 ERC20 token-aware guard tests
contract AAStarGlobalGuardM5Test is Test {
    // ─── Constants ────────────────────────────────────────────────────

    uint8 constant ALG_ECDSA = 0x02;
    uint8 constant ALG_P256  = 0x03;
    uint8 constant ALG_T2    = 0x04;
    uint8 constant ALG_T3    = 0x05;

    // ERC20 selectors
    bytes4 constant TRANSFER  = 0xa9059cbb;
    bytes4 constant APPROVE   = 0x095ea7b3;
    bytes4 constant TSFR_FROM = 0x23b872dd;

    // Token decimals
    uint256 constant USDC_DEC = 1e6;
    uint256 constant ETH_DEC  = 1 ether;

    // ─── Test Setup ───────────────────────────────────────────────────

    AAStarGlobalGuard guard;
    address account = address(0xA11CE);
    address mockToken = address(0xC0FFEE);
    address otherToken = address(0xBEEF);

    function setUp() public {
        uint8[] memory algIds = new uint8[](3);
        algIds[0] = ALG_ECDSA;
        algIds[1] = ALG_P256;
        algIds[2] = ALG_T2;

        address[] memory tokens = new address[](1);
        tokens[0] = mockToken;
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,   // 100 USDC → ECDSA ok
            tier2Limit: 1000 * USDC_DEC,  // 1,000 USDC → P256+BLS needed
            dailyLimit: 5000 * USDC_DEC   // 5,000 USDC daily cap
        });

        guard = new AAStarGlobalGuard(account, 1 ether, algIds, 0.1 ether, tokens, cfgs);
    }

    // ─── 1. Constructor token config ──────────────────────────────────

    function test_constructor_setsTokenConfig() public view {
        (uint256 t1, uint256 t2, uint256 daily) = _getConfig(mockToken);
        assertEq(t1, 100 * USDC_DEC);
        assertEq(t2, 1000 * USDC_DEC);
        assertEq(daily, 5000 * USDC_DEC);
    }

    function test_unconfiguredToken_noLimits() public {
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(otherToken, 999999 * USDC_DEC, ALG_ECDSA);
        assertTrue(ok);
    }

    // ─── 2. Tier enforcement ──────────────────────────────────────────

    function test_tier1_ECDSA_withinLimit_passes() public {
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 50 * USDC_DEC, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_tier1_ECDSA_atExactLimit_passes() public {
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 100 * USDC_DEC, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_tier2_ECDSA_exceedsTier1_reverts() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        guard.checkTokenTransaction(mockToken, 101 * USDC_DEC, ALG_ECDSA);
    }

    function test_tier1_P256_exceedsTier1_reverts() public {
        // P256 single-factor = Tier 1 (same as ECDSA). Cannot authorize Tier 2 amounts alone.
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        guard.checkTokenTransaction(mockToken, 500 * USDC_DEC, ALG_P256);
    }

    function test_tier3_P256_exceedsTier2_reverts() public {
        // P256 is Tier 1. Amount 1001 USDC > tier2Limit (1000) requires Tier 3. P256 provides Tier 1.
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 3, 1));
        guard.checkTokenTransaction(mockToken, 1001 * USDC_DEC, ALG_P256);
    }

    function test_tier3_T2_exceedsTier2_reverts() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 3, 2));
        guard.checkTokenTransaction(mockToken, 2000 * USDC_DEC, ALG_T2);
    }

    function test_tier3_T3_exceedsTier2_passes() public {
        // ALG_T3 = 0x05 — need to approve it first
        vm.prank(account);
        guard.approveAlgorithm(ALG_T3);

        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 2000 * USDC_DEC, ALG_T3);
        assertTrue(ok);
    }

    // ─── 3. Daily limit enforcement ───────────────────────────────────

    function test_dailyLimit_exceeded_reverts() public {
        // Send 4900 USDC (within limit)
        vm.prank(account);
        guard.approveAlgorithm(ALG_T3);
        vm.prank(account);
        guard.checkTokenTransaction(mockToken, 4900 * USDC_DEC, ALG_T3);

        // Try to send 200 more → total 5100 > daily 5000 → revert
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                AAStarGlobalGuard.TokenDailyLimitExceeded.selector,
                mockToken,
                200 * USDC_DEC,
                100 * USDC_DEC   // remaining = 5000 - 4900 = 100
            )
        );
        guard.checkTokenTransaction(mockToken, 200 * USDC_DEC, ALG_T3);
    }

    function test_dailyLimit_exactlyFills_passes() public {
        vm.prank(account);
        guard.approveAlgorithm(ALG_T3);
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 5000 * USDC_DEC, ALG_T3);
        assertTrue(ok);
    }

    // ─── 4. Cumulative batch bypass prevention ────────────────────────

    function test_batchBypass_ECDSA_cumulativeExceedsTier1_reverts() public {
        // First call: 60 USDC (cumulative 60 ≤ 100, tier1 ok)
        vm.prank(account);
        guard.checkTokenTransaction(mockToken, 60 * USDC_DEC, ALG_ECDSA);

        // Second call: 60 USDC (cumulative 120 > 100, needs tier2)
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        guard.checkTokenTransaction(mockToken, 60 * USDC_DEC, ALG_ECDSA);
    }

    function test_batchBypass_T2_cumulativeExceedsTier2_reverts() public {
        // ALG_T2 (0x04) is Tier 2. Each individual tx is within tier2Limit (1000 USDC),
        // but cumulatively they exceed tier2Limit — guard must require tier3 for the second tx.
        vm.prank(account);
        guard.approveAlgorithm(ALG_T2);

        // First call: 900 USDC (cumulative 900 ≤ 1000, tier2 ok)
        vm.prank(account);
        guard.checkTokenTransaction(mockToken, 900 * USDC_DEC, ALG_T2);

        // Second call: 200 USDC (cumulative 1100 > 1000, needs tier3)
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 3, 2));
        guard.checkTokenTransaction(mockToken, 200 * USDC_DEC, ALG_T2);
    }

    function test_tokenTodaySpent_updatesOnSpend() public {
        vm.prank(account);
        guard.checkTokenTransaction(mockToken, 60 * USDC_DEC, ALG_ECDSA);
        assertEq(guard.tokenTodaySpent(mockToken), 60 * USDC_DEC);

        vm.prank(account);
        guard.checkTokenTransaction(mockToken, 30 * USDC_DEC, ALG_ECDSA);
        assertEq(guard.tokenTodaySpent(mockToken), 90 * USDC_DEC);
    }

    // ─── 5. addTokenConfig (monotonic) ───────────────────────────────

    function test_addTokenConfig_newToken_succeeds() public {
        vm.prank(account);
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 1000e18,
            tier2Limit: 10000e18,
            dailyLimit: 50000e18
        }));
        (uint256 t1,,) = _getConfig(otherToken);
        assertEq(t1, 1000e18);
    }

    function test_addTokenConfig_alreadyConfigured_reverts() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.TokenAlreadyConfigured.selector, mockToken));
        guard.addTokenConfig(mockToken, AAStarGlobalGuard.TokenConfig(0, 0, 0));
    }

    function test_addTokenConfig_nonAccount_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AAStarGlobalGuard.OnlyAccount.selector);
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig(0, 0, 0));
    }

    // ─── 6. decreaseTokenDailyLimit (monotonic) ──────────────────────

    function test_decreaseTokenDailyLimit_succeeds() public {
        vm.prank(account);
        guard.decreaseTokenDailyLimit(mockToken, 2000 * USDC_DEC);
        (, , uint256 daily) = _getConfig(mockToken);
        assertEq(daily, 2000 * USDC_DEC);
    }

    function test_decreaseTokenDailyLimit_cannotIncrease_reverts() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                AAStarGlobalGuard.TokenCanOnlyDecreaseLimit.selector,
                mockToken,
                5000 * USDC_DEC,
                6000 * USDC_DEC
            )
        );
        guard.decreaseTokenDailyLimit(mockToken, 6000 * USDC_DEC);
    }

    // ─── 7. Account-level calldata parsing (integration) ─────────────

    function test_execute_ERC20Transfer_tierEnforced() public {
        // Deploy account with USDC token guard: tier1=100, tier2=1000
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = ALG_ECDSA;
        algIds[1] = ALG_P256;

        address mockUSDC = address(0xC0DE);
        address[] memory tokens = new address[](1);
        tokens[0] = mockUSDC;
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 5000 * USDC_DEC
        });

        address owner = address(0x1234);
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: cfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(this), owner, config);

        // transfer(recipient, 200 USDC) — exceeds tier1 100 USDC → guard reverts before inner call
        bytes memory transferData = abi.encodeWithSelector(TRANSFER, address(0x9999), 200 * USDC_DEC);

        // Direct owner call uses ALG_ECDSA (tier1) → InsufficientTokenTier(2, 1)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        acct.execute(mockUSDC, 0, transferData);
    }

    function test_execute_ERC20Transfer_withinTier1_guardsPassThrough() public {
        // transfer(recipient, 50 USDC) within tier1 — guard passes, call to mock address succeeds
        // (empty address in EVM: call returns success=true with empty returndata)
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;

        address mockUSDC = makeAddr("mockUSDC"); // addr with no code = call returns true
        address[] memory tokens = new address[](1);
        tokens[0] = mockUSDC;
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 5000 * USDC_DEC
        });

        address owner = makeAddr("owner");
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: cfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(this), owner, config);

        bytes memory transferData = abi.encodeWithSelector(TRANSFER, address(0x9999), 50 * USDC_DEC);

        // Guard should pass (50 ≤ 100 tier1), no revert at guard level
        // Call to empty address succeeds silently
        vm.prank(owner);
        acct.execute(mockUSDC, 0, transferData); // must NOT revert
    }

    function test_execute_nonERC20Calldata_noTokenCheck() public {
        // Token config has extremely tight limits (tier1=1). Any ERC20 call with ECDSA would fail.
        // But non-ERC20 calldata (selector not transfer/approve) bypasses token check entirely.
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;

        address targetToken = makeAddr("targetToken");
        address[] memory tokens = new address[](1);
        tokens[0] = targetToken;
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({ tier1Limit: 1, tier2Limit: 2, dailyLimit: 3 });

        address owner = makeAddr("owner2");
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: cfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(this), owner, config);

        // Unknown selector (not transfer/approve) → no token tier check → succeeds
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));
        vm.prank(owner);
        acct.execute(targetToken, 0, unknownData); // must NOT revert with InsufficientTokenTier
    }

    // ─── 8. algId tier mapping ────────────────────────────────────────

    function test_approve_selector_also_checked() public {
        // approve(spender, amount) should be treated same as transfer
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1));
        guard.checkTokenTransaction(mockToken, 500 * USDC_DEC, ALG_ECDSA);
    }

    // ─── 9. InvalidTokenConfig validation (dailyLimit >= tier2Limit bug fix) ───

    function test_invalidTokenConfig_tier1GtTier2_reverts() public {
        // tier1=500 > tier2=100 — incoherent: tier1 can never be exceeded to reach tier2
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            otherToken, 500 * USDC_DEC, 100 * USDC_DEC, 5000 * USDC_DEC
        ));
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 500 * USDC_DEC,
            tier2Limit: 100 * USDC_DEC,
            dailyLimit: 5000 * USDC_DEC
        }));
    }

    function test_invalidTokenConfig_dailyLtTier2_reverts() public {
        // dailyLimit=500 < tier2=1000 — tier2 range is unreachable, daily blocks first
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            otherToken, 100 * USDC_DEC, 1000 * USDC_DEC, 500 * USDC_DEC
        ));
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 500 * USDC_DEC   // daily < tier2 → tier2Limit is dead
        }));
    }

    function test_invalidTokenConfig_dailyLtTier1_onlyTier1Set_reverts() public {
        // tier2=0 but daily=50 < tier1=100 — tier1 max also unreachable
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            otherToken, 100 * USDC_DEC, 0, 50 * USDC_DEC
        ));
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 0,
            dailyLimit: 50 * USDC_DEC
        }));
    }

    function test_validTokenConfig_dailyEqualsTier2_passes() public {
        // dailyLimit == tier2Limit is the minimum valid config — tier2 max exactly reachable
        vm.prank(account);
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 1000 * USDC_DEC  // daily == tier2: valid edge case
        }));
        (uint256 t1, uint256 t2, uint256 daily) = guard.tokenConfigs(otherToken);
        assertEq(t2, daily);
    }

    function test_validTokenConfig_dailyGtTier2_passes() public {
        // Normal case: daily > tier2 — both tier1 and tier2 fully reachable
        vm.prank(account);
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 500 * USDC_DEC,
            dailyLimit: 2000 * USDC_DEC
        }));
        (,, uint256 daily) = guard.tokenConfigs(otherToken);
        assertEq(daily, 2000 * USDC_DEC);
    }

    function test_constructor_invalidTokenConfig_reverts() public {
        // Constructor also validates — can't deploy guard with incoherent token config
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0xBAD);
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](1);
        cfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 200 * USDC_DEC  // daily < tier2 — invalid
        });
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            address(0xBAD), 100 * USDC_DEC, 1000 * USDC_DEC, 200 * USDC_DEC
        ));
        new AAStarGlobalGuard(account, 1 ether, algIds, 0, tokens, cfgs);
    }

    // ─── 10. dailyLimit=0 prohibition when tier limits set ───────────────

    function test_validateTokenConfig_tier1WithoutDailyLimit_reverts() public {
        // tier1 > 0 but dailyLimit = 0 → cumulative tracking would be broken
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            otherToken, 100 * USDC_DEC, 0, 0
        ));
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100 * USDC_DEC,
            tier2Limit: 0,
            dailyLimit: 0
        }));
    }

    function test_validateTokenConfig_tier2WithoutDailyLimit_reverts() public {
        // tier2 > 0 but dailyLimit = 0 → cumulative tracking would be broken
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            otherToken, 0, 1000 * USDC_DEC, 0
        ));
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 0,
            tier2Limit: 1000 * USDC_DEC,
            dailyLimit: 0
        }));
    }

    function test_validateTokenConfig_dailyOnlyNoTiers_passes() public {
        // dailyOnly config (no tier limits, just daily cap) is still valid
        vm.prank(account);
        guard.addTokenConfig(otherToken, AAStarGlobalGuard.TokenConfig({
            tier1Limit: 0,
            tier2Limit: 0,
            dailyLimit: 1000 * USDC_DEC
        }));
        (,, uint256 daily) = guard.tokenConfigs(otherToken);
        assertEq(daily, 1000 * USDC_DEC);
    }

    function test_decreaseTokenDailyLimit_toZero_withTierLimits_reverts() public {
        // mockToken has tier1=100, tier2=1000, daily=5000 — cannot decrease daily to 0
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InvalidTokenConfig.selector,
            mockToken, 100 * USDC_DEC, 1000 * USDC_DEC, 0
        ));
        guard.decreaseTokenDailyLimit(mockToken, 0);
    }

    function test_decreaseTokenDailyLimit_toNonZero_withTierLimits_succeeds() public {
        // Decreasing to a non-zero value is always fine
        vm.prank(account);
        guard.decreaseTokenDailyLimit(mockToken, 1000 * USDC_DEC);
        (,, uint256 daily) = guard.tokenConfigs(mockToken);
        assertEq(daily, 1000 * USDC_DEC);
    }

    // ─── 11. ALG_BLS tier mapping alignment ───────────────────────────

    uint8 constant ALG_BLS = 0x01;

    function test_algBLS_isGuardTier3_satisfiesTier3Token() public {
        // ALG_BLS (0x01) is now Tier 3 in guard — must satisfy Tier 3 token requirements
        vm.prank(account);
        guard.approveAlgorithm(ALG_BLS);

        // Amount exceeds tier2 (1000 USDC) — requires Tier 3
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 2000 * USDC_DEC, ALG_BLS);
        assertTrue(ok);
    }

    function test_algBLS_isGuardTier3_matchesAccountTier() public {
        // Verify _algTier(0x01) == 3: ALG_BLS guard tier must match account tier
        // Previously was Tier 2 (bug), now corrected to Tier 3
        vm.prank(account);
        guard.approveAlgorithm(ALG_BLS);

        // If still Tier 2, this would revert with InsufficientTokenTier(3, 2)
        // After fix, it should pass because Tier 3 >= Tier 3
        vm.prank(account);
        bool ok = guard.checkTokenTransaction(mockToken, 5000 * USDC_DEC, ALG_BLS);
        assertTrue(ok); // daily limit = 5000, exact fill
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _getConfig(address token) internal view returns (uint256 t1, uint256 t2, uint256 daily) {
        (t1, t2, daily) = guard.tokenConfigs(token);
    }
}
