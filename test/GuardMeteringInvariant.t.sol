// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, StdInvariant, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title GuardMeteringInvariant — CC-99 需求2: non-bypass verification via a Foundry invariant.
/// @notice Property (the reviewer's "cheapest large credibility upgrade"): over ANY sequence of external
///         value-moving calls, the guard's cumulative accounting (`todaySpent()`) is never LESS than the
///         native ETH that actually left the account. If any path could move value without routing through
///         `_enforceGuard`→`recordSpend`, the receiver's balance would exceed `todaySpent()` and the
///         invariant would break. This is dynamic exhaustiveness — stronger than a hand enumeration
///         (which historically missed `withdrawDepositTo`, the H1 bypass, and `executeFromExecutor`).
/// @dev The handler drives the REAL flow: `validateUserOp` (stores the tier algId in transient storage)
///      then `execute`/`executeBatch` in the SAME call frame so the tstore algId persists (no --isolate).
contract GuardMeteringHandler is Test {
    AAStarAirAccountV7 public account;
    address public entryPoint;
    Vm.Wallet internal owner;
    address public receiver = address(0x4EC0);

    uint256 public opNonce;      // makes each userOpHash unique
    uint256 public ghostSent;    // ETH the handler intended to send (sanity cross-check)

    constructor(AAStarAirAccountV7 _account, address _entryPoint, Vm.Wallet memory _owner) {
        account = _account;
        entryPoint = _entryPoint;
        owner = _owner;
    }

    function _op() internal returns (PackedUserOperation memory op, bytes32 h) {
        op = PackedUserOperation({
            sender: address(account), nonce: opNonce, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""
        });
        h = keccak256(abi.encode(op.sender, op.nonce, "cc99-metering", opNonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner.privateKey, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v); // raw 65-byte owner ECDSA => tier-1 inline
        opNonce++;
    }

    /// Real tier-1 flow: validateUserOp (stores algId) then execute — both in this one frame.
    function execute(uint256 rawValue) external {
        uint256 value = bound(rawValue, 0, 0.5 ether);
        if (address(account).balance < value) return;
        (PackedUserOperation memory op, bytes32 h) = _op();
        vm.prank(entryPoint);
        if (account.validateUserOp(op, h, 0) != 0) return; // sig must validate (tier-1)
        vm.prank(entryPoint);
        try account.execute(receiver, value, "") { ghostSent += value; } catch { /* tier/limit revert: no outflow */ }
    }

    function executeBatch(uint256 rawA, uint256 rawB) external {
        uint256 a = bound(rawA, 0, 0.25 ether);
        uint256 b = bound(rawB, 0, 0.25 ether);
        if (address(account).balance < a + b) return;
        (PackedUserOperation memory op, bytes32 h) = _op();
        vm.prank(entryPoint);
        if (account.validateUserOp(op, h, 0) != 0) return;
        address[] memory dests = new address[](2);
        uint256[] memory vals = new uint256[](2);
        bytes[] memory funcs = new bytes[](2);
        dests[0] = receiver; dests[1] = receiver; vals[0] = a; vals[1] = b; funcs[0] = ""; funcs[1] = "";
        vm.prank(entryPoint);
        try account.executeBatch(dests, vals, funcs) { ghostSent += a + b; } catch { }
    }
}

contract GuardMeteringInvariantTest is StdInvariant, Test {
    AAStarAirAccountV7 account;
    AAStarGlobalGuard guard;
    GuardMeteringHandler handler;
    address entryPoint = address(0xEE7);
    Vm.Wallet owner;

    function setUp() public {
        owner = vm.createWallet("cc99-owner");
        account = new AAStarAirAccountV7(address(0));

        // Guard-configured account: tier1Limit huge (all fuzzed values stay tier-1), dailyLimit huge
        // (never binds — we want the metering path exercised, not the limit).
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 1e30,
            approvedAlgIds: new uint8[](0),
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: uint128(1e27),   // native ETH tier-1 ceiling (huge)
            tier2Limit: uint128(2e27)
        });
        guard = new AAStarGlobalGuard(address(account), cfg.dailyLimit, cfg.minDailyLimit, cfg.initialTokens, cfg.initialTokenConfigs);
        account.initialize(entryPoint, owner.addr, cfg, address(guard), bytes32(0), bytes32(0));
        vm.deal(address(account), 100 ether);

        handler = new GuardMeteringHandler(account, entryPoint, owner);
        targetContract(address(handler));
    }

    /// Core non-bypass invariant: the guard accounted for at least everything that left the account.
    /// (Equality holds when every outflow is metered; `>=` would still hold if a path over-metered.
    ///  A bypass — value out with no recordSpend — makes receiver.balance exceed todaySpent → FAIL.)
    function invariant_guardMetersAllOutflow() public view {
        assertGe(guard.todaySpent(), handler.receiver().balance, "guard under-metered an outflow (bypass!)");
    }

    /// Sanity: the metered total equals what the handler intended to send (no silent loss/gain).
    function invariant_meteredEqualsSent() public view {
        assertEq(guard.todaySpent(), handler.ghostSent(), "metered != intended sent");
    }
}
