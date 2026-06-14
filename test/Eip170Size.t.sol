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
///         Foundry's test EVM disables the EIP-170 runtime code-size limit AND the EIP-3860
///         initcode limit, so a contract that exceeds them still "deploys" in tests — but a real
///         chain (Sepolia, mainnet) rejects it, making the contract undeployable. These tests
///         assert both limits explicitly so the problem is caught in `forge test` / CI, not at
///         deploy time.
/// @dev EIP-3860 (Shanghai) caps the initcode passed to CREATE/CREATE2 at 49,152 bytes. The
///      factory is deployed by a normal creation transaction whose initcode = creationCode ++
///      abi.encode(constructor args); if that exceeds 49,152 the factory cannot be deployed on a
///      post-Shanghai chain. WS-E #82's uint128 TokenConfig packing pushed the factory initcode to
///      the brink (the inline `new AAStarAirAccountV7()` embedded ~14 KB of impl creation code);
///      injecting the implementation address fixed it. This assertion locks the fix in.
contract Eip170SizeTest is Test {
    /// @dev EIP-170 runtime code-size limit.
    uint256 internal constant EIP170_LIMIT = 24_576;
    /// @dev EIP-3860 initcode (creation-code) size limit for CREATE / CREATE2.
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    function _runtimeSize(address a) internal view returns (uint256) {
        return a.code.length;
    }

    function test_AAStarAirAccountV7_under_eip170() public {
        uint256 size = _runtimeSize(address(new AAStarAirAccountV7()));
        emit log_named_uint("AAStarAirAccountV7 runtime size", size);
        assertLe(size, EIP170_LIMIT, "AAStarAirAccountV7 exceeds EIP-170 (undeployable on real chains)");
    }

    function test_AAStarAirAccountFactoryV7_under_eip170() public {
        // #82 EIP-3860 fix: deploy the implementation first, then inject it (factory no longer
        // deploys the impl inline).
        address impl = address(new AAStarAirAccountV7());
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        uint256 size = _runtimeSize(address(new AAStarAirAccountFactoryV7(
            impl, address(0xEE), address(0), noTokens, noConfigs
        )));
        emit log_named_uint("AAStarAirAccountFactoryV7 runtime size", size);
        assertLe(size, EIP170_LIMIT, "Factory exceeds EIP-170");
    }

    /// @notice EIP-3860: the factory's full initcode (creationCode ++ encoded constructor args)
    ///         must be ≤ 49,152 bytes, or the factory cannot be deployed on a post-Shanghai chain.
    ///         Regression guard for WS-E #82 — the implementation-injection fix must hold.
    function test_AAStarAirAccountFactoryV7_initcode_under_eip3860() public {
        // Mirror the real deploy-tx args (empty default-token arrays = the chain-portable default).
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        bytes memory initcode = abi.encodePacked(
            type(AAStarAirAccountFactoryV7).creationCode,
            abi.encode(address(0xEE), address(0xEE), address(0), noTokens, noConfigs)
        );
        emit log_named_uint("AAStarAirAccountFactoryV7 initcode size", initcode.length);
        emit log_named_uint("EIP-3860 headroom (bytes)", EIP3860_INITCODE_LIMIT - initcode.length);
        assertLe(
            initcode.length,
            EIP3860_INITCODE_LIMIT,
            "Factory initcode exceeds EIP-3860 (undeployable via CREATE/CREATE2 on post-Shanghai chains)"
        );
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
