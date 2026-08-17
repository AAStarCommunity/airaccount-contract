// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/core/AAStarGlobalGuard.sol";

/// @title GuardOverheadGasTest — CC-99 需求1 (A): forge measurement of the per-op guard overhead that
///        `_enforceGuard` pays on a guard-configured account, which the CC-95 no-guard benchmark
///        (527,415/7,674 deltas on a `guard()==0` account) never priced.
/// @dev The reviewer named two guard-storage ops as the overhead: `todaySpent()` cold SLOAD and
///      `recordSpend()` first-tx zero→nonzero SSTORE. We measure them directly (isolated, no execute()
///      algId/tier confound) so the number is deterministic + reproducible, then reconcile with the
///      gas-schedule derivation (~26,800 first / ~7,000 subsequent). Reported to the paper as (M) forge.
contract GuardOverheadGasTest is Test {
    AAStarGlobalGuard guard;
    address account = address(0xACC0);

    function setUp() public {
        // Native-ETH daily cap; no token configs (the ETH-tier path is what CC-95's tiers exercise).
        address[] memory tokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory cfgs = new AAStarGlobalGuard.TokenConfig[](0);
        guard = new AAStarGlobalGuard(account, 100 ether, 0, tokens, cfgs);
    }

    function test_guardOverhead_perOp() public {
        uint256 v = 0.01 ether;

        // ── recordSpend: first tx of the day = cold dailySpent zero→nonzero SSTORE (+ reset-day SLOADs)
        vm.prank(account);
        uint256 g0 = gasleft();
        guard.recordSpend(v);
        uint256 recordFirst = g0 - gasleft();

        // ── recordSpend: subsequent same-day tx = warm nonzero→nonzero SSTORE
        vm.prank(account);
        g0 = gasleft();
        guard.recordSpend(v);
        uint256 recordWarm = g0 - gasleft();

        // ── todaySpent(): the cold SLOAD `_enforceGuard` does before the tier check
        g0 = gasleft();
        guard.todaySpent();
        uint256 todaySpentRead = g0 - gasleft();

        // External-call constant `_enforceGuard` pays to reach the guard (account→guard staticcall/call):
        // cold account access ~2,600 (first) then warm ~100. `_enforceGuard` makes up to two such calls
        // (todaySpent + recordSpend) per op.
        uint256 firstOpOverhead  = recordFirst + todaySpentRead + 2600 /*cold CALL todaySpent*/ + 100 /*warm CALL recordSpend*/;
        uint256 warmOpOverhead   = recordWarm + todaySpentRead + 100 + 100;

        emit log_named_uint("recordSpend first (cold 0->nonzero SSTORE)", recordFirst);
        emit log_named_uint("recordSpend warm  (nonzero->nonzero)",       recordWarm);
        emit log_named_uint("todaySpent() SLOAD read",                    todaySpentRead);
        emit log_named_uint("=> guard overhead / op, FIRST (+CALL const)", firstOpOverhead);
        emit log_named_uint("=> guard overhead / op, SUBSEQUENT",          warmOpOverhead);
        emit log_named_uint("as % of tier-1 101,948 (first) x1000",       firstOpOverhead * 1000 / 101948);
        emit log_named_uint("as % of tier-1 101,948 (subseq) x1000",      warmOpOverhead * 1000 / 101948);

        // Sanity bounds (not the deliverable — just to catch a broken measurement):
        assertGt(recordFirst, recordWarm, "cold SSTORE must cost more than warm");
        assertGt(recordFirst, 15000, "first-tx SSTORE should dominate");
    }
}
