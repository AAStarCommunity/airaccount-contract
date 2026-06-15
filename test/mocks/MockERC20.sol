// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20 — test token for the v0.18 E2E per-asset guard scenario (S-B3).
/// @dev Public `mint` so the E2E harness can fund test accounts. NOT for production.
contract MockERC20 is ERC20 {
    constructor() ERC20("AAStar E2E Test Token", "E2ET") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
