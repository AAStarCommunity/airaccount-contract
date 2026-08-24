// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title RepCreditCounter
/// @notice Minimal non-token application target for the RepCredit evidence run.
contract RepCreditCounter {
    uint256 public number;

    event Incremented(address indexed caller, uint256 value);

    function increment() external {
        unchecked {
            ++number;
        }
        emit Incremented(msg.sender, number);
    }
}
