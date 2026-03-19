// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title ICalldataParser — Interface for DeFi protocol calldata interpreters
/// @notice Implemented by protocol-specific parsers that extract the effective
///         token address and amount from complex protocol calldata.
///
/// @dev The AirAccount guard only natively understands ERC20 transfer/approve.
///      For DeFi protocols (Uniswap, Aave, Curve, etc.), calldata encodes token
///      flows differently. A parser translates protocol calldata into the
///      (token, amount) pair the guard uses for tier enforcement.
///
///      Parser responsibilities:
///      - Parse the INCOMING token (what the user is spending) from calldata
///      - Return (address(0), 0) if the calldata is unrecognized or non-token
///      - Must be a pure function (stateless, no storage reads)
///
///      Example: Uniswap V3 exactInputSingle(ExactInputSingleParams)
///        tokenIn at offset 4, amountIn at offset 164
///        → returns (tokenIn, amountIn)
interface ICalldataParser {
    /// @notice Parse calldata to extract the effective token address and spend amount.
    /// @param  data Full calldata of the external call (includes 4-byte selector)
    /// @return token  ERC20 token address being spent (address(0) = not applicable)
    /// @return amount Amount of token being spent in token native units (0 = not applicable)
    function parseTokenTransfer(bytes calldata data)
        external
        pure
        returns (address token, uint256 amount);
}
