// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {IAAStarCommitteeValidator} from "../src/interfaces/IAAStarCommitteeValidator.sol";
import {IAirAccountAgent} from "../src/interfaces/IAirAccountAgent.sol";
import {AAStarAgentStorageLayout} from "../src/core/AAStarAgentStorageLayout.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockEP_Committee {
    receive() external payable {}
}

contract MockP256Ok_Committee {
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(uint256(1)); }
}

/// @dev Mock CC-98 committee validator. `validate` asserts the CALLER prepended accountId = an ENROLLED
///      address and that the committee wire layout (accountId(32) ‖ k×512 ‖ blsSig(256)) is well-formed —
///      i.e. the account used the 512-byte committee stride and injected its own address(this). A submitter
///      cannot supply accountId (the account owns that word), and a non-enrolled accountId fails closed.
contract MockCommitteeValidator is IAAStarAlgorithm, IAAStarCommitteeValidator {
    uint256 public constant PER_SIGNER = 512; // 64 + TREE_DEPTH(14)*32
    bool public active = true;
    uint256 public quorum = 1;
    address public agg; // protocol batch aggregator (0 = none)
    mapping(address => bool) public enrolled;

    function setActive(bool a) external { active = a; }
    function setQuorum(uint256 q) external { quorum = q; }
    function setAggregator(address a) external { agg = a; }
    function aggregator() external view returns (address) { return agg; }

    function committeeActive() external view returns (bool) { return active; }
    function requiredQuorum() external view returns (uint256) { return quorum; }
    function enroll() external { enrolled[msg.sender] = true; }

    function validate(bytes32, bytes calldata sig) external view returns (uint256) {
        if (!active) {
            // Legacy whole-set layout: [nodeId(32)…][blsSig(256)] — NO accountId prefix, 32-byte stride.
            if (sig.length <= 256) return 1;
            return ((sig.length - 256) % 32 == 0) ? 0 : 1;
        }
        if (sig.length < 32 + 256) return 1;
        uint256 body = sig.length - 32 - 256;
        if (body == 0 || body % PER_SIGNER != 0) return 1;        // committee stride respected
        address acct = address(uint160(uint256(bytes32(sig[0:32]))));
        return enrolled[acct] ? 0 : 1;                            // accountId must be the enrolled account
    }
}

/// @dev TRUE legacy whole-set validator (models AAStarValidator 0x539B). Does NOT implement
///      committeeActive()/requiredQuorum() — the account's try/catch on committeeActive() REVERTS →
///      committeeOff=false → byte-identical whole-set framing. This is the long-term-coexistence form the
///      CC-116 gate must NOT break: [nodeId(32)…][blsSig(256)], 32-byte stride, no accountId prefix. May
///      optionally expose a protocol batch aggregator (legacy-only deferral path).
contract MockLegacyValidator is IAAStarAlgorithm {
    address public agg;
    function setAggregator(address a) external { agg = a; }
    function aggregator() external view returns (address) { return agg; }
    function validate(bytes32, bytes calldata sig) external pure returns (uint256) {
        if (sig.length <= 256) return 1;
        return ((sig.length - 256) % 32 == 0) ? 0 : 1;
    }
}

