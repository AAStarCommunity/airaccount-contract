// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CalldataParserRegistry} from "../src/core/CalldataParserRegistry.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";
import {ICalldataParser} from "../src/interfaces/ICalldataParser.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";

/// @title CalldataParserTest — Unit tests for M6.6b CalldataParser + Registry
contract CalldataParserTest is Test {
    CalldataParserRegistry public registry;
    UniswapV3Parser         public uniParser;

    address public owner;
    address public other;

    // Uniswap V3 SwapRouter address (Sepolia — doesn't matter for unit tests)
    address public constant UNI_ROUTER = address(0x1234CAFE);
    // Token addresses
    address public constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Uniswap V3 selectors
    bytes4 constant EXACT_INPUT_SINGLE = 0x414bf389;
    bytes4 constant EXACT_INPUT        = 0xc04b8d59;

    function setUp() public {
        owner  = address(this);
        other  = address(0xBAD1);

        registry  = new CalldataParserRegistry();
        uniParser = new UniswapV3Parser();
    }

    // ─── CalldataParserRegistry ───────────────────────────────────────

    function test_registry_registerParser_success() public {
        registry.registerParser(UNI_ROUTER, address(uniParser));
        assertEq(registry.getParser(UNI_ROUTER), address(uniParser));
    }

    function test_registry_getParser_nonexistent_returnsZero() public view {
        assertEq(registry.getParser(address(0x9999)), address(0));
    }

    function test_registry_registerParser_duplicate_reverts() public {
        registry.registerParser(UNI_ROUTER, address(uniParser));

        vm.expectRevert(CalldataParserRegistry.ParserAlreadyRegistered.selector);
        registry.registerParser(UNI_ROUTER, address(uniParser));
    }

    function test_registry_registerParser_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert(CalldataParserRegistry.OnlyOwner.selector);
        registry.registerParser(UNI_ROUTER, address(uniParser));
    }

    function test_registry_registerParser_zeroAddr_reverts() public {
        vm.expectRevert(CalldataParserRegistry.InvalidAddress.selector);
        registry.registerParser(address(0), address(uniParser));

        vm.expectRevert(CalldataParserRegistry.InvalidAddress.selector);
        registry.registerParser(UNI_ROUTER, address(0));
    }

    function test_registry_transferOwnership_success() public {
        registry.transferOwnership(other);
        assertEq(registry.owner(), other);
    }

    function test_registry_transferOwnership_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert(CalldataParserRegistry.OnlyOwner.selector);
        registry.transferOwnership(other);
    }

    // ─── UniswapV3Parser — exactInputSingle ───────────────────────────

    /// @dev Build exactInputSingle calldata
    ///      struct ExactInputSingleParams: tokenIn, tokenOut, fee, recipient, deadline, amountIn, amountOutMin, sqrtPriceLimitX96
    function _buildExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        address recipient,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMin,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            EXACT_INPUT_SINGLE,
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountIn,
            amountOutMin,
            sqrtPriceLimitX96
        );
    }

    function test_uniswapParser_exactInputSingle_correctToken() public view {
        bytes memory data = _buildExactInputSingle(
            USDC, WETH, 3000, address(0xdead), block.timestamp, 1000e6, 0, 0
        );
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, USDC);
        assertEq(amount, 1000e6);
    }

    function test_uniswapParser_exactInputSingle_zeroAmount() public view {
        bytes memory data = _buildExactInputSingle(
            USDC, WETH, 3000, address(0xdead), block.timestamp, 0, 0, 0
        );
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, USDC);
        assertEq(amount, 0);
    }

    function test_uniswapParser_exactInputSingle_tooShort_returnsZero() public view {
        bytes memory data = new bytes(100); // too short (need 260)
        data[0] = bytes1(EXACT_INPUT_SINGLE[0]);
        data[1] = bytes1(EXACT_INPUT_SINGLE[1]);
        data[2] = bytes1(EXACT_INPUT_SINGLE[2]);
        data[3] = bytes1(EXACT_INPUT_SINGLE[3]);
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, address(0));
        assertEq(amount, 0);
    }

    // ─── UniswapV3Parser — exactInput (multi-hop) ─────────────────────

    /// @dev Build exactInput calldata
    ///      struct ExactInputParams: path, recipient, deadline, amountIn, amountOutMin
    ///      path = tokenIn(20) + fee(3) + tokenOut(20) for a single-hop
    function _buildExactInput(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        address recipient,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal pure returns (bytes memory) {
        bytes memory path = abi.encodePacked(tokenIn, fee, tokenOut);
        return abi.encodeWithSelector(
            EXACT_INPUT,
            path,
            recipient,
            deadline,
            amountIn,
            amountOutMin
        );
    }

    function test_uniswapParser_exactInput_correctToken() public view {
        bytes memory data = _buildExactInput(
            USDC, WETH, 3000, address(0xdead), block.timestamp, 500e6, 0
        );
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, USDC);
        assertEq(amount, 500e6);
    }

    // ─── UniswapV3Parser — unknown selector ───────────────────────────

    function test_uniswapParser_unknownSelector_returnsZero() public view {
        bytes memory data = abi.encodeWithSelector(bytes4(0xDEADBEEF), uint256(1000));
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, address(0));
        assertEq(amount, 0);
    }

    function test_uniswapParser_emptyCalldata_returnsZero() public view {
        (address token, uint256 amount) = uniParser.parseTokenTransfer(new bytes(0));
        assertEq(token, address(0));
        assertEq(amount, 0);
    }

    // ─── Integration: account uses parser registry ────────────────────

    function test_setParserRegistry_ownerOnly() public {
        // Setup minimal account
        address entryPoint = address(0xEEEE);
        address guardianAddr = address(0xBEEF01);
        address guardianAddr2 = address(0xBEEF02);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02; // ECDSA
        address[3] memory guardians;
        guardians[0] = guardianAddr;
        guardians[1] = guardianAddr2;
        address[] memory emptyTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory emptyCfgs = new AAStarGlobalGuard.TokenConfig[](0);

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: emptyTokens,
            initialTokenConfigs: emptyCfgs
        });

        address accountOwner = address(this);
        AAStarAirAccountV7 acct = new AAStarAirAccountV7(entryPoint, accountOwner, cfg);

        // Initially no parser registry
        assertEq(acct.parserRegistry(), address(0));

        // Owner sets registry
        acct.setParserRegistry(address(registry));
        assertEq(acct.parserRegistry(), address(registry));

        // Non-owner cannot set registry
        vm.prank(other);
        vm.expectRevert();
        acct.setParserRegistry(address(0));
    }

    function test_setParserRegistry_emitsEvent() public {
        address entryPoint = address(0xEEEE);
        address guardianAddr = address(0xBEEF01);
        address guardianAddr2 = address(0xBEEF02);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02;
        address[3] memory guardians;
        guardians[0] = guardianAddr;
        guardians[1] = guardianAddr2;
        address[] memory emptyTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory emptyCfgs = new AAStarGlobalGuard.TokenConfig[](0);

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: emptyTokens,
            initialTokenConfigs: emptyCfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(0xEEEE), address(this), cfg);

        vm.expectEmit(true, false, false, false);
        emit AAStarAirAccountBase.ParserRegistrySet(address(registry));
        acct.setParserRegistry(address(registry));
    }

    // ─── Integration: _enforceGuard uses parser for DeFi calldata ─────

    function test_enforceGuard_usesParser_forUniswapCalldata() public {
        // Deploy a real account
        address accountOwner = address(this);
        address guardianAddr  = address(0xBEEF01);
        address guardianAddr2 = address(0xBEEF02);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02; // ECDSA

        // Configure USDC token with tier limits
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        AAStarGlobalGuard.TokenConfig[] memory tokenCfgs = new AAStarGlobalGuard.TokenConfig[](1);
        tokenCfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 500e6,    // 500 USDC max for ECDSA (Tier 1)
            tier2Limit: 5000e6,   // 5000 USDC for P256+BLS
            dailyLimit: 10000e6   // 10000 USDC daily cap
        });

        address[3] memory guardians;
        guardians[0] = guardianAddr;
        guardians[1] = guardianAddr2;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: tokenCfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(0xEEEE), accountOwner, cfg);

        // Register the Uniswap parser
        registry.registerParser(UNI_ROUTER, address(uniParser));
        acct.setParserRegistry(address(registry));

        // Build a Uniswap exactInputSingle calldata: 1000 USDC → WETH (exceeds tier1 = 500 USDC)
        bytes memory uniCalldata = _buildExactInputSingle(
            USDC, WETH, 3000, address(acct), block.timestamp, 1000e6, 0, 0
        );

        // Call execute() directly as owner — ALG_ECDSA (Tier 1) is forced for direct owner calls
        // 1000 USDC > tier1Limit (500 USDC) with ECDSA (Tier 1) should revert InsufficientTokenTier
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InsufficientTokenTier.selector, uint8(2), uint8(1)
        ));
        acct.execute(UNI_ROUTER, 0, uniCalldata);
    }

    function test_setParserRegistry_zero_disablesParser() public {
        // Setting registry to address(0) disables DeFi parsing — ERC20 fallback still active
        address accountOwner = address(this);
        address guardianAddr  = address(0xBEEF01);
        address guardianAddr2 = address(0xBEEF02);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02;
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        AAStarGlobalGuard.TokenConfig[] memory tokenCfgs = new AAStarGlobalGuard.TokenConfig[](1);
        tokenCfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 500e6,
            tier2Limit: 5000e6,
            dailyLimit: 10000e6
        });

        address[3] memory guardians;
        guardians[0] = guardianAddr;
        guardians[1] = guardianAddr2;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: tokenCfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(0xEEEE), accountOwner, cfg);

        // First set a registry
        registry.registerParser(UNI_ROUTER, address(uniParser));
        acct.setParserRegistry(address(registry));
        assertEq(acct.parserRegistry(), address(registry));

        // Now clear it — sets to address(0), disabling DeFi parser lookup
        acct.setParserRegistry(address(0));
        assertEq(acct.parserRegistry(), address(0));

        // With no parser, a Uniswap call with value=0 is NOT caught by token tier check
        // (parser returns nothing, ERC20 fallback doesn't recognise the Uniswap selector)
        // So the execute call should NOT revert with InsufficientTokenTier
        bytes memory uniCalldata = _buildExactInputSingle(
            USDC, WETH, 3000, address(acct), block.timestamp, 1000e6, 0, 0
        );
        vm.prank(accountOwner);
        acct.execute(UNI_ROUTER, 0, uniCalldata); // must NOT revert (guard bypassed)
    }

    function test_enforceGuard_parserReturnsZero_fallsBackToERC20() public {
        // If parser returns (address(0), 0), guard should fall back to ERC20 native parsing
        address accountOwner = address(this);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02;
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        AAStarGlobalGuard.TokenConfig[] memory tokenCfgs = new AAStarGlobalGuard.TokenConfig[](1);
        tokenCfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100e6,   // 100 USDC tier1 max
            tier2Limit: 1000e6,
            dailyLimit: 5000e6
        });

        address[3] memory guardians;
        guardians[0] = address(0xBEEF01);
        guardians[1] = address(0xBEEF02);

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: tokenCfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(0xEEEE), accountOwner, cfg);

        // Register parser for a DIFFERENT dest — USDC itself has no parser
        registry.registerParser(UNI_ROUTER, address(uniParser));
        acct.setParserRegistry(address(registry));

        // ERC20 transfer to USDC directly: 500 USDC > tier1 → InsufficientTokenTier via ERC20 fallback
        bytes memory erc20Data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xdead), 500e6);
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InsufficientTokenTier.selector, uint8(2), uint8(1)
        ));
        acct.execute(USDC, 0, erc20Data); // parser returns (address(0), 0) → ERC20 fallback catches it
    }

    function test_uniswapParser_exactInput_pathTooShort_returnsZero() public view {
        // exactInput with path < 20 bytes cannot extract tokenIn
        bytes memory shortPath = new bytes(10); // only 10 bytes, need >= 20 for a token address
        bytes memory data = abi.encodeWithSelector(
            EXACT_INPUT,
            shortPath,          // too short
            address(0xdead),    // recipient
            uint256(9999),      // deadline
            uint256(100e6),     // amountIn
            uint256(0)          // amountOutMin
        );
        (address token, uint256 amount) = uniParser.parseTokenTransfer(data);
        assertEq(token, address(0));
        assertEq(amount, 0);
    }

    function test_enforceGuard_fallsBackToERC20_whenNoParser() public {
        // Deploy account without parser registry
        address accountOwner = address(this);
        address guardianAddr  = address(0xBEEF01);
        address guardianAddr2 = address(0xBEEF02);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02; // ECDSA

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        AAStarGlobalGuard.TokenConfig[] memory tokenCfgs = new AAStarGlobalGuard.TokenConfig[](1);
        tokenCfgs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100e6,   // 100 USDC Tier 1 max
            tier2Limit: 1000e6,
            dailyLimit: 5000e6
        });

        address[3] memory guardians;
        guardians[0] = guardianAddr;
        guardians[1] = guardianAddr2;

        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: guardians,
            dailyLimit: 10 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: tokens,
            initialTokenConfigs: tokenCfgs
        });

        AAStarAirAccountV7 acct = new AAStarAirAccountV7(address(0xEEEE), accountOwner, cfg);
        // No parser registry set — should fall back to native ERC20 parsing

        // Build ERC20 transfer calldata for 500 USDC (exceeds tier1 = 100 USDC)
        bytes memory transferCalldata = abi.encodeWithSelector(
            bytes4(0xa9059cbb), // transfer(address,uint256)
            address(0xdead),
            500e6
        );

        // ECDSA (Tier 1), amount > tier1Limit → InsufficientTokenTier
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(
            AAStarGlobalGuard.InsufficientTokenTier.selector, uint8(2), uint8(1)
        ));
        acct.execute(USDC, 0, transferCalldata);
    }
}
