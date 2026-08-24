// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {RepCreditCounter} from "./mocks/RepCreditCounter.sol";

contract RepCreditCounterTest is Test {
    RepCreditCounter internal counter;

    function setUp() public {
        counter = new RepCreditCounter();
    }

    function test_increment_recordsCallerAndValue() public {
        address caller = address(0xA11CE);
        vm.expectEmit(true, false, false, true, address(counter));
        emit RepCreditCounter.Incremented(caller, 1);
        vm.prank(caller);
        counter.increment();
        assertEq(counter.number(), 1);
    }
}
