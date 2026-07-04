// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @title Beta4AlgIdBundlerFix — verifies the v0.17.2-beta.4 bundler-compatibility fix.
/// @notice Covers: (1) the algorithm whitelist is the ACCOUNT's single source of truth and enforced
///         in validateUserOp; (2) executeUserOp re-derives algId from the signature so guard-enabled
///         accounts work under bundler split-simulation (no AlgorithmNotApproved(0) / InsufficientTier
///         from a cleared transient algId); (3) tiered accounts resolve the correct tier in execution.
contract Beta4AlgIdBundlerFixTest is Test {
    AAStarAirAccountV7 internal account;
    AAStarGlobalGuard internal guard;
    address internal entryPoint = address(0xEE);
    address internal ownerAddr;
    uint256 internal ownerKey;
    address internal dest = address(0xD157);

    uint8 internal constant ALG_ECDSA = 0x02;
    uint8 internal constant ALG_P256  = 0x03;

    function setUp() public {
        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    /// @dev Deploy a fresh account + guard. `algs` populates the ACCOUNT whitelist (new in beta.4);
    ///      the guard no longer takes algIds. dailyLimit>0 deploys the guard.
    function _deploy(uint8[] memory algs, uint256 dailyLimit) internal {
        account = new AAStarAirAccountV7(address(0));
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: dailyLimit,
            approvedAlgIds: algs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        address g = address(0);
        if (dailyLimit > 0) {
            g = address(new AAStarGlobalGuard(address(account), dailyLimit, 0, new address[](0), new AAStarGlobalGuard.TokenConfig[](0)));
        }
        account.initialize(entryPoint, ownerAddr, cfg, g, bytes32(0), bytes32(0));
        guard = AAStarGlobalGuard(g);
        vm.deal(address(account), 100 ether);
    }

    function _algs(uint8 a) internal pure returns (uint8[] memory out) {
        out = new uint8[](1);
        out[0] = a;
    }

    /// @dev Explicit ALG_ECDSA (0x02) owner sig over the EIP-191 prefixed userOpHash (66 bytes).
    ///      The M1 raw-65 fallback was removed (CRITICAL-1) — every tier is now explicit in the prefix.
    function _signEcdsa(bytes32 userOpHash) internal view returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        return abi.encodePacked(bytes1(0x02), r, s, v);
    }

    function _emptyUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = address(account);
        op.nonce = 0;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        op.paymasterAndData = "";
        op.signature = "";
    }

    /// @dev callData wrapped for the ERC-4337 v0.7 executeUserOp route: executeUserOp.selector ++ inner.
    function _wrapExecute(address to, uint256 value) internal view returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(account.execute.selector, to, value, bytes(""));
        return bytes.concat(AAStarAirAccountV7.executeUserOp.selector, inner);
    }

    // ─── Whitelist is the account's single source of truth ──────────────

    function test_whitelist_populatedOnAccountFromConfig() public {
        _deploy(_algs(ALG_ECDSA), 1 ether);
        assertTrue(account.approvedAlgorithms(ALG_ECDSA), "account should own the whitelist");
        assertFalse(account.approvedAlgorithms(ALG_P256), "non-configured alg not approved");
    }

    function test_guardApproveAlgorithm_writesAccountNotGuard() public {
        _deploy(_algs(ALG_ECDSA), 1 ether);
        assertFalse(account.approvedAlgorithms(0x09));
        vm.prank(ownerAddr);
        account.guardApproveAlgorithm(0x09);
        assertTrue(account.approvedAlgorithms(0x09), "guardApproveAlgorithm must update the account whitelist");
    }

    function test_guardApproveAlgorithm_onlyOwner() public {
        _deploy(_algs(ALG_ECDSA), 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.guardApproveAlgorithm(0x09);
    }

    // ─── validateUserOp authoritative whitelist gate ────────────────────

    function test_validateUserOp_acceptsWhitelistedAlg() public {
        _deploy(_algs(ALG_ECDSA), 1 ether);
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 0);
        bytes32 h = keccak256("op-accept");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        uint256 vd = account.validateUserOp(op, h, 0);
        assertEq(vd, 0, "whitelisted ECDSA op must validate");
    }

    function test_validateUserOp_rejectsNonWhitelistedAlg() public {
        // Whitelist only P256; send a perfectly valid owner-ECDSA op → signature is valid but the
        // algorithm is not approved → the validation gate must reject with SIG_VALIDATION_FAILED.
        _deploy(_algs(ALG_P256), 1 ether);
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 0);
        bytes32 h = keccak256("op-reject");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        uint256 vd = account.validateUserOp(op, h, 0);
        assertEq(vd, 1, "non-whitelisted algorithm must be rejected in validation");
    }

    // ─── executeUserOp selector allowlist (Codex CRITICAL fix) ──────────

    function test_executeUserOp_rejectsNestedWrapper() public {
        // A nested executeUserOp would let the inner (never-validated) signature forge a high algId.
        _deploy(_algs(ALG_ECDSA), 5 ether);
        bytes memory inner = bytes.concat(AAStarAirAccountV7.executeUserOp.selector, hex"deadbeef");
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = bytes.concat(AAStarAirAccountV7.executeUserOp.selector, inner);
        bytes32 h = keccak256("nested");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedInnerSelector()"));
        account.executeUserOp(op, h);
    }

    function test_executeUserOp_rejectsArbitrarySelector() public {
        _deploy(_algs(ALG_ECDSA), 5 ether);
        bytes memory inner = bytes.concat(bytes4(0x12345678), hex"00");
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = bytes.concat(AAStarAirAccountV7.executeUserOp.selector, inner);
        bytes32 h = keccak256("arb");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedInnerSelector()"));
        account.executeUserOp(op, h);
    }

    // ─── executeUserOp coverage: batch, daily-limit, non-ECDSA tier re-derivation ──

    function test_executeUserOp_executeBatch_runsAllCalls() public {
        _deploy(_algs(ALG_ECDSA), 10 ether);
        address d1 = address(0xD1); address d2 = address(0xD2);
        address[] memory dests = new address[](2); dests[0] = d1; dests[1] = d2;
        uint256[] memory vals = new uint256[](2); vals[0] = 1 ether; vals[1] = 2 ether;
        bytes[] memory funcs = new bytes[](2); funcs[0] = ""; funcs[1] = "";
        bytes memory inner = abi.encodeWithSelector(account.executeBatch.selector, dests, vals, funcs);
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = bytes.concat(AAStarAirAccountV7.executeUserOp.selector, inner);
        bytes32 h = keccak256("batch");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        account.executeUserOp(op, h);
        assertEq(d1.balance, 1 ether, "batch call 1 ran");
        assertEq(d2.balance, 2 ether, "batch call 2 ran");
    }

    function test_executeUserOp_dailyLimitStillEnforced() public {
        // guard accounting (recordSpend) must still revert on daily-limit breach through executeUserOp.
        _deploy(_algs(ALG_ECDSA), 1 ether); // dailyLimit = 1 ETH, no tiering
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 2 ether); // exceeds daily limit
        bytes32 h = keccak256("overlimit");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        vm.expectRevert(); // DailyLimitExceeded bubbled from guard.recordSpend via the delegatecall
        account.executeUserOp(op, h);
    }

    function test_executeUserOp_rederivesNonEcdsaTierFromPrefix() public {
        // Proves executeUserOp re-derives the correct (higher) tier from the signature prefix:
        // a tier-3 (0x05) prefix lets a value that requires tier 3 execute. If algId were the cleared
        // transient 0 (tier 0), the execution tier check would revert InsufficientTier.
        _deploy(_algs(0x05), 5 ether); // whitelist CUMULATIVE_T3
        vm.prank(ownerAddr);
        account.setTierLimits(0.1 ether, 1 ether); // 2 ETH → requires tier 3

        bytes memory inner = abi.encodeWithSelector(account.execute.selector, dest, uint256(2 ether), bytes(""));
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = bytes.concat(AAStarAirAccountV7.executeUserOp.selector, inner);
        bytes32 h = keccak256("t3");
        // 0x05 prefix → _populateExecAlg stores ALG_CUMULATIVE_T3 (tier 3); not crypto-verified in
        // executeUserOp (validateUserOp verifies in the real flow). Length 65 = prefix + 64.
        op.signature = abi.encodePacked(uint8(0x05), new bytes(64));

        uint256 before = dest.balance;
        vm.prank(entryPoint);
        account.executeUserOp(op, h);
        assertEq(dest.balance - before, 2 ether, "tier-3 algId re-derived from prefix clears tier-3 value");
    }

    // ─── validateUserOp per-op tier gate (fail-fast, Codex MEDIUM fix) ──

    function test_validateUserOp_rejectsUnderTierValue() public {
        // tier1 = 1 ETH; an ECDSA (tier 1) op moving 2 ETH requires tier 2 → must reject in validation
        // (not just at execution) so the bundler never includes a doomed op.
        _deploy(_algs(ALG_ECDSA), 10 ether);
        vm.prank(ownerAddr);
        account.setTierLimits(1 ether, 5 ether);

        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 2 ether); // above tier1 → needs tier 2
        bytes32 h = keccak256("op-undertier");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        assertEq(account.validateUserOp(op, h, 0), 1, "under-tier op must fail validation fast");
    }

    function test_validateUserOp_acceptsWithinTierValue() public {
        _deploy(_algs(ALG_ECDSA), 10 ether);
        vm.prank(ownerAddr);
        account.setTierLimits(1 ether, 5 ether);

        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 0.5 ether); // within tier 1
        bytes32 h = keccak256("op-intier");
        op.signature = _signEcdsa(h);

        vm.prank(entryPoint);
        assertEq(account.validateUserOp(op, h, 0), 0, "within-tier ECDSA op must validate");
    }

    // ─── executeUserOp survives bundler split-simulation ────────────────

    /// @notice THE core regression test. The bundler simulates validateUserOp and execution in
    ///         SEPARATE eth_calls, so cross-phase transient storage is cleared. executeUserOp must
    ///         re-derive algId from userOp.signature in THIS frame and execute without reverting.
    function test_executeUserOp_splitSimulation_executes() public {
        _deploy(_algs(ALG_ECDSA), 5 ether);
        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 1 ether);
        bytes32 h = keccak256("op-exec");
        op.signature = _signEcdsa(h);

        uint256 destBefore = dest.balance;
        // Call executeUserOp DIRECTLY as the EntryPoint with NO prior validateUserOp in this call —
        // exactly the bundler's separate-eth_call execution phase (transient algId queue is empty).
        vm.prank(entryPoint);
        account.executeUserOp(op, h);

        assertEq(dest.balance - destBefore, 1 ether, "inner execute() must run via executeUserOp");
    }

    /// @notice Tiered account: executeUserOp must resolve algId=ECDSA (tier 1) from the signature so
    ///         a value within tier-1 passes. If algId were the cleared-transient 0 (tier 0), this
    ///         would revert InsufficientTier — so success proves the re-derivation works.
    function test_executeUserOp_tieredAccount_resolvesAlgId() public {
        _deploy(_algs(ALG_ECDSA), 5 ether);
        vm.prank(ownerAddr);
        account.setTierLimits(1 ether, 2 ether); // tier1 = 1 ETH (ECDSA), above requires stronger

        PackedUserOperation memory op = _emptyUserOp();
        op.callData = _wrapExecute(dest, 0.5 ether); // within tier 1
        bytes32 h = keccak256("op-tier");
        op.signature = _signEcdsa(h);

        uint256 destBefore = dest.balance;
        vm.prank(entryPoint);
        account.executeUserOp(op, h);
        assertEq(dest.balance - destBefore, 0.5 ether, "tier-1 value must pass with re-derived ECDSA algId");
    }

    /// @notice Demonstrates WHY executeUserOp is required: calling execute() DIRECTLY via the
    ///         EntryPoint (the old unwrapped path) on a tiered account reads algId=0 from the empty
    ///         transient queue → tier 0 < required tier 1 → InsufficientTier. executeUserOp avoids this.
    function test_directExecuteViaEntryPoint_tiered_revertsFromClearedAlgId() public {
        _deploy(_algs(ALG_ECDSA), 5 ether);
        vm.prank(ownerAddr);
        account.setTierLimits(1 ether, 2 ether);

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSignature("InsufficientTier(uint8,uint8)", uint8(1), uint8(0)));
        account.execute(dest, 0.5 ether, "");
    }
}
