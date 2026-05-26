// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AirAccountDelegate} from "../src/core/AirAccountDelegate.sol";
import {AirAccountExtension} from "../src/core/AirAccountExtension.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title Eip170SizeTest
/// @notice Guards against deploy-blocking contract-size regressions.
///         Foundry's test EVM disables the EIP-170 runtime code-size limit, so a contract
///         that exceeds 24,576 bytes still "deploys" in tests — but a real chain (Sepolia,
///         mainnet) rejects it, making the contract undeployable. These tests assert the
///         limit explicitly so the problem is caught in `forge test` / CI, not at deploy time.
contract Eip170SizeTest is Test {
    /// @dev EIP-170 runtime code-size limit.
    uint256 internal constant EIP170_LIMIT = 24_576;

    function _runtimeSize(address a) internal view returns (uint256) {
        return a.code.length;
    }

    function test_AAStarAirAccountV7_under_eip170() public {
        uint256 size = _runtimeSize(address(new AAStarAirAccountV7()));
        emit log_named_uint("AAStarAirAccountV7 runtime size", size);
        assertLe(size, EIP170_LIMIT, "AAStarAirAccountV7 exceeds EIP-170 (undeployable on real chains)");
    }

    function test_AAStarAirAccountFactoryV7_under_eip170() public {
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        uint256 size = _runtimeSize(address(new AAStarAirAccountFactoryV7(
            address(0xEE), address(0), noTokens, noConfigs, address(0), address(0)
        )));
        emit log_named_uint("AAStarAirAccountFactoryV7 runtime size", size);
        assertLe(size, EIP170_LIMIT, "Factory exceeds EIP-170");
    }

    function test_AirAccountDelegate_under_eip170() public {
        uint256 size = _runtimeSize(address(new AirAccountDelegate()));
        emit log_named_uint("AirAccountDelegate runtime size", size);
        assertLe(size, EIP170_LIMIT, "AirAccountDelegate exceeds EIP-170");
    }

    /// @dev The diamond-lite cold-function facet (agent + weight governance). Reached by the
    ///      account via fallback + delegatecall; must also fit under EIP-170 to be deployable.
    function test_AirAccountExtension_under_eip170() public {
        uint256 size = _runtimeSize(address(new AirAccountExtension()));
        emit log_named_uint("AirAccountExtension runtime size", size);
        assertLe(size, EIP170_LIMIT, "AirAccountExtension exceeds EIP-170");
    }
}
