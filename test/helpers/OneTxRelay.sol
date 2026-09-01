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
///     because their entryPoint is a shared MOCK CONTRACT. Etching that in setUp would replace its
///     code for every other test in the file.
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
