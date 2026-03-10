// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AAStarGlobalGuard — Immutable spending guard bound to an AA account
/// @notice Deployed BY the account contract at construction. Cannot be removed or transferred.
/// @dev Configuration is monotonic: daily limit can only decrease, algorithms can only be added.
///      Guard.account is immutable — social recovery changes Account.owner, not Account address,
///      so guard always remains functional regardless of key rotation.
contract AAStarGlobalGuard {
    // ─── Immutable State ─────────────────────────────────────────

    /// @notice The AA account that owns this guard (set at construction, never changes)
    address public immutable account;

    // ─── Mutable State ──────────────────────────────────────────

    /// @notice Daily spending limit in wei (0 = unlimited)
    uint256 public dailyLimit;

    /// @notice Tracks spending per day (day number → amount spent)
    mapping(uint256 => uint256) public dailySpent;

    /// @notice Algorithm whitelist: only approved algIds can be used for transactions
    mapping(uint8 => bool) public approvedAlgorithms;

    // ─── Events ─────────────────────────────────────────────────

    event DailyLimitDecreased(uint256 oldLimit, uint256 newLimit);
    event AlgorithmApproved(uint8 indexed algId);
    event SpendRecorded(uint256 indexed day, uint256 amount, uint256 totalSpent);

    // ─── Errors ─────────────────────────────────────────────────

    error OnlyAccount();
    error CanOnlyDecreaseLimit(uint256 current, uint256 requested);
    error DailyLimitExceeded(uint256 requested, uint256 remaining);
    error AlgorithmNotApproved(uint8 algId);

    // ─── Modifier ───────────────────────────────────────────────

    modifier onlyAccount() {
        if (msg.sender != account) revert OnlyAccount();
        _;
    }

    // ─── Constructor ────────────────────────────────────────────

    /// @param _account The AA account contract address (immutable binding)
    /// @param _dailyLimit Daily spending limit in wei (0 = unlimited)
    /// @param _algIds Initial approved algorithm IDs
    constructor(address _account, uint256 _dailyLimit, uint8[] memory _algIds) {
        account = _account;
        dailyLimit = _dailyLimit;
        for (uint256 i = 0; i < _algIds.length; i++) {
            approvedAlgorithms[_algIds[i]] = true;
            emit AlgorithmApproved(_algIds[i]);
        }
    }

    // ─── Guard Checks (called by account in execute) ────────────

    /// @notice Check if a transaction is allowed by the guard.
    /// @param value The ETH value of the transaction
    /// @param algId The algorithm used for signature verification
    /// @return True if allowed
    function checkTransaction(uint256 value, uint8 algId) external onlyAccount returns (bool) {
        if (!approvedAlgorithms[algId]) revert AlgorithmNotApproved(algId);

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

    // ─── Monotonic Configuration (only tighten, never loosen) ───

    /// @notice Decrease daily limit. Can NEVER increase.
    function decreaseDailyLimit(uint256 _newLimit) external onlyAccount {
        if (_newLimit >= dailyLimit) {
            revert CanOnlyDecreaseLimit(dailyLimit, _newLimit);
        }
        uint256 old = dailyLimit;
        dailyLimit = _newLimit;
        emit DailyLimitDecreased(old, _newLimit);
    }

    /// @notice Add a new approved algorithm. Can NEVER revoke.
    function approveAlgorithm(uint8 algId) external onlyAccount {
        approvedAlgorithms[algId] = true;
        emit AlgorithmApproved(algId);
    }
}
