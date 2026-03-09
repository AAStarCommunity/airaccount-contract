// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";

/// @dev Mock algorithm that always returns 0 (success)
contract MockAlgorithm is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Mock algorithm that always returns 1 (failure)
contract MockFailAlgorithm is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) {
        return 1;
    }
}

contract AAStarValidatorTest is Test {
    AAStarValidator public router;
    MockAlgorithm public mockAlg;
    MockFailAlgorithm public mockFailAlg;

    address owner = address(this);

    function setUp() public {
        router = new AAStarValidator();
        mockAlg = new MockAlgorithm();
        mockFailAlg = new MockFailAlgorithm();
    }

    // ─── Registration Tests ──────────────────────────────────────────

    function test_registerAlgorithm() public {
        router.registerAlgorithm(0x01, address(mockAlg));
        assertEq(router.getAlgorithm(0x01), address(mockAlg));
    }

    function test_registerAlgorithm_multipleIds() public {
        router.registerAlgorithm(0x01, address(mockAlg));
        router.registerAlgorithm(0x03, address(mockFailAlg));

        assertEq(router.getAlgorithm(0x01), address(mockAlg));
        assertEq(router.getAlgorithm(0x03), address(mockFailAlg));
        assertEq(router.getAlgorithm(0x02), address(0));
    }

    function test_registerAlgorithm_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarValidator.OnlyOwner.selector);
        router.registerAlgorithm(0x01, address(mockAlg));
    }

    function test_registerAlgorithm_cannotOverwrite() public {
        router.registerAlgorithm(0x01, address(mockAlg));

        vm.expectRevert(AAStarValidator.AlgorithmAlreadyRegistered.selector);
        router.registerAlgorithm(0x01, address(mockFailAlg));
    }

    function test_registerAlgorithm_zeroAddress() public {
        vm.expectRevert(AAStarValidator.InvalidAlgorithmAddress.selector);
        router.registerAlgorithm(0x01, address(0));
    }

    // ─── Validation Routing Tests ────────────────────────────────────

    function test_validateSignature_routesToAlgorithm() public {
        router.registerAlgorithm(0x01, address(mockAlg));

        // sig[0] = 0x01, rest = arbitrary data
        bytes memory sig = abi.encodePacked(uint8(0x01), bytes("somedata"));
        uint256 result = router.validateSignature(bytes32(0), sig);
        assertEq(result, 0); // success
    }

    function test_validateSignature_failingAlgorithm() public {
        router.registerAlgorithm(0x02, address(mockFailAlg));

        bytes memory sig = abi.encodePacked(uint8(0x02), bytes("somedata"));
        uint256 result = router.validateSignature(bytes32(0), sig);
        assertEq(result, 1); // failure
    }

    function test_validateSignature_unregisteredAlgId() public {
        bytes memory sig = abi.encodePacked(uint8(0xff), bytes("somedata"));
        vm.expectRevert(AAStarValidator.AlgorithmNotRegistered.selector);
        router.validateSignature(bytes32(0), sig);
    }

    function test_validateSignature_emptySignature() public {
        vm.expectRevert(AAStarValidator.EmptySignature.selector);
        router.validateSignature(bytes32(0), "");
    }

    // ─── Ownership Tests ─────────────────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = address(0xBEEF);
        router.transferOwnership(newOwner);
        assertEq(router.owner(), newOwner);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarValidator.OnlyOwner.selector);
        router.transferOwnership(address(0xBEEF));
    }

    function test_transferOwnership_zeroAddress() public {
        vm.expectRevert(AAStarValidator.InvalidAlgorithmAddress.selector);
        router.transferOwnership(address(0));
    }

    function test_newOwnerCanRegister() public {
        address newOwner = address(0xBEEF);
        router.transferOwnership(newOwner);

        vm.prank(newOwner);
        router.registerAlgorithm(0x01, address(mockAlg));
        assertEq(router.getAlgorithm(0x01), address(mockAlg));
    }
}
