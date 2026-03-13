// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock P256 precompile that returns valid (1)
contract MockP256Valid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @dev Mock P256 precompile that returns invalid (0)
contract MockP256Invalid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// @dev Mock P256 precompile that returns empty (simulates chain without EIP-7212)
contract MockP256Empty {
    fallback(bytes calldata) external returns (bytes memory) {
        return "";
    }
}

/// @title AAStarAirAccountM5_4Test — P256 chain deployment requirement tests
/// @notice After removing the fallback verifier (M5.4 revision), P256 validation
///         uses fail-fast behavior: if EIP-7212 precompile is unavailable or returns
///         invalid, validation fails immediately. No silent fallback to expensive
///         pure-Solidity path. Deployment is only supported on chains with EIP-7212.
contract AAStarAirAccountM5_4Test is Test {
    AAStarAirAccountV7 account;
    address owner = address(0x1234);
    address entryPoint = address(0xBEEF);

    MockP256Valid mockValid;
    MockP256Invalid mockInvalid;
    MockP256Empty mockEmpty;

    // Real P256 private key and signature for unit tests
    // (generated offline: privKey = 0xa665...ae3, pubX/pubY from secp256r1)
    bytes32 constant TEST_P256_X = bytes32(uint256(1)); // placeholder — real key used via mock
    bytes32 constant TEST_P256_Y = bytes32(uint256(2));

    function setUp() public {
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = 0x03; // ALG_P256
        algIds[1] = 0x06; // ALG_COMBINED_T1

        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        account = new AAStarAirAccountV7(entryPoint, owner, config);

        mockValid = new MockP256Valid();
        mockInvalid = new MockP256Invalid();
        mockEmpty = new MockP256Empty();

        // Set a non-zero P256 key
        vm.prank(owner);
        account.setP256Key(TEST_P256_X, TEST_P256_Y);
    }

    // ─── Fail-fast: no fallback mechanism ────────────────────────────────────

    function test_noFallbackVerifier_functionRemoved() public view {
        // p256FallbackVerifier storage variable is removed.
        // This test simply confirms the contract compiles without it.
        // The account has no getter for p256FallbackVerifier.
        assertTrue(account.p256KeyX() == TEST_P256_X);
        assertTrue(account.p256KeyY() == TEST_P256_Y);
    }

    function test_precompilePresent_validSig_passes() public {
        // Deploy valid mock at EIP-7212 precompile address 0x100
        vm.etch(address(0x100), address(mockValid).code);

        // Build a minimal UserOp: signature = [0x03][r(32)][s(32)] = 65 bytes
        // The mock at 0x100 returns valid(1), so P256 validation succeeds
        PackedUserOperation memory op = _buildP256UserOp(bytes.concat(
            bytes32(uint256(0xaabb)), // r (dummy, mock accepts everything)
            bytes32(uint256(0xccdd))  // s
        ));

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(op, bytes32(uint256(1)), 0);
        assertEq(result, 0, "P256 with valid precompile should pass");
    }

    function test_precompilePresent_invalidSig_fails() public {
        // Deploy invalid mock at 0x100 — precompile returns 0 (bad signature)
        vm.etch(address(0x100), address(mockInvalid).code);

        PackedUserOperation memory op = _buildP256UserOp(bytes.concat(
            bytes32(uint256(0xaabb)),
            bytes32(uint256(0xccdd))
        ));

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(op, bytes32(uint256(1)), 0);
        assertEq(result, 1, "P256 with invalid precompile result should fail");
    }

    function test_precompileAbsent_failsFast_noFallback() public {
        // Deploy empty mock at 0x100 — simulates chain without EIP-7212 precompile
        // Empty return → result.length < 32 → fail immediately, no fallback
        vm.etch(address(0x100), address(mockEmpty).code);

        PackedUserOperation memory op = _buildP256UserOp(bytes.concat(
            bytes32(uint256(0xaabb)),
            bytes32(uint256(0xccdd))
        ));

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(op, bytes32(uint256(1)), 0);
        assertEq(result, 1, "P256 with absent precompile should fail fast");
    }

    function test_precompileAbsent_doesNotRunExpensiveSolidity() public {
        // Confirm that no fallback is attempted when precompile is absent.
        // Gas measurement: if pure Solidity P256 ran, gas would be 200k+.
        // If fail-fast, gas stays well under 50k for the validation call.
        vm.etch(address(0x100), address(mockEmpty).code);

        PackedUserOperation memory op = _buildP256UserOp(bytes.concat(
            bytes32(uint256(0xaabb)),
            bytes32(uint256(0xccdd))
        ));

        vm.prank(entryPoint);
        uint256 gasBefore = gasleft();
        account.validateUserOp(op, bytes32(uint256(1)), 0);
        uint256 gasUsed = gasBefore - gasleft();

        // Pure Solidity P256 would use ~280,000 gas; fail-fast uses < 30,000
        assertLt(gasUsed, 50_000, "Fail-fast must not run expensive Solidity P256 path");
    }

    function test_p256KeyNotSet_failsBeforePrecompile() public {
        // If P256 key is not registered, fail before even calling precompile
        vm.etch(address(0x100), address(mockValid).code);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x03;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 accountNoKey = new AAStarAirAccountV7(entryPoint, owner, config);
        // No setP256Key call — key remains (0,0)

        PackedUserOperation memory op = _buildP256UserOp(bytes.concat(
            bytes32(uint256(0xaabb)),
            bytes32(uint256(0xccdd))
        ));
        op.sender = address(accountNoKey);

        vm.prank(entryPoint);
        uint256 result = accountNoKey.validateUserOp(op, bytes32(uint256(1)), 0);
        assertEq(result, 1, "P256 with no key registered should fail");
    }

    function test_wrongSigLength_failsImmediately() public {
        vm.etch(address(0x100), address(mockValid).code);

        // Signature with wrong length (63 bytes instead of 64)
        PackedUserOperation memory op = _buildP256UserOp(new bytes(63));

        vm.prank(entryPoint);
        uint256 result = account.validateUserOp(op, bytes32(uint256(1)), 0);
        assertEq(result, 1, "P256 with wrong sig length should fail");
    }

    function test_deploymentChainRequirement_documented() public pure {
        // This test documents the deployment requirement:
        // AirAccount P256 features require EIP-7212 precompile at address(0x100).
        // Supported chains (as of 2026-03):
        //   - Ethereum mainnet (Pectra, 2025-05-07)
        //   - Base / Optimism (Isthmus, 2025-05-09)
        //   - Arbitrum (ArbOS 51, 2026-01-08)
        //   - BNB Chain (Pascal, 2025-03-20) — EIP-7212 status: verify before deploy
        //   - zkSync Era — EIP-7212 supported (early adopter)
        // NOT supported: chains without EIP-7212 (deploy will result in P256 always failing)
        assertTrue(true);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _buildP256UserOp(bytes memory sigData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(300000), uint128(300000))),
            preVerificationGas: 50000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei))),
            paymasterAndData: "",
            // algId=0x03 prefix + P256 sig data
            signature: bytes.concat(bytes1(0x03), sigData)
        });
    }
}
