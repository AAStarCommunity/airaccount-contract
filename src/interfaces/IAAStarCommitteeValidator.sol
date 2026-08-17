// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IAAStarCommitteeValidator — account-side view of the CC-98 per-proposal committee BLS validator
/// @notice The mounted BLS algorithm (router algId 0x01) is, from v0.30.0 on, a per-proposal committee
///         validator (repo:dvt YetAnotherAA-Validator PR #237, `AAStarCommitteeValidator is AAStarValidator`).
///         The account reads `committeeActive()` to choose its signature framing (inject accountId +
///         committee layout) instead of guessing from the payload shape — that shape-collision is the root
///         of the flip-order forgery (CC-98 B2). Same validator state drives both the validator's parse and
///         the account's framing, so there is no cross-repo desync window.
/// @dev    All three members MUST be resolved fail-safe (try/catch) at the account: a legacy validator that
///         does not implement `committeeActive()`/`requiredQuorum()` reverts, which the account treats as
///         "committee off" (legacy whole-set framing) / "quorum unreadable → fail-closed". Never let any of
///         these revert the ERC-4337 validation phase.
interface IAAStarCommitteeValidator {
    /// @notice True iff committee mode is active (validator's `epochLength != 0`).
    function committeeActive() external view returns (bool);

    /// @notice Required signer count ⌈2·m_e/3⌉ for the epoch active now (over the look-ahead set
    ///         `setRoot[e-1]`). Returns `type(uint256).max` when the prerequisite snapshot is missing, so
    ///         a `k >= requiredQuorum()` mirror check fails closed.
    function requiredQuorum() external view returns (uint256);

    /// @notice Self-enroll the caller (the account) for committee validation. `msg.sender` IS the account,
    ///         so enrollment is self-proving. Defense-in-depth for the account-injected accountId: the
    ///         validator fails closed on any accountId that maps to a non-enrolled address.
    function enroll() external;
}
