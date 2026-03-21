// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IERC7579Module} from "../interfaces/IERC7579Module.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ─── L2 Bridge Interfaces ──────────────────────────────────────────────────

/// @dev OP Stack L2 withdrawal initiator (precompile at L2_TO_L1_MESSAGE_PASSER_OP)
interface IL2ToL1MessagePasser {
    function initiateWithdrawal(address _target, uint256 _gasLimit, bytes calldata _data) external payable;
}

/// @dev Arbitrum L1 message sender (precompile at ARB_SYS)
interface IArbSys {
    function sendTxToL1(address destination, bytes calldata calldataForL1) external payable returns (uint256);
}

/// @dev Minimal interface to read guardian snapshot from an AirAccount
interface IAirAccountConfig {
    struct AccountConfig {
        address accountOwner;
        address guardAddress;
        uint256 dailyLimit;
        uint256 dailyRemaining;
        uint256 tier1Limit;
        uint256 tier2Limit;
        address[3] guardianAddresses;
        uint8 guardianCount;
        bool hasP256Key;
        bool hasValidator;
        bool hasAggregator;
        bool hasActiveRecovery;
    }
    function getConfigDescription() external view returns (AccountConfig memory);
}

/**
 * @title ForceExitModule
 * @notice ERC-7579 Executor module enabling L2→L1 forced withdrawal with 2-of-3 guardian protection.
 * @dev Installed as moduleTypeId=2 (Executor). Supports OP Stack and Arbitrum One exit paths.
 *
 *      Flow:
 *        1. Account owner calls proposeForceExit() — snapshots guardians, stores proposal.
 *        2. Each guardian calls approveForceExit() with an ECDSA sig over the proposal hash.
 *        3. Anyone calls executeForceExit() once ≥2 approvals are recorded.
 *        4. Owner may call cancelForceExit() at any time before execution.
 *
 *      Guardian signatures bind to: chainId || account || target || value || data || proposedAt
 *      so replays across chains or proposal re-orderings are impossible.
 */
