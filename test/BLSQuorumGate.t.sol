// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {IAAStarValidatorQuorum} from "../src/interfaces/IAAStarValidatorQuorum.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

contract MockEntryPointQ {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    receive() external payable {}
}

/// @dev Stands in at the account's ALG_BLS slot. `validate()` ALWAYS succeeds, so the ONLY variable
///      that can change the account's decision is the CC-97 committee-quorum gate — this is the
///      "isolate the gate from the cryptography" discipline. Models the real AAStarValidator (PR #235):
///      requiredQuorum() = 0 when off, type(uint256).max when committee < floor, else ceil(2N/3).
contract MockQuorumBLS is IAAStarAlgorithm, IAAStarValidatorQuorum {
    uint256 public n;              // eligible committee size
    bool public quorumOn;
    uint256 constant FLOOR = 3;

    function set(uint256 _n, bool _on) external { n = _n; quorumOn = _on; }

    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }

    function eligibleNodeCount() external view override returns (uint256) { return n; }

    function quorumFor(uint256 x) public pure override returns (uint256) { return (2 * x + 2) / 3; }

    function requiredQuorum() external view override returns (uint256) {
        if (!quorumOn) return 0;
        if (n < FLOOR) return type(uint256).max; // below floor → unsatisfiable, fail-closed
        return quorumFor(n);
    }
}

/// @dev Legacy validator: implements validate() only. requiredQuorum()/eligibleNodeCount() are absent
///      → the account's staticcall reverts → gate must treat as "enforcement not active" (migration-safe).
contract MockLegacyBLS is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }
}

/// @dev Quorum ON but eligibleNodeCount() reverts → account must fail-closed (reject).
contract MockBrokenViewBLS is IAAStarAlgorithm, IAAStarValidatorQuorum {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }
    function requiredQuorum() external pure override returns (uint256) { return 2; } // enforcement ON
    function eligibleNodeCount() external pure override returns (uint256) { revert("boom"); }
    function quorumFor(uint256 x) external pure override returns (uint256) { return (2 * x + 2) / 3; }
}

/// @dev Enforcement ON and eligibleNodeCount() returns an absurd huge value → the gate must reject
///      WITHOUT reverting (2*n overflow must not escape as a validation-phase revert).
contract MockHugeNBLS is IAAStarAlgorithm, IAAStarValidatorQuorum {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }
    function requiredQuorum() external pure override returns (uint256) { return 2; } // enforcement ON
    function eligibleNodeCount() external pure override returns (uint256) { return type(uint256).max; }
    function quorumFor(uint256 x) external pure override returns (uint256) { return (2 * x + 2) / 3; }
}

