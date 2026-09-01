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
///       -> tload after a separate top-level call: 99
///     ... same command with --gas-report
///       -> tload after a separate top-level call: 0
///
/// Three states, three distinct numbers: 99 healthy, 0 the harness split the calls, 42 the cross-call
/// write did nothing and you are reading the control's residue. That third reading used to collide
/// with the healthy one.
///
/// So `--gas-report` makes 1.7.1 run each top-level call as its own transaction, clearing transient
/// storage between them; 1.8.x does that unconditionally, which is why CI is pinned to 1.7.1 (see
/// .github/workflows/test.yml). It is a harness artifact, NOT a real sensitivity of EIP-1153 across
/// frames and NOT a contract defect: the on-chain assumption is untouched.
///
/// The CROSS-CALL value is deliberately not asserted -- it legitimately differs by mode, so asserting
/// either reading would fail in one of the two modes this exists to compare. The same-frame control
/// IS asserted, because it must hold in all of them.
///
/// Why the control matters more than it looks: on 1.7.1 you can tell a healthy probe from a broken one
/// by running twice (healthy prints 99 then 0; broken prints 0 twice). **On 1.8.x that stops working**
/// -- the split is unconditional, so a healthy probe prints 0 both times, which is byte-identical to
/// the broken signature. And 1.8.x is what someone hitting this in the wild is running. The control
/// removes the need for a second run entirely.
///
/// UNVERIFIED PREMISE, stated rather than assumed: that the control still reads 42 on 1.8.x rests on
/// 1.8.x splitting only TOP-LEVEL calls, sub-calls within one staying in the same transaction. Nobody
/// here has measured that -- it is the same premise this file's conclusion already depends on. One
/// command settles it on any machine with 1.8.x: if the control reads 0 there, this comment is wrong
/// AND the shared premise needs re-examining, which is the more valuable outcome.
contract TStoreProbe {
    function put(uint256 v) external { assembly { tstore(7, v) } }
    function get() external view returns (uint256 v) { assembly { v := tload(7) } }

    /// Same-frame control: the identical two sub-calls, same slot, same shapes -- but both inside ONE
    /// top-level call. That isolates the single variable under test (the top-level call boundary), so
    /// it must read 42 in EVERY mode. If it does not, the probe itself has rotted (slot renumbered on
    /// one side, transient storage unavailable, --evm-version not applied, solc semantics changed) and
    /// the reading below says nothing about foundry.
    function putThenGet(uint256 v) external returns (uint256) {
        this.put(v);
        return this.get();
    }
}

contract TransientAcrossTopLevelCalls is Test {
    function test_probe() public {
        TStoreProbe t = new TStoreProbe();

        // Assertable in every mode, so a single run is self-explanatory and the file is a check
        // rather than a log line: control 42 + probe 0 means the harness split the calls; control 0
        // means the probe is broken and the probe reading is meaningless.
        assertEq(t.putThenGet(42), 42, "same-frame control failed: this probe is broken, not foundry");

        // SENTINEL, not 42: the control just wrote 42 to this same slot. Reusing that value makes a
        // healthy read indistinguishable from reading the control's residue -- delete the line below
        // and the file still prints 42, so the positive claim would no longer be produced by the thing
        // it claims about. Same slot and same call shapes are kept on purpose (that is what isolates
        // the top-level boundary as the only variable); only the VALUE differs.
        t.put(99);
        emit log_named_uint("tload after a separate top-level call", t.get());
        emit log_string("99 = the cross-call write survived | 0 = harness split the top-level calls | 42 = that write did nothing (you are reading the control's residue)");
    }
}
