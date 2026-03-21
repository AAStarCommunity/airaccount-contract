// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title AAStarAirAccountFactoryV7Test - Unit tests for CREATE2 factory
contract AAStarAirAccountFactoryV7Test is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public ownerA;
    address public ownerB;
    Vm.Wallet public g1Wallet;
    Vm.Wallet public g2Wallet;
    address public communityGuardian;

    uint256 constant TEST_DAILY_LIMIT = 0.5 ether;

    function setUp() public {
        entryPoint = makeAddr("entryPoint");
        ownerA = makeAddr("ownerA");
        ownerB = makeAddr("ownerB");
        g1Wallet = vm.createWallet("guardian1");
        g2Wallet = vm.createWallet("guardian2");
        communityGuardian = makeAddr("communityGuardian");

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        factory = new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, noTokens, noConfigs, address(0), address(0));
    }

    /// @dev Sign the domain-separated guardian acceptance message for setUp factory + owner + salt.
    function _guardianSig(Vm.Wallet memory w, address owner, uint256 salt) internal view returns (bytes memory) {
        return _guardianSigFor(w, address(factory), owner, salt);
    }

    /// @dev Sign the domain-separated guardian acceptance message for an explicit factory address.
    ///      Mirrors: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()
    function _guardianSigFor(Vm.Wallet memory w, address factoryAddr, address owner, uint256 salt) internal view returns (bytes memory) {
        bytes32 raw = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, factoryAddr, owner, salt));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _minimalConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        uint8[] memory noAlgs = new uint8[](0);
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
    }

    // ─── createAccountWithDefaults ──────────────────────────────────

    function test_createAccountWithDefaults() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        address account = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);

        assertTrue(account.code.length > 0);

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));
        assertEq(acc.owner(), ownerA);
        assertEq(acc.guardianCount(), 3);
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
        assertEq(acc.guardians(2), communityGuardian);

        // Guard should be initialized with user-specified daily limit
        assertTrue(address(acc.guard()) != address(0));
        AAStarGlobalGuard g = acc.guard();
        assertEq(g.account(), account);
        assertEq(g.dailyLimit(), TEST_DAILY_LIMIT);
        assertTrue(g.approvedAlgorithms(0x02)); // ECDSA
        assertTrue(g.approvedAlgorithms(0x01)); // BLS
        assertTrue(g.approvedAlgorithms(0x03)); // P256
    }

    function test_createAccountWithDefaults_deterministic() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 1);
        address a1 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        address a2 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        assertEq(a1, a2);
    }

    function test_getAddressWithDefaults_matchesCreated() public {
        address predicted = factory.getAddressWithDefaults(ownerA, 5, g1Wallet.addr, g2Wallet.addr, TEST_DAILY_LIMIT);
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 5);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 5);
        address actual = factory.createAccountWithDefaults(ownerA, 5, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
        assertEq(predicted, actual);
    }

    function test_createAccountWithDefaults_differentLimits() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a1 = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, 0.1 ether);

        // With clone pattern: address depends on owner+salt only (not config).
        
        bytes memory sig1b = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerA, 1);
        address a2 = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, 1 ether);
        assertTrue(a1 != a2);
    }

    // ─── M5.3: Guardian acceptance validation ───────────────────────

    function test_guardian1_invalidSig_reverts() public {
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27)); // zero sig
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, badSig, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian2_invalidSig_reverts() public {
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory badSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g2Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, badSig, TEST_DAILY_LIMIT);
    }

    function test_guardian1_wrongSigner_reverts() public {
        // g2 signs for g1's slot — wrong signer
        bytes memory wrongSig = _guardianSig(g2Wallet, ownerA, 0);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, wrongSig, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian_wrongOwner_reverts() public {
        // Guardian signs for wrong owner
        bytes memory sig1 = _guardianSig(g1Wallet, ownerB, 0); // signed for ownerB, not ownerA
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    function test_guardian_wrongSalt_reverts() public {
        // Guardian signs for wrong salt
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 99); // signed for salt=99, not 0
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT);
    }

    // ─── createAccount (full config) ────────────────────────────────

    function test_createAccount_fullConfig() public {
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = 0x02;
        algIds[1] = 0x03;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [g1Wallet.addr, g2Wallet.addr, address(0)],
            dailyLimit: 5 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        address account = factory.createAccount(ownerA, 0, config);
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        assertEq(acc.guardianCount(), 2);
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
        assertEq(acc.guard().dailyLimit(), 5 ether);
    }

    function test_getAddress_matchesCreated() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 123, config);
        address actual = factory.createAccount(ownerA, 123, config);
        assertEq(predicted, actual);
    }

    // ─── Different params produce different addresses ────────────────

    function test_differentOwners_differentAddresses() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, TEST_DAILY_LIMIT);

        bytes memory sig1b = _guardianSig(g1Wallet, ownerB, 0);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerB, 0);
        address b = factory.createAccountWithDefaults(ownerB, 0, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    function test_differentSalts_differentAddresses() public {
        bytes memory sig1a = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2a = _guardianSig(g2Wallet, ownerA, 0);
        address a = factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sig1a, g2Wallet.addr, sig2a, TEST_DAILY_LIMIT);

        bytes memory sig1b = _guardianSig(g1Wallet, ownerA, 1);
        bytes memory sig2b = _guardianSig(g2Wallet, ownerA, 1);
        address b = factory.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1b, g2Wallet.addr, sig2b, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    // ─── Factory state ──────────────────────────────────────────────

    function test_factoryEntryPoint() public view {
        assertEq(factory.entryPoint(), entryPoint);
    }

    function test_factoryCommunityGuardian() public view {
        assertEq(factory.defaultCommunityGuardian(), communityGuardian);
    }

    // ─── Event emission ─────────────────────────────────────────────

    function test_createAccount_emitsEvent() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 99, config);

        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountFactoryV7.AccountCreated(predicted, ownerA, 99);

        factory.createAccount(ownerA, 99, config);
    }

    // ─── Default token config (constructor injection) ────────────────

    /// @dev Factory with 1 default token pre-loaded; accounts created via createAccountWithDefaults
    ///      inherit that token config automatically via _buildDefaultConfig.
    function test_createAccountWithDefaults_inheritsDefaultTokens() public {
        address mockToken = address(0xBEEF);
        address[] memory tokens = new address[](1);
        tokens[0] = mockToken;
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](1);
        configs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100e6,
            tier2Limit: 1000e6,
            dailyLimit: 5000e6
        });

        AAStarAirAccountFactoryV7 tokenFactory = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, tokens, configs, address(0), address(0)
        );

        bytes memory sig1 = _guardianSigFor(g1Wallet, address(tokenFactory), ownerA, 0);
        bytes memory sig2 = _guardianSigFor(g2Wallet, address(tokenFactory), ownerA, 0);
        address account = tokenFactory.createAccountWithDefaults(
            ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT
        );

        AAStarGlobalGuard g = AAStarAirAccountV7(payable(account)).guard();
        (uint256 t1, uint256 t2, uint256 daily) = g.tokenConfigs(mockToken);
        assertEq(t1, 100e6,   "tier1Limit mismatch");
        assertEq(t2, 1000e6,  "tier2Limit mismatch");
        assertEq(daily, 5000e6, "dailyLimit mismatch");
    }

    function test_factoryWithNoDefaultTokens_accountHasNoTokenConfig() public {
        // The default setUp factory has no token config — accounts should have empty token configs
        bytes memory sig1 = _guardianSig(g1Wallet, ownerA, 0);
        bytes memory sig2 = _guardianSig(g2Wallet, ownerA, 0);
        address account = factory.createAccountWithDefaults(
            ownerA, 0, g1Wallet.addr, sig1, g2Wallet.addr, sig2, TEST_DAILY_LIMIT
        );

        AAStarGlobalGuard g = AAStarAirAccountV7(payable(account)).guard();
        (uint256 t1, uint256 t2, uint256 daily) = g.tokenConfigs(address(0xDEAD));
        assertEq(t1, 0);
        assertEq(t2, 0);
        assertEq(daily, 0);
    }

    // ─── Packed guardian storage ─────────────────────────────────────

    /// @dev Empty guardian slots must return address(0) (packed storage edge case).
    function test_packedStorage_emptySlot_returnsAddressZero() public {
        // Create account with only 2 guardians → slot index 2 must be address(0)
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = 0x02;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [g1Wallet.addr, g2Wallet.addr, address(0)],
            dailyLimit: 1 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        address account = factory.createAccount(ownerA, 77, config);
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        assertEq(acc.guardianCount(), 2);
        assertEq(acc.guardians(0), g1Wallet.addr);
        assertEq(acc.guardians(1), g2Wallet.addr);
        assertEq(acc.guardians(2), address(0)); // empty slot must be zero
    }

    // ─── Codex audit: LOW — factory default config validation ────────

    /// @dev Invalid default token config (tier1 > tier2) should revert at factory deploy time,
    ///      not silently succeed and fail on every createAccountWithDefaults call.
    function test_invalidDefaultConfig_tier1GtTier2_reverts() public {
        address mockToken = address(0xBEEF);
        address[] memory tokens = new address[](1);
        tokens[0] = mockToken;
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](1);
        configs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 1000e6, // tier1 > tier2 — invalid
            tier2Limit: 100e6,
            dailyLimit: 5000e6
        });
        vm.expectRevert("Invalid default token config");
        new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, tokens, configs, address(0), address(0));
    }

    /// @dev Tier limits set but dailyLimit=0 should revert (guard requires dailyLimit > 0
    ///      for cumulative tracking to work).
    function test_invalidDefaultConfig_noDaily_reverts() public {
        address mockToken = address(0xBEEF);
        address[] memory tokens = new address[](1);
        tokens[0] = mockToken;
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](1);
        configs[0] = AAStarGlobalGuard.TokenConfig({
            tier1Limit: 100e6,
            tier2Limit: 1000e6,
            dailyLimit: 0    // tier limits set but no daily — invalid
        });
        vm.expectRevert("Invalid default token config");
        new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, tokens, configs, address(0), address(0));
    }

    // ─── Codex audit: MEDIUM — guardian acceptance domain separation ──

    /// @dev A guardian sig produced for a DIFFERENT chainId must be rejected.
    ///      Prevents replay of acceptance signatures across chains.
    function test_guardian_wrongChainId_reverts() public {
        uint256 wrongChain = block.chainid + 1;
        // Sign for wrong chainId manually
        bytes32 raw = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", wrongChain, address(factory), ownerA, uint256(0)));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g1Wallet.privateKey, ethHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        bytes memory correctSig2 = _guardianSig(g2Wallet, ownerA, 0);

        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, badSig, g2Wallet.addr, correctSig2, TEST_DAILY_LIMIT);
    }

    /// @dev A guardian sig produced for a DIFFERENT factory address must be rejected.
    ///      Prevents replay across factories on the same chain with same owner+salt.
    function test_guardian_wrongFactory_reverts() public {
        // Deploy a second factory, sign acceptance for it
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 otherFactory = new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, noTokens, noConfigs, address(0), address(0));

        // Sign for otherFactory address
        bytes memory sigForOtherFactory = _guardianSigFor(g1Wallet, address(otherFactory), ownerA, 0);
        bytes memory correctSig2 = _guardianSig(g2Wallet, ownerA, 0);

        vm.expectRevert(abi.encodeWithSelector(AAStarAirAccountFactoryV7.GuardianDidNotAccept.selector, g1Wallet.addr));
        factory.createAccountWithDefaults(ownerA, 0, g1Wallet.addr, sigForOtherFactory, g2Wallet.addr, correctSig2, TEST_DAILY_LIMIT);
    }

    // ─── Codex audit: LOW — address zero and dedup validation ────────

    /// @dev address(0) as a default token address should revert at factory deploy time.
    function test_invalidDefaultConfig_addressZero_reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0); // zero address
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](1);
        configs[0] = AAStarGlobalGuard.TokenConfig({ tier1Limit: 0, tier2Limit: 0, dailyLimit: 0 });
        vm.expectRevert("Default token address zero");
        new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, tokens, configs, address(0), address(0));
    }

    /// @dev Duplicate token address in default config should revert at factory deploy time.
    function test_invalidDefaultConfig_duplicateToken_reverts() public {
        address mockToken = address(0xBEEF);
        address[] memory tokens = new address[](2);
        tokens[0] = mockToken;
        tokens[1] = mockToken; // duplicate
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](2);
        configs[0] = AAStarGlobalGuard.TokenConfig({ tier1Limit: 0, tier2Limit: 0, dailyLimit: 0 });
        configs[1] = AAStarGlobalGuard.TokenConfig({ tier1Limit: 0, tier2Limit: 0, dailyLimit: 0 });
        vm.expectRevert("Duplicate default token");
        new AAStarAirAccountFactoryV7(entryPoint, communityGuardian, tokens, configs, address(0), address(0));
    }

    // ─── ERC-7828 Chain-Specific Address (M7.4) ──────────────────────────────

    function test_getChainQualifiedAddress_deterministicHash() public {
        address account = makeAddr("account");
        bytes32 cqa = factory.getChainQualifiedAddress(account);
        bytes32 expected = keccak256(abi.encodePacked(account, block.chainid));
        assertEq(cqa, expected);
    }

    function test_getChainQualifiedAddress_differentAddresses_differ() public {
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        assertNotEq(factory.getChainQualifiedAddress(a1), factory.getChainQualifiedAddress(a2));
    }

    function test_getAddressWithChainId_matchesPredictedAddress() public {
        address owner = makeAddr("owner");
        uint256 salt = 42;
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();

        (address predicted, bytes32 chainQual) = factory.getAddressWithChainId(owner, salt, config);
        address expected = factory.getAddress(owner, salt, config);
        bytes32 expectedCq = factory.getChainQualifiedAddress(expected);

        assertEq(predicted, expected);
        assertEq(chainQual, expectedCq);
    }

    function test_getChainQualifiedAddress_differentChains_differ() public {
        address account = makeAddr("account");
        bytes32 cq1 = factory.getChainQualifiedAddress(account);
        vm.chainId(999);
        bytes32 cq2 = factory.getChainQualifiedAddress(account);
        assertNotEq(cq1, cq2);
    }

    function test_getChainQualifiedAddress_sameAddressSameChain_sameResult() public {
        address account = makeAddr("account");
        bytes32 cq1 = factory.getChainQualifiedAddress(account);
        bytes32 cq2 = factory.getChainQualifiedAddress(account);
        assertEq(cq1, cq2);
    }

    // ─── C8: Factory Pre-Install Default Modules (M7.2) ───────────────────

    /// @notice Factory with no default modules stores address(0) for both
    function test_factory_noDefaultModules_storesZero() public view {
        assertEq(factory.defaultValidatorModule(), address(0));
        assertEq(factory.defaultHookModule(), address(0));
    }

    /// @notice Factory stores default validator module address
    function test_factory_defaultValidatorModule_stored() public {
        address mockValidator = makeAddr("mockValidator");
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, mockValidator, address(0)
        );
        assertEq(f.defaultValidatorModule(), mockValidator);
        assertEq(f.defaultHookModule(), address(0));
    }

    /// @notice Factory stores default hook module address
    function test_factory_defaultHookModule_stored() public {
        address mockHook = makeAddr("mockHook");
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(0), mockHook
        );
        assertEq(f.defaultValidatorModule(), address(0));
        assertEq(f.defaultHookModule(), mockHook);
    }

    /// @notice createAccount with default modules pre-installs them on the new account
    function test_factory_createAccount_preinstalls_defaultValidator() public {
        // Deploy a minimal module with code (needed for _preInstallModule to proceed)
        MockModuleC8 mockValidator = new MockModuleC8();

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(mockValidator), address(0)
        );

        address account = f.createAccount(ownerA, 999, _minimalConfig());
        AAStarAirAccountV7 acct = AAStarAirAccountV7(payable(account));

        // Validator should be pre-installed (type 1)
        assertTrue(acct.isModuleInstalled(1, address(mockValidator), ""));
        // onInstall should have been called
        assertTrue(mockValidator.installedFor(account));
    }

    /// @notice createAccount with default hook pre-installs it on the new account
    function test_factory_createAccount_preinstalls_defaultHook() public {
        MockModuleC8 mockHook = new MockModuleC8();

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(0), address(mockHook)
        );

        address account = f.createAccount(ownerA, 999, _minimalConfig());
        AAStarAirAccountV7 acct = AAStarAirAccountV7(payable(account));

        // Hook should be pre-installed (type 3)
        assertTrue(acct.isModuleInstalled(3, address(mockHook), ""));
    }

    /// @notice createAccountWithDefaults pre-installs both default modules
    function test_factory_createAccountWithDefaults_preinstalls_both() public {
        MockModuleC8 mockValidator = new MockModuleC8();
        MockModuleC8 mockHook = new MockModuleC8();

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(mockValidator), address(mockHook)
        );

        bytes memory sig1 = _guardianSigFor(g1Wallet, address(f), ownerA, 1);
        bytes memory sig2 = _guardianSigFor(g2Wallet, address(f), ownerA, 1);
        address account = f.createAccountWithDefaults(ownerA, 1, g1Wallet.addr, sig1, g2Wallet.addr, sig2, 1 ether);
        AAStarAirAccountV7 acct = AAStarAirAccountV7(payable(account));

        assertTrue(acct.isModuleInstalled(1, address(mockValidator), ""), "validator not installed");
        assertTrue(acct.isModuleInstalled(3, address(mockHook), ""), "hook not installed");
    }

    /// @notice Pre-installed module is idempotent — second createAccount call returns same account (already deployed)
    function test_factory_preinstall_idempotent_on_redeployAttempt() public {
        MockModuleC8 mockValidator = new MockModuleC8();

        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 f = new AAStarAirAccountFactoryV7(
            entryPoint, communityGuardian, noTokens, noConfigs, address(mockValidator), address(0)
        );

        address account1 = f.createAccount(ownerA, 42, _minimalConfig());
        address account2 = f.createAccount(ownerA, 42, _minimalConfig()); // same params = same address
        assertEq(account1, account2); // returns existing, no revert
    }

    /// @notice initialize() with modules overload works without factory (direct call for testing)
    function test_initialize_withModules_directCall() public {
        MockModuleC8 mockMod = new MockModuleC8();

        AAStarAirAccountV7 acct = new AAStarAirAccountV7();

        uint256[] memory typeIds = new uint256[](1);
        typeIds[0] = 1; // validator
        address[] memory mods = new address[](1);
        mods[0] = address(mockMod);
        bytes[] memory datas = new bytes[](1);
        datas[0] = "";

        acct.initialize(entryPoint, ownerA, _minimalConfig(), address(0), typeIds, mods, datas);

        assertTrue(acct.isModuleInstalled(1, address(mockMod), ""));
        assertTrue(mockMod.installedFor(address(acct)));
    }

    /// @notice _preInstallModule skips address(0) modules silently — initialize must not revert
    function test_initialize_withModules_zeroAddressSkipped() public {
        AAStarAirAccountV7 acct = new AAStarAirAccountV7();

        uint256[] memory typeIds = new uint256[](1);
        typeIds[0] = 1;
        address[] memory mods = new address[](1);
        mods[0] = address(0); // zero address — should be silently skipped
        bytes[] memory datas = new bytes[](1);
        datas[0] = "";

        // Should not revert even with address(0) module
        acct.initialize(entryPoint, ownerA, _minimalConfig(), address(0), typeIds, mods, datas);
        // Owner should still be set correctly (account initialized successfully)
        assertEq(acct.owner(), ownerA);
    }
}

/// @notice Minimal mock module for C8 pre-install tests
contract MockModuleC8 {
    mapping(address => bool) public installedFor;

    function onInstall(bytes calldata) external {
        installedFor[msg.sender] = true;
    }

    function onUninstall(bytes calldata) external {
        installedFor[msg.sender] = false;
    }

    function isInitialized(address smartAccount) external view returns (bool) {
        return installedFor[smartAccount];
    }
}