/// @title CC-98 committee BLS framing — account-side v0.31.0 unit tests
contract CommitteeBLSFramingV031 is Test {
    MockEP_Committee ep;
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockCommitteeValidator committee;
    Vm.Wallet ownerW;

    function setUp() public {
        ownerW = vm.createWallet("owner");
        ep = new MockEP_Committee();

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0, tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(address(ep), ownerW.addr, cfg, address(0), bytes32(0), bytes32(0));

        router = new AAStarValidator();
        committee = new MockCommitteeValidator();
        router.registerAlgorithm(0x01, address(committee));

        vm.startPrank(ownerW.addr);
        account.setValidator(address(router));
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();

        vm.etch(address(0x100), address(new MockP256Ok_Committee()).code);
        vm.deal(address(account), 100 ether);
    }

    // Committee tier-2 sig: [P256(64)][nodeIdsLength=k(32)][per-signer(512)×k][blsSig(256)]. The account
    // prepends accountId when it calls the validator — the submitter never provides it.
    function _committeeT2Sig(uint256 k) internal pure returns (bytes memory) {
        bytes memory signers = new bytes(512 * k);
        bytes memory blsSig = new bytes(256);
        return abi.encodePacked(uint8(0x04), bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), bytes32(k), signers, blsSig);
    }

    function _uo() internal view returns (PackedUserOperation memory op, bytes32 h) {
        op = PackedUserOperation({
            sender: address(account), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""
        });
        h = keccak256(abi.encode(op));
    }

    function _enroll() internal {
        vm.prank(ownerW.addr);
        account.enrollInCommitteeValidator();
    }

    // ── enroll ─────────────────────────────────────────────────────────────────

    function test_enroll_selfProving_marksThisAccount() public {
        assertFalse(committee.enrolled(address(account)));
        _enroll();
        assertTrue(committee.enrolled(address(account))); // msg.sender at validator was the account
    }

    function test_enroll_nonOwner_reverts() public {
        vm.expectRevert();
        account.enrollInCommitteeValidator();
    }

    // ── committee framing: accountId injection + stride ─────────────────────────

    function test_committee_validSig_prependsAccountId_passes() public {
        _enroll();
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeT2Sig(1);
        vm.prank(address(ep));
        // Passes ONLY if the account used the 512 stride AND prepended its own (enrolled) address.
        assertEq(account.validateUserOp(op, h, 0), 0);
    }

    function test_committee_notEnrolled_failsClosed() public {
        // No enroll → the injected accountId maps to a non-enrolled address → validator rejects.
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeT2Sig(1);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    function test_committee_belowQuorum_rejectedByAccount() public {
        _enroll();
        committee.setQuorum(2); // account mirrors k >= requiredQuorum(); k=1 < 2 → reject before validate
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeT2Sig(1);
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    function test_committee_meetsQuorum_passes() public {
        _enroll();
        committee.setQuorum(2);
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeT2Sig(2); // k=2 >= 2
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), 0);
    }

    // ── pr-daemon #203 B1: committee must NOT be short-circuited by a non-zero aggregator() ─────

    /// @dev Triple (0x01) committee sig: [nodeIdsLength=k(32)][per-signer(512)×k][blsSig(256)][ownerSig(65)].
    function _committeeTripleSig(uint256 k, bytes32 userOpHash) internal view returns (bytes memory) {
        bytes memory signers = new bytes(512 * k);
        bytes memory blsSig = new bytes(256);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW, MessageHashUtils.toEthSignedMessageHash(userOpHash));
        return abi.encodePacked(uint8(0x01), bytes32(k), signers, blsSig, abi.encodePacked(r, s, v));
    }

    function test_committee_notShortCircuitedByAggregator() public {
        _enroll();
        committee.setAggregator(address(0xA66)); // a non-zero protocol aggregator on the 0x01 algorithm
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeTripleSig(1, h);
        vm.prank(address(ep));
        // With the !committee guard, the account runs the committee path (validate() → 0 for the enrolled
        // account) instead of deferring to the aggregator (which would return uint160(0xA66) = 2662).
        assertEq(account.validateUserOp(op, h, 0), 0);
    }

    // ── CC-116: committee validator DISARMED (committeeActive()==false) ⇒ tier-2/3 FAILS CLOSED ──
    //
    // A committee validator's validate() falls back to a floorless whole-set path when committee mode is off
    // (migration window before setEpochLength, or committee later disabled). Pre-CC-116 the account rode that
    // path byte-identically (a single registered node passed tier-2/3). The account now distinguishes
    // "committeeActive() returns false" (disarmed committee validator → committeeOff=true → reject) from a
    // TRUE legacy validator whose committeeActive() reverts (committeeOff=false → whole-set, tested below).

    function test_committeeOff_triple_failsClosed() public {
        _enroll();
        committee.setActive(false); // disarmed committee validator (returns false, does NOT revert)
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeTripleSig(1, h); // otherwise-valid committee triple
        vm.prank(address(ep));
        // Even an enrolled account with a well-formed owner+BLS triple is rejected while the floor is missing.
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    function test_committeeOff_cumulativeT2_failsClosed() public {
        _enroll();
        committee.setActive(false);
        // Cumulative tier-2 (0x04): [P256(64)][nodeIdsLength=1(32)][nodeId(32)][blsSig(256)] (legacy shape).
        bytes memory blsSig = new bytes(256);
        bytes memory sig = abi.encodePacked(
            uint8(0x04), bytes32(uint256(0xAA)), bytes32(uint256(0xBB)),
            bytes32(uint256(1)), keccak256("node"), blsSig
        );
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = sig;
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), 1); // pre-CC-116 this returned 0
    }

    function test_committeeOff_notDeferredToAggregator() public {
        _enroll();
        committee.setActive(false);
        committee.setAggregator(address(0xA66)); // a non-zero aggregator must NOT open a bypass around the gate
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _committeeTripleSig(1, h);
        vm.prank(address(ep));
        // The committeeOff gate is placed BEFORE the aggregator deferral, so the result is a clean reject (1),
        // NOT the aggregator address uint160(0xA66) that legacy deferral would return.
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    // ── CC-116 (pr-daemon #208 review): GATE-DISCRIMINATING tests ────────────────────────────────
    //
    // The committeeOff-mode sigs above use the 512-byte committee stride. If the gate at
    // _validateTripleSignature / _validateWeightedSignature is DELETED, `committee` collapses to false,
    // stride collapses to 32, and the sig fails the strict length check — which also returns 1. So those
    // assertions cannot distinguish "gate present" from "gate deleted" (both give 1 via different paths).
    // The mutation review proved deleting those two gates left the whole suite green. These tests close
    // that gap by using a LEGACY-SHAPED payload (32 stride, no accountId) whose length check PASSES, so
    // the ONLY thing standing between the sig and a tier-2/3 pass is the committeeOff gate itself:
    //   gate present  → validateUserOp returns 1  (fail closed ✅)
    //   gate deleted  → validateUserOp returns 0  (the exact CC-116 hole)
    // Verification (mandatory, both directions): delete the corresponding `if (committeeOff)` line → the
    // test MUST go red; restore → green. Confirmed for all three on foundry 1.7.1.

    /// @dev Legacy-shaped triple (32 stride, no accountId): [nodeIdsLength=1(32)][nodeId(32)][blsSig(256)][ownerSig(65)].
    ///      Its post-tag length (385) EQUALS the legacy expectedLength, so the length check does not mask the gate.
    function _legacyShapedTriple(bytes32 userOpHash) internal view returns (bytes memory) {
        bytes memory blsSig = new bytes(256);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW, MessageHashUtils.toEthSignedMessageHash(userOpHash));
        return abi.encodePacked(
            uint8(0x01), bytes32(uint256(1)), keccak256("node"), blsSig, abi.encodePacked(r, s, v)
        );
    }

    function test_committeeOff_legacyShapedTriple_failsClosed() public {
        _enroll();
        committee.setActive(false); // disarmed committee validator
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _legacyShapedTriple(h);
        vm.prank(address(ep));
        // Length check passes (385==385) and the owner ECDSA is valid, so WITHOUT the gate this reaches the
        // whole-set validate() and passes (returns 0). The gate is the only thing that makes it 1.
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    function test_committeeOff_legacyShapedTriple_notDeferredToAggregator() public {
        _enroll();
        committee.setActive(false);
        committee.setAggregator(address(0xA66)); // legacy-shaped so the aggregator deferral WOULD fire if reached
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _legacyShapedTriple(h);
        vm.prank(address(ep));
        // Pins the ordering: the gate sits BEFORE the aggregator deferral. Gate present → 1. If the gate were
        // moved AFTER the deferral, this legacy-shaped sig would defer and return uint160(0xA66) (2662) — a
        // value distinct from 1, so this assertion genuinely discriminates the ordering.
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    /// @dev Weighted (0x07) sig exercising the BLS bit — the first repo test to do so. bitmap = P256|BLS;
    ///      legacy 32-stride BLS block so the block-length check passes when the gate is absent.
    function _weightedBlsSig() internal pure returns (bytes memory) {
        bytes memory blsSig = new bytes(256);
        return abi.encodePacked(
            uint8(0x07),                                     // algId: weighted
            uint8(0x05),                                     // bitmap: bit0 P256 + bit2 BLS
            bytes32(uint256(0xAA)), bytes32(uint256(0xBB)),  // P256 block (64B; mock precompile succeeds)
            bytes32(uint256(1)), keccak256("node"), blsSig   // BLS block: nodeIdsLength=1, nodeId, blsSig
        );
    }

    function test_committeeOff_weightedBls_failsClosed() public {
        _enroll();
        // Weight config where P256(2)+BLS(2)=4 >= tier1Threshold(3), but P256 alone (2) is below it. So
        // WITHOUT the gate the BLS weight lands and the sig passes (returns 0); WITH the gate the BLS block
        // returns 1 before accumulating. No single factor reaches the threshold (passes setWeightConfig checks).
        AAStarAgentStorageLayout.WeightConfig memory wc = AAStarAgentStorageLayout.WeightConfig({
            passkeyWeight: 2, ecdsaWeight: 2, blsWeight: 2,
            guardian0Weight: 1, guardian1Weight: 1, guardian2Weight: 1,
            _padding: 0, tier1Threshold: 3, tier2Threshold: 4, tier3Threshold: 6
        });
        vm.prank(ownerW.addr);
        IAirAccountAgent(address(account)).setWeightConfig(wc);

        committee.setActive(false); // disarmed committee validator
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _weightedBlsSig();
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), 1);
    }

    // ── TRUE legacy validator (committeeActive() reverts) ⇒ whole-set coexistence PRESERVED ──────
    //
    // The gate must only fire on a disarmed committee validator, never on a genuine legacy validator that
    // simply does not implement committeeActive(). These build a fresh account whose router 0x01 is a
    // MockLegacyValidator (no committeeActive()).

    function _legacyAccount() internal returns (AAStarAirAccountV7 acct, MockLegacyValidator legacy) {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0, tier2Limit: 0
        });
        acct = new AAStarAirAccountV7(address(0));
        acct.initialize(address(ep), ownerW.addr, cfg, address(0), bytes32(0), bytes32(0));
        AAStarValidator r = new AAStarValidator();
        legacy = new MockLegacyValidator();
        r.registerAlgorithm(0x01, address(legacy));
        vm.startPrank(ownerW.addr);
        acct.setValidator(address(r));
        acct.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();
        vm.deal(address(acct), 100 ether);
    }

    function test_trueLegacy_wholeSetStillPasses() public {
        (AAStarAirAccountV7 acct,) = _legacyAccount();
        // Legacy tier-2 (0x04): [P256(64)][nodeIdsLength=1(32)][nodeId(32)][blsSig(256)] — 32-byte stride, no
        // accountId. committeeActive() reverts → committeeOff=false → whole-set passthrough, unchanged.
        bytes memory blsSig = new bytes(256);
        bytes memory sig = abi.encodePacked(
            uint8(0x04), bytes32(uint256(0xAA)), bytes32(uint256(0xBB)),
            bytes32(uint256(1)), keccak256("node"), blsSig
        );
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.sender = address(acct);
        h = keccak256(abi.encode(op));
        op.signature = sig;
        vm.prank(address(ep));
        assertEq(acct.validateUserOp(op, h, 0), 0); // coexistence: legacy whole-set NOT broken by the gate
    }

    function test_trueLegacy_stillDefersToAggregator() public {
        (AAStarAirAccountV7 acct, MockLegacyValidator legacy) = _legacyAccount();
        legacy.setAggregator(address(0xA66)); // aggregator deferral remains legacy-only
        bytes memory blsSig = new bytes(256);
        // Build op/hash first so the owner sig binds the real userOpHash.
        PackedUserOperation memory op = PackedUserOperation({
            sender: address(acct), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""
        });
        bytes32 h = keccak256(abi.encode(op));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(
            uint8(0x01), bytes32(uint256(1)), keccak256("node"), blsSig, abi.encodePacked(r, s, v)
        );
        vm.prank(address(ep));
        // Legacy aggregator branch fires and returns the aggregator address (uint160) — unchanged by CC-116.
        assertEq(acct.validateUserOp(op, h, 0), uint256(uint160(address(0xA66))));
    }
}
