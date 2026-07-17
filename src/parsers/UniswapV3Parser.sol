// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/// @title UniswapV3Parser — ICalldataParser for Uniswap V3 SwapRouter
/// @notice Parses Uniswap V3 swap calldata to extract tokenIn + amountIn for guard enforcement.
///         The guard uses this to enforce tier/daily limits on Uniswap swaps, which otherwise
///         appear as value=0 ETH transactions and would bypass token tier checks.
///
/// @dev Supported selectors:
///      - exactInputSingle (0x414bf389): single-hop swap with exact input
///        struct ExactInputSingleParams {
///            address tokenIn;        // offset 4
///            address tokenOut;       // offset 36
///            uint24 fee;             // offset 68
///            address recipient;      // offset 100 (padded to 32 bytes)
///            uint256 deadline;       // offset 132
///            uint256 amountIn;       // offset 164
///            uint256 amountOutMin;   // offset 196
///            uint160 sqrtPriceLimitX96; // offset 228
///        }
///        → returns (tokenIn, amountIn)
///
///      - exactInput (0xc04b8d59): multi-hop swap with exact input
///        struct ExactInputParams {
///            bytes path;             // ABI-encoded, tokenIn is the first 20 bytes of path
///            address recipient;
///            uint256 deadline;
///            uint256 amountIn;
///            uint256 amountOutMin;
///        }
///        → returns (tokenIn from path[0:20], amountIn)
///        Note: path is ABI-encoded as dynamic bytes; amountIn is at a fixed structural offset.
///
///      Returns (address(0), 0) for unrecognized selectors.
contract UniswapV3Parser is ICalldataParser {
    // ─── Selectors ───────────────────────────────────────────────────

    bytes4 internal constant EXACT_INPUT_SINGLE = 0x414bf389;
    // SCOPE: this is the CLASSIC SwapRouter `exactInput((bytes,address,uint256,uint256,uint256))` (5-field
    // ExactInputParams, WITH deadline). SwapRouter02 dropped `deadline` → its `exactInput` is a DIFFERENT
    // signature/selector (0xb858183f, amountIn at struct base+64 not +96). Because this constant only
    // matches 0xc04b8d59, a SwapRouter02 call does NOT match and falls to (0,0) → guard fail-closed (it is
    // NOT mis-decoded). Register this parser only against a classic SwapRouter; a SwapRouter02 parser needs
    // its own decoder. (#194 review scope note.)
    bytes4 internal constant EXACT_INPUT        = 0xc04b8d59;

    // ─── ICalldataParser ─────────────────────────────────────────────

    /// @inheritdoc ICalldataParser
    function parseTokenTransfer(bytes calldata data)
        external
        pure
        override
        returns (address token, uint256 amount)
    {
        if (data.length < 4) return (address(0), 0);

        bytes4 sel = bytes4(data[:4]);

        if (sel == EXACT_INPUT_SINGLE) {
            return _parseExactInputSingle(data);
        }

        if (sel == EXACT_INPUT) {
            return _parseExactInput(data);
        }

        return (address(0), 0);
    }

    // ─── Internal ────────────────────────────────────────────────────

    /// @dev exactInputSingle: fixed-layout struct, tokenIn at offset 4, amountIn at offset 164
    ///      Minimum data length: 4 (selector) + 8*32 (params) = 260 bytes
    function _parseExactInputSingle(bytes calldata data) internal pure returns (address token, uint256 amount) {
        if (data.length < 260) return (address(0), 0);
        // tokenIn: first parameter (address, padded to 32 bytes)
        token = address(uint160(uint256(bytes32(data[4:36]))));
        // amountIn: sixth parameter (5 params × 32 bytes after selector = offset 164)
        amount = uint256(bytes32(data[164:196]));
    }

    /// @dev exactInput: ABI-encoded with dynamic bytes path field.
    ///      ABI layout (tuple with dynamic bytes):
    ///        offset 4: tuple offset (= 32, since tuple starts right away)
    ///        offset 36: path offset within tuple (= 160, since 5 fixed fields before path... wait)
    ///
    ///      Actually Uniswap's ExactInputParams has path as first field:
    ///        struct ExactInputParams { bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMin; }
    ///
    ///      ABI encoding with path as dynamic bytes:
    ///        [4 selector]
    ///        [32 offset to tuple = 32]
    ///        [32 path offset within tuple = 160 (4 fixed words before path end + path data)]
    ///        ... actually ABI encodes differently for dynamic types.
    ///
    ///      Standard ABI encoding of ExactInputParams:
    ///        word 0 (offset 4):  offset to path data = 0xa0 (160) — 5 slots for path_offset, recipient, deadline, amountIn, amountOutMin
    ///        word 1 (offset 36): recipient (address, padded)
    ///        word 2 (offset 68): deadline
    ///        word 3 (offset 100): amountIn
    ///        word 4 (offset 132): amountOutMin
    ///        word 5 (offset 164): path.length
    ///        bytes  (offset 196): path data (tokenIn is first 20 bytes)
    ///
    ///      Minimum data: 4 + 5*32 (fixed) + 32 (path length) + 43 (min path: 20+3+20) = 235 bytes
    /// @dev exactInput(ExactInputParams). Because the struct has a dynamic `bytes path`, the whole
    ///      struct is a DYNAMIC tuple — the calldata is [selector][top-level offset to struct][struct…].
    ///      H3/#194: the prior code OMITTED the top-level struct-offset word, so it read `deadline` as
    ///      amountIn and mis-located the path. Correct layout (base = 4 + structOffset, normally 36):
    ///        struct head @ base : [path-offset][recipient][deadline][amountIn][amountOutMin]
    ///        so amountIn @ base+96 ; path.length @ base + path-offset ; tokenIn = path[0:20].
    ///      Bounds use the subtraction form (x > len - k) to avoid checked-arith overflow on hostile
    ///      offsets; returns (0,0) on any malformed/short input (never reverts — ICalldataParser contract).
    function _parseExactInput(bytes calldata data) internal pure returns (address token, uint256 amount) {
        uint256 len = data.length;
        if (len < 36) return (address(0), 0);

        uint256 structOff = uint256(bytes32(data[4:36]));            // top-level offset to struct data
        // struct head is 5 words (160 bytes); need base + 160 within bounds.
        if (structOff > len - 4 || len - 4 - structOff < 160) return (address(0), 0);
        uint256 base = 4 + structOff;

        amount = uint256(bytes32(data[base + 96 : base + 128]));     // amountIn (4th struct field)

        uint256 pathOff = uint256(bytes32(data[base : base + 32]));  // path offset within the struct
        if (pathOff > len - base || len - base - pathOff < 32) return (address(0), 0);
        uint256 pathLenOff = base + pathOff;
        uint256 pathLen = uint256(bytes32(data[pathLenOff : pathLenOff + 32]));
        uint256 pathStart = pathLenOff + 32;
        if (pathLen < 20 || pathStart > len || len - pathStart < 20) return (address(0), 0);

        token = address(bytes20(data[pathStart : pathStart + 20])); // tokenIn = first 20 bytes of path
    }
}