contract ForceExitModule is IERC7579Module {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants ─────────────────────────────────────────────────────────

    uint8 public constant L2_TYPE_OPTIMISM = 1;
    uint8 public constant L2_TYPE_ARBITRUM = 2;

    /// @dev OP Stack L2ToL1MessagePasser precompile (same address on all OP chains)
    address public constant L2_TO_L1_MESSAGE_PASSER_OP = 0x4200000000000000000000000000000000000016;

    /// @dev Arbitrum ArbSys precompile
    address public constant ARB_SYS = 0x0000000000000000000000000000000000000064;

    /// @dev Default gasLimit forwarded with OP Stack withdrawals
    uint256 public constant OP_DEFAULT_GAS_LIMIT = 200_000;

    /// @dev 2-of-3 guardian approval threshold
    uint256 public constant APPROVAL_THRESHOLD = 2;

    // ─── Storage ───────────────────────────────────────────────────────────

    /// @notice Whether this module has been initialized for a given account
    mapping(address account => bool) internal _initialized;

    /// @notice Which L2 type the account is deployed on (1=OP, 2=Arbitrum)
    mapping(address account => uint8) public accountL2Type;

    struct ExitProposal {
        address target;           // L1 recipient address
        uint256 value;            // ETH amount to exit (wei)
        bytes   data;             // Calldata to forward to L1 target
        uint256 proposedAt;       // block.timestamp when proposed
        uint256 approvalBitmap;   // bit i = guardian[i] approved
        address[3] guardians;     // Snapshot from account at propose time
    }

    /// @notice Pending force-exit proposal per account
    mapping(address account => ExitProposal) public pendingExit;

    // ─── Errors ────────────────────────────────────────────────────────────

    error AlreadyProposed();
    error NoProposal();
    error AlreadyApproved();
    error NotEnoughApprovals();
    error InvalidGuardianSig();
    error UnsupportedL2Type();
    error NotOwner();

    // ─── Events ────────────────────────────────────────────────────────────

    event ExitProposed(address indexed account, address indexed target, uint256 value);
    event ExitApproved(address indexed account, address indexed guardian, uint256 bitmap);
    event ExitExecuted(address indexed account, address indexed target, uint256 value);
    event ExitCancelled(address indexed account);

    // ─── IERC7579Module ────────────────────────────────────────────────────

    /// @notice Initialize the module for the calling account.
    /// @param data abi.encode(uint8 l2Type) — 1=OP Stack, 2=Arbitrum
    function onInstall(bytes calldata data) external override {
        _initialized[msg.sender] = true;
        if (data.length == 0) return;
        uint8 l2Type = abi.decode(data, (uint8));
        accountL2Type[msg.sender] = l2Type;
    }

    /// @notice Remove the module from the calling account.
    function onUninstall(bytes calldata /* data */) external override {
        delete _initialized[msg.sender];
        delete accountL2Type[msg.sender];
        delete pendingExit[msg.sender];
    }

    /// @notice Returns true if the module is installed for the given account.
    function isInitialized(address smartAccount) external view override returns (bool) {
        return _initialized[smartAccount];
    }

    // ─── Proposal Lifecycle ────────────────────────────────────────────────

    /**
     * @notice Propose a force-exit withdrawal. Must be called by the account owner.
     * @dev Reads guardian addresses from the account via getConfigDescription() staticcall.
     *      Reverts with AlreadyProposed if a proposal is already pending.
     * @param target  L1 address that will receive the ETH and/or calldata
     * @param value   ETH amount in wei to exit
     * @param data    Calldata to forward to target on L1
     */
    function proposeForceExit(address target, uint256 value, bytes calldata data) external {
        ExitProposal storage proposal = pendingExit[msg.sender];
        if (proposal.proposedAt != 0) revert AlreadyProposed();

        // Read guardian snapshot from the account
        address[3] memory guardians = _readGuardians(msg.sender);

        proposal.target      = target;
        proposal.value       = value;
        proposal.data        = data;
        proposal.proposedAt  = block.timestamp;
        proposal.approvalBitmap = 0;
        proposal.guardians   = guardians;

        emit ExitProposed(msg.sender, target, value);
    }

    /**
     * @notice Guardian approves the pending force-exit proposal.
     * @dev Verifies ECDSA signature over keccak256("FORCE_EXIT" || chainId || account || target || value || data || proposedAt).
     *      Each guardian may only approve once. Bit i in approvalBitmap corresponds to guardians[i].
     * @param account     The AA account whose proposal is being approved
     * @param guardianSig ECDSA signature (65 bytes) from the approving guardian
     */
    function approveForceExit(address account, bytes calldata guardianSig) external {
        ExitProposal storage proposal = pendingExit[account];
        if (proposal.proposedAt == 0) revert NoProposal();

        // Compute proposal hash
        bytes32 msgHash = _proposalHash(
            account,
            proposal.target,
            proposal.value,
            proposal.data,
            proposal.proposedAt
        );

        // Recover signer
        address signer = msgHash.toEthSignedMessageHash().recover(guardianSig);

        // Match signer to a guardian slot
        uint256 bit = _guardianBit(proposal.guardians, signer);
        if (bit == type(uint256).max) revert InvalidGuardianSig();

        // Check not already approved
        if (proposal.approvalBitmap & (uint256(1) << bit) != 0) revert AlreadyApproved();

        proposal.approvalBitmap |= (uint256(1) << bit);

        emit ExitApproved(account, signer, proposal.approvalBitmap);
    }

    /**
     * @notice Execute the force-exit after 2-of-3 guardian approvals.
     * @dev Callable by anyone once the threshold is met.
     *      Calls the appropriate L2 precompile and transfers the account's ETH.
     *      Clears the proposal on success.
     * @param account The AA account to execute the exit for
     */
    function executeForceExit(address account) external {
        ExitProposal storage proposal = pendingExit[account];
        if (proposal.proposedAt == 0) revert NoProposal();

        uint256 approvals = _countBits(proposal.approvalBitmap);
        if (approvals < APPROVAL_THRESHOLD) revert NotEnoughApprovals();

        address target = proposal.target;
        uint256 value  = proposal.value;
        bytes memory exitData = proposal.data;

        // Clear proposal before external call (re-entrancy guard)
        delete pendingExit[account];

        uint8 l2Type = accountL2Type[account];

        if (l2Type == L2_TYPE_OPTIMISM) {
            IL2ToL1MessagePasser(L2_TO_L1_MESSAGE_PASSER_OP).initiateWithdrawal{value: value}(
                target,
                OP_DEFAULT_GAS_LIMIT,
                exitData
            );
        } else if (l2Type == L2_TYPE_ARBITRUM) {
            IArbSys(ARB_SYS).sendTxToL1{value: value}(target, exitData);
        } else {
            revert UnsupportedL2Type();
        }

        emit ExitExecuted(account, target, value);
    }

    /**
     * @notice Cancel the pending force-exit proposal. Only the account owner can cancel.
     * @dev The account itself calls this — msg.sender is the AA account address.
     *      To cancel from an EOA wallet, call via the account's execute().
     * @param account The AA account whose proposal to cancel
     */
    /// @notice Explicit getter for the full ExitProposal struct (including bytes and address[3]).
    ///         The auto-generated public mapping getter omits dynamic and array fields.
    function getPendingExit(address account) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposedAt,
        uint256 approvalBitmap,
        address[3] memory guardians
    ) {
        ExitProposal storage p = pendingExit[account];
        return (p.target, p.value, p.data, p.proposedAt, p.approvalBitmap, p.guardians);
    }

    function cancelForceExit(address account) external {
        // Caller must be the account owner (account calls on its own behalf via execute())
        // or the account itself (msg.sender == account)
        if (msg.sender != account) {
            // Check if msg.sender is the owner of `account`
            address owner = _readOwner(account);
            if (msg.sender != owner) revert NotOwner();
        }

        ExitProposal storage proposal = pendingExit[account];
        if (proposal.proposedAt == 0) revert NoProposal();

        delete pendingExit[account];

        emit ExitCancelled(account);
    }

    // ─── Internal Helpers ──────────────────────────────────────────────────

    /// @dev Read guardian addresses from an AirAccount via staticcall to getConfigDescription()
    function _readGuardians(address account) internal view returns (address[3] memory guardians) {
        (bool ok, bytes memory returnData) = account.staticcall(
            abi.encodeWithSignature("getConfigDescription()")
        );
        if (ok && returnData.length >= 32) {
            // AccountConfig is a complex struct; decode the full thing and extract guardianAddresses
            // The struct layout: accountOwner(addr), guardAddress(addr), dailyLimit(u256), dailyRemaining(u256),
            //                    tier1Limit(u256), tier2Limit(u256), guardianAddresses(addr[3]),
            //                    guardianCount(u8), hasP256Key(bool), hasValidator(bool),
            //                    hasAggregator(bool), hasActiveRecovery(bool)
            IAirAccountConfig.AccountConfig memory cfg = abi.decode(
                returnData,
                (IAirAccountConfig.AccountConfig)
            );
            guardians = cfg.guardianAddresses;
        }
        // If staticcall fails, guardians remain [0,0,0] — execution will fail at approval threshold
    }

    /// @dev Read the owner address from an AirAccount via staticcall
    function _readOwner(address account) internal view returns (address owner) {
        (bool ok, bytes memory returnData) = account.staticcall(
            abi.encodeWithSignature("owner()")
        );
        if (ok && returnData.length >= 32) {
            owner = abi.decode(returnData, (address));
        }
    }

    /// @dev Compute the EIP-191 pre-image hash for a force-exit proposal
    function _proposalHash(
        address account,
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposedAt
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "FORCE_EXIT",
                block.chainid,
                account,
                target,
                value,
                data,
                proposedAt
            )
        );
    }

    /// @dev Find which guardian index corresponds to `signer`. Returns type(uint256).max if not found.
    function _guardianBit(address[3] memory guardians, address signer) internal pure returns (uint256) {
        for (uint256 i = 0; i < 3; i++) {
            if (guardians[i] == signer) return i;
        }
        return type(uint256).max;
    }

    /// @dev Count the number of set bits in a uint256 (popcount)
    function _countBits(uint256 bitmap) internal pure returns (uint256 count) {
        while (bitmap != 0) {
            count += bitmap & 1;
            bitmap >>= 1;
        }
    }
}
