// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IAAStarValidatorQuorum — committee-quorum read interface exposed by the BLS validator
/// @notice CC-97: tier-2/3 BLS aggregate signing requires an on-chain committee quorum. The
///         authoritative floor lives in the validator's `validate()` (repo:dvt, PR #235); the
///         account reads these views to enforce the SAME rule a second time as defense-in-depth
///         (policy belongs to the account, isomorphic with tier limits — CC-10 Decision A).
/// @dev Signature contract locked with repo:dvt on 2026-08-16 (Seeder CC-97):
///      all three are the exact selectors the deployed `AAStarValidator` (new 0x539B) exposes.
///      A legacy validator that does not implement these makes the staticcall revert; the account
///      treats that as "quorum enforcement not active" (migration-safe) — see AAStarAirAccountBase.
interface IAAStarValidatorQuorum {
    /// @notice The eligible signing committee size N: registered AND (when `requireStake` is on)
    ///         staked nodes, excluding retired bootstrap nodes. This is the correct denominator for
    ///         ceil(2N/3) — NOT the raw `activeNodeCount()` (which includes bootstrap).
    /// @dev Same value the validator's own `validate()` gate uses (`_eligibleNodeCount()`), read in
    ///      the same userOp validation frame → the account never rejects what the validator accepts.
    function eligibleNodeCount() external view returns (uint256);

    /// @notice The number of distinct signers `validate()` currently requires: 0 when quorum
    ///         enforcement is OFF (migration-safe default), `type(uint256).max` when the committee is
    ///         below the minimum (unsatisfiable, fail-closed), otherwise ceil(2N/3).
    function requiredQuorum() external view returns (uint256);

    /// @notice Pure ceil(2n/3) helper (3->2, 4->3, 5->4, 6->4, 7->5). Provided for off/on-chain
    ///         cross-checks; the account recomputes the bound itself rather than trusting a returned value.
    function quorumFor(uint256 n) external pure returns (uint256);
}
