// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AAStarGlobalGuard — Immutable spending guard bound to an AA account
/// @notice Deployed BY the account contract at construction. Cannot be removed or transferred.
/// @dev Configuration is monotonic: daily limit can only decrease, algorithms can only be added,
///      token configs can only be added (never removed), token daily limits can only decrease.
///      Guard.account is immutable — social recovery changes Account.owner, not Account address,
///      so guard always remains functional regardless of key rotation.
contract AAStarGlobalGuard {
    // ─── Token Config Struct ─────────────────────────────────────

    /// @notice Per-token spending tier configuration (in token's native units)
    struct TokenConfig {
        uint256 tier1Limit; // max cumulative amount for Tier 1 (ECDSA only)
        uint256 tier2Limit; // max cumulative amount for Tier 2 (P256+BLS)
        uint256 dailyLimit; // total daily cap (0 = unlimited)
    }

    // ─── Immutable State ─────────────────────────────────────────

    /// @notice The AA account that owns this guard (set at construction, never changes)
    address public immutable account;

    /// @notice Absolute floor — daily limit can never be decreased below this value.
    uint256 public immutable minDailyLimit;

    // ─── ETH Mutable State ──────────────────────────────────────

    /// @notice Daily ETH spending limit in wei (0 = unlimited)
    uint256 public dailyLimit;

    /// @notice Tracks ETH spending per day (day number → amount spent)
    mapping(uint256 => uint256) public dailySpent;

    /// @notice Algorithm whitelist: only approved algIds can be used for transactions
    mapping(uint8 => bool) public approvedAlgorithms;

    // ─── ERC20 Token State ───────────────────────────────────────

    /// @notice Per-token tier and daily limit configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Tracks token spending per day: token → day → amount spent
    mapping(address => mapping(uint256 => uint256)) public tokenDailySpent;

    // ─── Events ─────────────────────────────────────────────────

    event DailyLimitDecreased(uint256 oldLimit, uint256 newLimit);
    event AlgorithmApproved(uint8 indexed algId);
    event SpendRecorded(uint256 indexed day, uint256 amount, uint256 totalSpent);
    event TokenConfigAdded(address indexed token, uint256 tier1Limit, uint256 tier2Limit, uint256 dailyLimit);
    event TokenDailyLimitDecreased(address indexed token, uint256 oldLimit, uint256 newLimit);
    event TokenSpendRecorded(address indexed token, uint256 indexed day, uint256 amount, uint256 totalSpent);

    // ─── Errors ─────────────────────────────────────────────────

    error OnlyAccount();
    error CanOnlyDecreaseLimit(uint256 current, uint256 requested);
    error BelowMinDailyLimit(uint256 requested, uint256 minimum);
    error DailyLimitExceeded(uint256 requested, uint256 remaining);
    error AlgorithmNotApproved(uint8 algId);
    error TokenAlreadyConfigured(address token);
    error TokenCanOnlyDecreaseLimit(address token, uint256 current, uint256 requested);
    error TokenDailyLimitExceeded(address token, uint256 requested, uint256 remaining);
    error InsufficientTokenTier(uint8 required, uint8 provided);
    /// @dev Fired when token tier/daily limits are logically inconsistent:
    ///      tier1 <= tier2 <= dailyLimit (when non-zero) must hold, otherwise
    ///      the daily limit silently caps users below their configured tier max.
    error InvalidTokenConfig(address token, uint256 tier1, uint256 tier2, uint256 daily);

    // ─── Modifier ───────────────────────────────────────────────

    modifier onlyAccount() {
        if (msg.sender != account) revert OnlyAccount();
        _;
    }

    /// @dev Validate token tier/daily config coherence.
    ///      Rules (each only checked when both values are non-zero):
    ///        tier1 <= tier2   — tier2 range must start above tier1 max
    ///        tier2 <= daily   — daily cap must cover the full tier2 range
    ///        tier1 <= daily   — daily cap must cover at least tier1 range
    function _validateTokenConfig(address token, uint256 t1, uint256 t2, uint256 daily) internal pure {
        bool bad = (t1 > 0 && t2 > 0 && t1 > t2)
            || (t2 > 0 && daily > 0 && daily < t2)
            || (t1 > 0 && t2 == 0 && daily > 0 && daily < t1)
            || ((t1 > 0 || t2 > 0) && daily == 0); // tier limits require dailyLimit > 0 for cumulative tracking
        if (bad) revert InvalidTokenConfig(token, t1, t2, daily);
    }

    // ─── Constructor ────────────────────────────────────────────

    /// @param _account          The AA account contract address (immutable binding)
    /// @param _dailyLimit       ETH daily spending limit in wei (0 = unlimited)
    /// @param _algIds           Initial approved algorithm IDs
    /// @param _minDailyLimit    Floor for ETH daily limit (0 = no floor)
    /// @param _initialTokens    ERC20 token addresses with initial configs (may be empty)
    /// @param _initialConfigs   Per-token tier/daily configs, 1:1 with _initialTokens
    constructor(
        address _account,
        uint256 _dailyLimit,
        uint8[] memory _algIds,
        uint256 _minDailyLimit,
        address[] memory _initialTokens,
        TokenConfig[] memory _initialConfigs
    ) {
        require(_initialTokens.length == _initialConfigs.length, "length mismatch");
        account = _account;
        dailyLimit = _dailyLimit;
        minDailyLimit = _minDailyLimit;
        for (uint256 i = 0; i < _algIds.length; i++) {
            approvedAlgorithms[_algIds[i]] = true;
            emit AlgorithmApproved(_algIds[i]);
        }
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            address tok = _initialTokens[i];
            TokenConfig memory cfg = _initialConfigs[i];
            _validateTokenConfig(tok, cfg.tier1Limit, cfg.tier2Limit, cfg.dailyLimit);
            tokenConfigs[tok] = cfg;
            emit TokenConfigAdded(tok, cfg.tier1Limit, cfg.tier2Limit, cfg.dailyLimit);
        }
    }

    // ─── ETH Guard Checks ───────────────────────────────────────

    /// @notice Check if an ETH transaction is allowed.
    ///         Enforces algorithm whitelist and ETH daily limit.
    ///         Tier enforcement is handled by the account (reads todaySpent for cumulative check).
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

    /// @notice Query remaining ETH daily allowance
    function remainingDailyAllowance() external view returns (uint256) {
        if (dailyLimit == 0) return type(uint256).max;
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[today];
        return dailyLimit > spent ? dailyLimit - spent : 0;
    }

    /// @notice Query ETH spent today (for account's cumulative tier enforcement)
    function todaySpent() external view returns (uint256) {
        return dailySpent[block.timestamp / 1 days];
    }

    // ─── ERC20 Token Guard Checks ────────────────────────────────

    /// @notice Check if an ERC20 token transaction is allowed.
    ///         Enforces algorithm whitelist, token tier limits (cumulative), and token daily limit.
    ///         If token is not configured, passes through with no limits applied.
    /// @param token    ERC20 token contract address (= calldata dest)
    /// @param amount   Token amount from parsed calldata (transfer/approve amount)
    /// @param algId    Algorithm used for this UserOp
    function checkTokenTransaction(address token, uint256 amount, uint8 algId) external onlyAccount returns (bool) {
        if (!approvedAlgorithms[algId]) revert AlgorithmNotApproved(algId);

        TokenConfig memory cfg = tokenConfigs[token];
        // Unconfigured token: no limits applied, pass through
        if (cfg.tier1Limit == 0 && cfg.tier2Limit == 0 && cfg.dailyLimit == 0) {
            return true;
        }

        uint256 today = block.timestamp / 1 days;
        uint256 spent = tokenDailySpent[token][today];
        uint256 cumulative = spent + amount;

        // Tier enforcement using cumulative spend (prevents batch bypass)
        if (cfg.tier1Limit > 0 || cfg.tier2Limit > 0) {
            uint8 required;
            if (cfg.tier1Limit > 0 && cumulative <= cfg.tier1Limit) {
                required = 1;
            } else if (cfg.tier2Limit == 0 || cumulative <= cfg.tier2Limit) {
                required = 2;
            } else {
                required = 3;
            }
            uint8 provided = _algTier(algId);
            if (provided < required) revert InsufficientTokenTier(required, provided);
        }

        // Daily limit enforcement + spend recording
        if (cfg.dailyLimit > 0 && amount > 0) {
            uint256 remaining = cfg.dailyLimit > spent ? cfg.dailyLimit - spent : 0;
            if (amount > remaining) revert TokenDailyLimitExceeded(token, amount, remaining);
            tokenDailySpent[token][today] = cumulative;
            emit TokenSpendRecorded(token, today, amount, cumulative);
        }

        return true;
    }

    /// @notice Query token spent today (for off-chain monitoring / dashboards)
    function tokenTodaySpent(address token) external view returns (uint256) {
        return tokenDailySpent[token][block.timestamp / 1 days];
    }

    // ─── Monotonic Token Configuration ──────────────────────────

    /// @notice Add a new ERC20 token config. Monotonic: can only ADD, never remove.
    ///         Reverts if token is already configured.
    function addTokenConfig(address token, TokenConfig calldata config) external onlyAccount {
        TokenConfig memory existing = tokenConfigs[token];
        if (existing.tier1Limit != 0 || existing.tier2Limit != 0 || existing.dailyLimit != 0) {
            revert TokenAlreadyConfigured(token);
        }
        _validateTokenConfig(token, config.tier1Limit, config.tier2Limit, config.dailyLimit);
        tokenConfigs[token] = config;
        emit TokenConfigAdded(token, config.tier1Limit, config.tier2Limit, config.dailyLimit);
    }

    /// @notice Decrease a token's daily limit. Can NEVER increase.
    ///         Cannot decrease to 0 when tier limits are configured — that would break cumulative tracking.
    function decreaseTokenDailyLimit(address token, uint256 newLimit) external onlyAccount {
        TokenConfig storage cfg = tokenConfigs[token];
        if (newLimit >= cfg.dailyLimit) {
            revert TokenCanOnlyDecreaseLimit(token, cfg.dailyLimit, newLimit);
        }
        if (newLimit == 0 && (cfg.tier1Limit > 0 || cfg.tier2Limit > 0)) {
            revert InvalidTokenConfig(token, cfg.tier1Limit, cfg.tier2Limit, newLimit);
        }
        uint256 old = cfg.dailyLimit;
        cfg.dailyLimit = newLimit;
        emit TokenDailyLimitDecreased(token, old, newLimit);
    }

    // ─── Monotonic ETH Configuration ────────────────────────────

    /// @notice Decrease ETH daily limit. Can NEVER increase. Cannot go below minDailyLimit.
    function decreaseDailyLimit(uint256 _newLimit) external onlyAccount {
        if (_newLimit >= dailyLimit) {
            revert CanOnlyDecreaseLimit(dailyLimit, _newLimit);
        }
        if (_newLimit < minDailyLimit) {
            revert BelowMinDailyLimit(_newLimit, minDailyLimit);
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

    // ─── Internal ───────────────────────────────────────────────

    /// @dev Maps algId to security tier level. Must stay in sync with account's _algTier.
    ///      When new algIds are added to the account, update this mapping too.
    function _algTier(uint8 algId) internal pure returns (uint8) {
        if (algId == 0x05 || algId == 0x01) return 3;          // ALG_CUMULATIVE_T3, ALG_BLS legacy triple
        if (algId == 0x04) return 2;                           // CUMULATIVE_T2 (P256 + BLS dual-factor)
        if (algId == 0x02 || algId == 0x03 || algId == 0x06) return 1; // ECDSA, bare P256, COMBINED_T1
        return 0;
    }
}