/// CC-97: the account reads eligibleNodeCount()/requiredQuorum() from the mounted BLS validator and
/// enforces committee >= 3 && signers >= ceil(2N/3) as a second line of defense over dvt's floor.
contract BLSQuorumGateTest is Test {
    AAStarAirAccountV7 account;
    MockQuorumBLS mockBls;
    MockEntryPointQ epMock;
    address entryPointAddr;
    Vm.Wallet ownerWallet;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        epMock = new MockEntryPointQ();
        entryPointAddr = address(epMock);
        mockBls = new MockQuorumBLS();
        account = _deployStack(address(mockBls));
    }

    /// Deploy a fresh account + router wired to `bls` at ALG_BLS. `setValidator` is set-once and
    /// registerAlgorithm is register-once, so each distinct BLS validator needs its own stack.
    function _deployStack(address bls) internal returns (AAStarAirAccountV7 acc) {
        acc = new AAStarAirAccountV7(address(0));
        acc.initialize(entryPointAddr, ownerWallet.addr, _emptyConfig(), address(0), bytes32(0), bytes32(0));
        AAStarValidator r = new AAStarValidator();
        r.registerAlgorithm(0x01, bls); // ALG_BLS
        vm.prank(ownerWallet.addr);
        acc.setValidator(address(r));
        vm.deal(address(acc), 10 ether);
    }

    function _emptyConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: new uint8[](0),
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
    }

    function _userOp() internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: address(account), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""
        });
    }

    /// Triple-sig with `k` node ids: [0x01][len=k(32)][nodeId×k][blsSig(256)][ownerECDSA(65)]
    function _tripleSig(bytes32 userOpHash, uint256 k) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerWallet.privateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash)));
        bytes memory nodeIds;
        for (uint256 i = 0; i < k; i++) {
            nodeIds = abi.encodePacked(nodeIds, keccak256(abi.encodePacked("node", i)));
        }
        return abi.encodePacked(uint8(0x01), uint256(k), nodeIds, new bytes(256), abi.encodePacked(r, s, v));
    }

    /// Run one op with `k` signers against `acc` and return validateUserOp's result (0=pass, 1=fail).
    function _runOn(AAStarAirAccountV7 acc, uint256 k) internal returns (uint256) {
        PackedUserOperation memory op = _userOp();
        op.sender = address(acc);
        bytes32 h = keccak256(abi.encode(op));
        op.signature = _tripleSig(h, k);
        vm.prank(entryPointAddr);
        return acc.validateUserOp(op, h, 0);
    }

    function _run(uint256 k) internal returns (uint256) { return _runOn(account, k); }

    // ── Migration safety: quorum OFF → byte-for-byte unchanged, even 1 signer passes ──
    function test_quorumOff_singleSignerPasses() public {
        mockBls.set(3, false); // enforcement OFF
        assertEq(_run(1), 0, "quorum off: 1 signer must still pass (zero behaviour change)");
    }

    // ── DECISIVE: same signer count (k=2), only committee size N moves. N=3 pass / N=4 reject. ──
    function test_sameSigners_gateMovesWithCommittee() public {
        mockBls.set(3, true);
        assertEq(_run(2), 0, "N=3 (quorum 2): 2 signers must pass");
        mockBls.set(4, true);
        assertEq(_run(2), 1, "N=4 (quorum 3): the SAME 2 signers must now be rejected");
    }

    // ── ceil(2N/3) table (3->2,4->3,5->4,6->4,7->5): boundary just-enough passes, one-below rejects ──
    function test_quorumBoundary_N3() public { mockBls.set(3, true); assertEq(_run(2), 0); assertEq(_run(1), 1); }
    function test_quorumBoundary_N4() public { mockBls.set(4, true); assertEq(_run(3), 0); assertEq(_run(2), 1); }
    function test_quorumBoundary_N5() public { mockBls.set(5, true); assertEq(_run(4), 0); assertEq(_run(3), 1); }
    function test_quorumBoundary_N6() public { mockBls.set(6, true); assertEq(_run(4), 0); assertEq(_run(3), 1); }
    function test_quorumBoundary_N7() public { mockBls.set(7, true); assertEq(_run(5), 0); assertEq(_run(4), 1); }

    // ── Committee floor: N<3 can never satisfy quorum, regardless of signer count ──
    function test_belowMinCommittee_rejected() public {
        mockBls.set(2, true);
        assertEq(_run(2), 1, "committee below floor(3) must be rejected");
    }

    // ── Legacy validator (no quorum views) → enforcement not active → migration-safe pass ──
    function test_legacyValidator_migrationSafePass() public {
        AAStarAirAccountV7 acc = _deployStack(address(new MockLegacyBLS()));
        assertEq(_runOn(acc, 1), 0, "legacy validator without quorum views must not break tier-2/3");
    }

    // ── Enforcement ON but eligibleNodeCount() reverts → fail-closed ──
    function test_brokenView_failClosed() public {
        AAStarAirAccountV7 acc = _deployStack(address(new MockBrokenViewBLS()));
        assertEq(_runOn(acc, 5), 1, "enforcement on + unreadable committee size must fail-closed");
    }

    // ── Enforcement ON + absurd huge committee size → reject, NOT revert (2*n overflow guard) ──
    function test_hugeCommittee_rejectsWithoutRevert() public {
        AAStarAirAccountV7 acc = _deployStack(address(new MockHugeNBLS()));
        assertEq(_runOn(acc, 5), 1, "huge eligibleNodeCount must reject cleanly, never revert validation");
    }
}
