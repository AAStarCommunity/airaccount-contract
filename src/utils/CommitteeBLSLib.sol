// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";
import {IAAStarCommitteeValidator} from "../interfaces/IAAStarCommitteeValidator.sol";

/// @title CommitteeBLSLib — externalized CC-98 committee BLS framing (EIP-170 headroom)
/// @notice Extracted from AAStarAirAccountBase to keep the non-upgradable account impl under EIP-170.
///         Deployed once and linked into the impl/extension (like WebAuthnLib), so its `external`
///         function is delegatecalled and runs in the ACCOUNT's context. The account passes its OWN
///         accountId (= address(this)); the submitter never supplies it — this is the CC-98 B2 injection
///         invariant, kept identical to the in-contract version (byte-for-byte same validator call).
/// @dev    DEPLOY LANDMINE (mirror WebAuthnLib): the impl/extension bytecode carries a `__$…$__` link
///         placeholder for this library. Deploy CommitteeBLSLib FIRST and link its address, or the shipped
///         account bytecode is broken. `forge test` links libraries automatically; the deploy script must
///         link explicitly (add to the LIBRARIES map).
library CommitteeBLSLib {
    /// @dev Verify a BLS aggregate over the `[signers...][blsSig(256)]` region (nodeIdsLength prefix
    ///      already stripped). Legacy (`committee == false`): pass the region straight to the whole-set
    ///      validator — byte-identical to the pre-CC-98 path. Committee (`committee == true`): mirror the
    ///      validator's `k >= requiredQuorum()` floor (read fail-safe; unreadable → sentinel max →
    ///      fail-closed) and PREPEND the account-injected accountId before calling validate(). Membership /
    ///      Merkle / sortition correctness stays the validator's authority. Fail-closed, never reverts
    ///      (ERC-4337/7562: the account's validation phase must return, not revert).
    function verifyAgg(
        address blsAlg,
        bool committee,
        bytes32 accountId,
        bytes32 userOpHash,
        uint256 k,
        bytes calldata signersAndSig
    ) external view returns (bool) {
        if (blsAlg == address(0)) return false;
        if (!committee) {
            try IAAStarAlgorithm(blsAlg).validate(userOpHash, signersAndSig) returns (uint256 r) {
                return r == 0;
            } catch {
                return false;
            }
        }
        uint256 required;
        try IAAStarCommitteeValidator(blsAlg).requiredQuorum() returns (uint256 q) {
            required = q;
        } catch {
            required = type(uint256).max;
        }
        if (k < required) return false;
        bytes memory payload = abi.encodePacked(accountId, signersAndSig);
        try IAAStarAlgorithm(blsAlg).validate(userOpHash, payload) returns (uint256 r) {
            return r == 0;
        } catch {
            return false;
        }
    }
}
