// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/// @title RailgunParser — ICalldataParser for Railgun V2.1 privacy pool transactions (M7.11)
/// @notice Parses Railgun shield/transact calldata to extract (tokenAddress, amount) for guard enforcement.
///
/// @dev ABI verified against Railgun-Community/engine src/abi/V2.1/RailgunSmartWallet.json
///      and confirmed via eth_abi encoding tests against deployed contracts.
///
///      ╔══════════════════════════════════════════════════════════════════════════╗
///      ║  MULTI-CHAIN DEPENDENCY: Railgun V2.1 RailgunSmartWallet (proxy)        ║
///      ║  Source: github.com/Railgun-Community/shared-models network-config.ts   ║
///      ║                                                                          ║
///      ║  Deployed chains and proxy addresses:                                   ║
///      ║  chainId 1       Ethereum: 0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9  ║
///      ║  chainId 56      BSC:      0x590162bf4b50f6576a459b75309ee21d92178a10  ║
///      ║  chainId 137     Polygon:  0x19b620929f97b7b990801496c3b361ca5def8c71  ║
///      ║  chainId 42161   Arbitrum: 0xFA7093CDD9EE6932B4eb2c9e1cde7CE00B1FA4b9  ║
///      ║  chainId 11155111 Sepolia: 0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea ║
///      ║  chainId 80002   Amoy:     0xD1aC80208735C7f963Da560C42d6BD82A8b175B5  ║
///      ║                                                                          ║
///      ║  NOT deployed on: Optimism, Base, or any other chain.                  ║
///      ║  Addresses are NOT CREATE2 deterministic — each chain is different.     ║
///      ║  Ethereum and Arbitrum share the same address (verified).               ║
///      ║                                                                          ║
///      ║  Function selectors are chain-agnostic (derived from ABI, same on all): ║
///      ║    shield()   = 0x044a40c3                                              ║
///      ║    transact() = 0xd8ae136a                                              ║
///      ╚══════════════════════════════════════════════════════════════════════════╝
///
///      Function signatures (V2.1):
///        shield(((bytes32,(uint8,address,uint256),uint120),(bytes32[3],bytes32))[])
///          selector: 0x044a40c3
///        transact((((uint256,uint256),(uint256[2],uint256[2]),(uint256,uint256)),bytes32,bytes32[],bytes32[],
///          (uint16,uint72,uint8,uint64,address,bytes32,(bytes32[4],bytes32,bytes32,bytes,bytes)[]),
///          (bytes32,(uint8,address,uint256),uint120))[])
///          selector: 0xd8ae136a
///
///      shield() calldata layout (after selector, 1 request):
///        [0:32]    = 0x20  (pointer to ShieldRequest[] array)
///        [32:64]   = 1     (array length)
///        [64:96]   = CommitmentPreimage.npk (bytes32 — random, NOT token address)
///        [96:128]  = tokenType (uint8, padded to 32)
///        [128:160] = tokenAddress  ← offset 128
///        [160:192] = tokenSubID (uint256)
///        [192:224] = value/amount  ← offset 192
///        [224:...]  = ShieldCiphertext (encryptedBundle[3] + shieldKey)
///        Minimum total calldata (after selector): 352 bytes
///
///      transact() calldata layout (after selector, 1 transaction):
///        [0:32]    = 0x20  (pointer to Transaction[] array)
///        [32:64]   = 1     (array length)
///        [64:96]   = 0x20  (offset to tx[0])
///        [96:352]  = SnarkProof (G1a + G2b + G1c = 8 × 32 bytes)
///        [352:384] = merkleRoot (bytes32)
///        [384:416] = offset to nullifiers[]
///        [416:448] = offset to commitments[]
///        [448:480] = offset to BoundParams
///        [480:512] = unshieldPreimage.npk (bytes32)
///        [512:544] = tokenType (uint8, padded to 32)
///        [544:576] = tokenAddress  ← offset 544
///        [576:608] = tokenSubID (uint256)
///        [608:640] = value/amount  ← offset 608
///        Minimum total calldata (after selector): 960 bytes
contract RailgunParser is ICalldataParser {
    // ─── Railgun V2.1 Selectors ──────────────────────────────────────────

    /// @dev shield(((bytes32,(uint8,address,uint256),uint120),(bytes32[3],bytes32))[])
    bytes4 internal constant RAILGUN_SHIELD   = 0x044a40c3;

    /// @dev transact((((uint256,uint256),(uint256[2],uint256[2]),(uint256,uint256)),bytes32,bytes32[],bytes32[],
    ///      (uint16,uint72,uint8,uint64,address,bytes32,(bytes32[4],bytes32,bytes32,bytes,bytes)[]),
    ///      (bytes32,(uint8,address,uint256),uint120))[])
    bytes4 internal constant RAILGUN_TRANSACT = 0xd8ae136a;

    // ─── ABI offsets (after selector) ───────────────────────────────────

    // shield(): single-request minimum (array header 64B + request 288B)
    uint256 internal constant SHIELD_MIN_LEN            = 352;
    uint256 internal constant SHIELD_TOKEN_ADDR_OFFSET  = 128;
    uint256 internal constant SHIELD_AMOUNT_OFFSET      = 192;

    // transact(): single-transaction minimum (array header 64B + tx 896B)
    uint256 internal constant TRANSACT_MIN_LEN           = 960;
    uint256 internal constant TRANSACT_TOKEN_ADDR_OFFSET = 544;
    uint256 internal constant TRANSACT_AMOUNT_OFFSET     = 608;

    // ─── ICalldataParser ─────────────────────────────────────────────────

    /// @notice Parse Railgun V2.1 calldata to extract (tokenAddress, amount).
    ///         Returns (address(0), 0) on unknown selector or parse failure.
    function parseTokenTransfer(bytes calldata data)
        external
        pure
        override
        returns (address tokenIn, uint256 amountIn)
    {
        if (data.length < 4) return (address(0), 0);
        bytes4 sel = bytes4(data[:4]);

        if (sel == RAILGUN_SHIELD)   return _parseShield(data[4:]);
        if (sel == RAILGUN_TRANSACT) return _parseTransact(data[4:]);
        return (address(0), 0);
    }

    // ─── Internal parsers ────────────────────────────────────────────────

    /// @dev shield(): tokenAddress at offset 128, amount at offset 192.
    ///      Minimum data length 352 bytes (after selector).
    function _parseShield(bytes calldata data) internal pure returns (address tok, uint256 amt) {
        if (data.length < SHIELD_MIN_LEN) return (address(0), 0);

        tok = address(uint160(uint256(bytes32(data[SHIELD_TOKEN_ADDR_OFFSET : SHIELD_TOKEN_ADDR_OFFSET + 32]))));
        amt = uint256(bytes32(data[SHIELD_AMOUNT_OFFSET : SHIELD_AMOUNT_OFFSET + 32]));

        if (tok == address(0) || amt == 0) return (address(0), 0);
    }

    /// @dev transact(): tokenAddress at offset 544, amount at offset 608.
    ///      Minimum data length 960 bytes (after selector).
    function _parseTransact(bytes calldata data) internal pure returns (address tok, uint256 amt) {
        if (data.length < TRANSACT_MIN_LEN) return (address(0), 0);

        tok = address(uint160(uint256(bytes32(data[TRANSACT_TOKEN_ADDR_OFFSET : TRANSACT_TOKEN_ADDR_OFFSET + 32]))));
        amt = uint256(bytes32(data[TRANSACT_AMOUNT_OFFSET : TRANSACT_AMOUNT_OFFSET + 32]));

        if (tok == address(0) || amt == 0) return (address(0), 0);
    }
}
