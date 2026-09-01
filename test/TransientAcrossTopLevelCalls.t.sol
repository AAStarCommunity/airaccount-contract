// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

/// Diagnostic probe for a foundry harness artifact that looks exactly like a broken tiering system.
///
/// SYMPTOM it explains: six tier tests fail with `InsufficientTier(n, 0)` under `--gas-report` (and,
/// on foundry 1.8.x, without any flag at all). `provided = 0` means AlgTierLib received an algId it
/// does not know -- because the algId never arrived. The account carries it from validateUserOp into
/// execute() through EIP-1153 transient storage, which on-chain is safe: both phases of a UserOp run
/// inside ONE transaction.
///
/// WHAT THIS PROBE SHOWS: the harness does not always agree. No contract of ours is involved -- two
/// top-level calls in one test function, a tstore and a tload. Measured on foundry 1.7.1:
///
///     forge test --match-path test/TransientAcrossTopLevelCalls.t.sol --evm-version prague
///       -> tload after a separate top-level call: 42
///     ... same command with --gas-report
///       -> tload after a separate top-level call: 0
///
/// So `--gas-report` makes 1.7.1 run each top-level call as its own transaction, clearing transient
/// storage between them; 1.8.x does that unconditionally, which is why CI is pinned to 1.7.1 (see
/// .github/workflows/test.yml). It is a harness artifact, NOT a real sensitivity of EIP-1153 across
/// frames and NOT a contract defect: the on-chain assumption is untouched.
///
/// This test asserts nothing on purpose -- the value it prints IS the answer, and asserting either
/// reading would make it fail in one of the two modes it exists to compare.
contract TStoreProbe {
    function put(uint256 v) external { assembly { tstore(7, v) } }
    function get() external view returns (uint256 v) { assembly { v := tload(7) } }
}

contract TransientAcrossTopLevelCalls is Test {
    function test_probe() public {
        TStoreProbe t = new TStoreProbe();
        t.put(42);
        emit log_named_uint("tload after a separate top-level call", t.get());
        emit log_string("42 = transient survived (plain forge test) | 0 = harness split the calls (--gas-report, or foundry 1.8.x)");
    }
}
