// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AAStarGlobalGuard - Hardcoded spending limits and algorithm whitelist
/// @notice Immutable guard: daily spending limits and algorithm approval.
///         Checked before every transaction execution.
/// @dev Per-account contract, deployed alongside the account.
contract AAStarGlobalGuard {
    // ─── Storage ────────────────────────────────────────────────────

    /// @notice Account owner
    address public owner;

    /// @notice Daily spending limit in wei (0 = unlimited)
    uint256 public dailyLimit;

    /// @notice Tracks spending per day (day number → amount spent)
    mapping(uint256 => uint256) public dailySpent;

    /// @notice Algorithm whitelist: only approved algIds can be used
    mapping(uint8 => bool) public approvedAlgorithms;

    // ─── Events ─────────────────────────────────────────────────────

    event DailyLimitSet(uint256 oldLimit, uint256 newLimit);
    event AlgorithmApproved(uint8 indexed algId);
    event AlgorithmRevoked(uint8 indexed algId);
    event SpendRecorded(uint256 indexed day, uint256 amount, uint256 totalSpent);

    // ─── Errors ─────────────────────────────────────────────────────

    error OnlyOwner();
    error DailyLimitExceeded(uint256 requested, uint256 remaining);
    error AlgorithmNotApproved(uint8 algId);
    error ZeroLimit();

    // ─── Constructor ────────────────────────────────────────────────

    constructor(address _owner, uint256 _dailyLimit) {
        owner = _owner;
        dailyLimit = _dailyLimit;
    }

    // ─── Guard Checks ───────────────────────────────────────────────

    /// @notice Check if a transaction is allowed by the guard.
    /// @param value The ETH value of the transaction
    /// @param algId The algorithm used for signature verification
    /// @return True if allowed
    function checkTransaction(uint256 value, uint8 algId) external returns (bool) {
        // Algorithm whitelist check (if any algorithms are approved)
        if (!approvedAlgorithms[algId]) revert AlgorithmNotApproved(algId);

        // Daily limit check
        if (dailyLimit > 0 && value > 0) {
            uint256 today = block.timestamp / 1 days;
            uint256 spent = dailySpent[today];
            uint256 remaining = dailyLimit > spent ? dailyLimit - spent : 0;
            if (value > remaining) {
                revert DailyLimitExceeded(value, remaining);
            }
            dailySpent[today] = spent + value;
            emit SpendRecorded(today, value, spent + value);
        }

        return true;
    }

    /// @notice Query remaining daily allowance
    function remainingDailyAllowance() external view returns (uint256) {
        if (dailyLimit == 0) return type(uint256).max;
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[today];
        return dailyLimit > spent ? dailyLimit - spent : 0;
    }

    // ─── Configuration (owner only) ─────────────────────────────────

    function setDailyLimit(uint256 _limit) external {
        if (msg.sender != owner) revert OnlyOwner();
        uint256 old = dailyLimit;
        dailyLimit = _limit;
        emit DailyLimitSet(old, _limit);
    }

    function approveAlgorithm(uint8 algId) external {
        if (msg.sender != owner) revert OnlyOwner();
        approvedAlgorithms[algId] = true;
        emit AlgorithmApproved(algId);
    }

    function revokeAlgorithm(uint8 algId) external {
        if (msg.sender != owner) revert OnlyOwner();
        approvedAlgorithms[algId] = false;
        emit AlgorithmRevoked(algId);
    }
}
