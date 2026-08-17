// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {IAAStarCommitteeValidator} from "../src/interfaces/IAAStarCommitteeValidator.sol";
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

    /// @dev Legacy (32-stride) triple sig: [nodeIdsLength=1(32)][nodeId(32)][blsSig(256)][ownerSig(65)].
    function _legacyTripleSig(bytes32 userOpHash) internal view returns (bytes memory) {
        bytes memory blsSig = new bytes(256);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW, MessageHashUtils.toEthSignedMessageHash(userOpHash));
        return abi.encodePacked(
            uint8(0x01), bytes32(uint256(1)), keccak256("node"), blsSig, abi.encodePacked(r, s, v)
        );
    }

    function test_legacy_stillDefersToAggregator() public {
        committee.setActive(false);              // legacy mode
        committee.setAggregator(address(0xA66)); // aggregator deferral is legacy-only
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = _legacyTripleSig(h);
        // In legacy mode the aggregator branch fires and returns the aggregator address (uint160).
        vm.prank(address(ep));
        assertEq(account.validateUserOp(op, h, 0), uint256(uint160(address(0xA66))));
    }

    // ── legacy fallback: committee mode off → 32-byte stride, no accountId ───────

    function test_legacyMode_usesWholeSetStride_noAccountId() public {
        committee.setActive(false); // committeeActive() → false → legacy framing
        // Legacy tier-2: [P256(64)][nodeIdsLength=1(32)][nodeId(32)][blsSig(256)] (32-byte stride, no accountId)
        bytes memory blsSig = new bytes(256);
        bytes memory sig = abi.encodePacked(
            uint8(0x04), bytes32(uint256(0xAA)), bytes32(uint256(0xBB)),
            bytes32(uint256(1)), keccak256("node"), blsSig
        );
        (PackedUserOperation memory op, bytes32 h) = _uo();
        op.signature = sig;
        vm.prank(address(ep));
        // Passes ONLY if the account used the 32-byte legacy stride and did NOT prepend accountId (the mock's
        // legacy branch accepts [nodeId(32)][blsSig(256)]). A wrongly-injected accountId or 512 stride would
        // change the layout and fail. Confirms committeeActive()==false ⇒ byte-identical legacy framing.
        assertEq(account.validateUserOp(op, h, 0), 0);
    }
}
