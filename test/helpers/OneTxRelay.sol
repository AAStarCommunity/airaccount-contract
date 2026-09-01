// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

interface IValidatingAccount {
    function validateUserOp(PackedUserOperation calldata op, bytes32 opHash, uint256 missingFunds)
        external
        returns (uint256);
}

/// Runs validateUserOp and the account call in ONE top-level call, the way EntryPoint.handleOps does
/// on-chain.
///
/// SCOPE, so nobody builds on a promise this does not make: it mirrors handleOps' TRANSACTION
/// BOUNDARY and nothing else. It does NOT gate execution on `validationData` (a UserOp whose
/// validation returns 1 will still have its call executed here, where the real EntryPoint would
/// reject it), and it always passes `missingAccountFunds = 0`, so the prefund path in
/// AAStarAirAccountV7 (_payPrefund) is never exercised through it. Neither gap is observable in the
/// current tests -- adding `require(validationData == 0)` leaves the suite at 947 passed -- but a
/// future test of the form "an invalid signature must not execute" would PASS through this relay
/// while the call actually happened. Add the gate before writing that test, not after.
///
/// WHY THIS EXISTS: the account carries the validated algId (and the session-key scope tag) from
/// validateUserOp into execute() through EIP-1153 transient storage. That is safe on-chain because
/// both phases of a UserOp run inside one transaction. But foundry runs each TOP-LEVEL call from a
/// test as its own transaction -- unconditionally on 1.8.x, and on 1.7.1 whenever --gas-report is
/// passed -- so a test that calls validateUserOp and then execute as two separate top-level calls
/// loses the transient state between them. The symptom is `InsufficientTier(n, 0)`: provided = 0
/// because the algId never arrived, which reads like a broken tiering system and is not one. See
/// test/TransientAcrossTopLevelCalls.t.sol for the minimal demonstration.
///
/// The account gates execute() with onlyEntryPoint, so this must run AT the entryPoint address:
///
///     vm.etch(entryPoint, address(new OneTxRelay()).code);
///     OneTxRelay(entryPoint).run(address(account), op, opHash, abi.encodeCall(account.execute, (...)));
///
/// It holds no storage, so etching its runtime code is enough. Reverts from the account call are
/// bubbled with their original data, so vm.expectRevert on a specific selector still works.
///
/// WHERE TO ETCH IT -- the asymmetry across the suites is deliberate, do not "unify" it:
///   * AAStarAirAccountV7_M3.t.sol etches in setUp, because its entryPoint is a bare address (0xEE)
///     with no behaviour to preserve.
///   * CumulativeSignature / WeightedSignature / SessionKey etch INSIDE the one test that needs it,
///     as a PRECAUTION only: their entryPoint is a mock CONTRACT rather than a bare address. Measured
///     (pr-daemon), the precaution buys nothing today -- moving all three etches into setUp keeps
///     43/23/13 green, and even etching those mocks to empty code keeps them green, because no test
///     in those files ever calls a method on the mock; it is used purely as an address via
///     `vm.prank(address(ep))`. So today this is the same situation as M3's bare address, not a
///     different one. Keep the narrow scope for when that stops being true, but do not read the
///     asymmetry as evidence that unifying it would break something now.
///
/// ORDERING TRAP, worth knowing before you move an etch: `vm.expectRevert` applies to the very next
/// call, so deploying or etching the relay AFTER it consumes the expectation. The failure reads
/// "next call did not revert as expected" while the contract behaved perfectly correctly -- i.e. it
/// points the reader at the contract, which is the wrong place. Install the relay first.
contract OneTxRelay {
    function run(address account, PackedUserOperation calldata op, bytes32 opHash, bytes calldata accountCall)
        external
        returns (uint256 validationData, bytes memory ret)
    {
        validationData = IValidatingAccount(account).validateUserOp(op, opHash, 0);
        bool ok;
        (ok, ret) = account.call(accountCall);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
