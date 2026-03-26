// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";

/// @dev ERC-5564 Announcer interface (deployed on mainnet/testnet by ERC-5564 authors)
interface IERC5564Announcer {
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external;
}

/**
 * @title AirAccountDelegate
 * @notice EIP-7702 compatible AirAccount implementation contract.
 *
 * Business scenario: An existing EOA (MetaMask wallet, etc.) wants AirAccount features
 * (daily limit, guardian recovery, ERC-4337 support) WITHOUT changing their address.
 * The EOA sends a Type 4 transaction delegating to this contract, then calls initialize().
 *
 * Key design differences from AirAccountV7:
 *  - owner() = address(this)  — the EOA IS the account, no separate owner address
 *  - ERC-7201 namespaced storage — avoids collision with any prior EOA storage slots
 *  - No constructor initialization — EOA calls initialize() after delegation is active
 *  - Guardian rescue (not owner rotation) — recovery transfers assets to a new address
 *  - Deployed once, referenced by all 7702 delegates (singleton implementation)
 *
 * EIP-7702 activation flow:
 *  1. User sends Type 4 tx with authorization_list = [{chainId, address(this), nonce, sig}]
 *  2. EOA's code is set to 0xef0100 || address(AirAccountDelegate)
 *  3. User sends Type 2 tx to own address calling initialize(g1, g1sig, g2, g2sig, dailyLimit)
 *  4. AirAccount features are now active on the EOA's existing address
 *
 * @dev SECURITY NOTE: EIP-7702 private key validity problem —
 *   If the EOA private key is compromised, attacker can reset delegation via a new Type 4 tx.
 *   Guardians can initiate asset rescue to a new address before attacker can drain funds.
 *   AirAccountDelegate is best used as an ONBOARDING path; high-value users should
 *   eventually migrate to a native AirAccountV7 (CREATE2 deployed, non-7702).
 */
contract AirAccountDelegate {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── ERC-7201 Namespaced Storage ─────────────────────────────────────────

    /// @dev ERC-7201 storage slot.
    ///      = keccak256(abi.encode(uint256(keccak256("airaccount.delegate.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_SLOT =
        0x3251860799ccffe5dbc5b59b0d67c129b3e2ea13b1cea6f53b8a6ed43c720a00;

    struct DelegateStorage {
        bool    initialized;
        address guard;             // AAStarGlobalGuard deployed for this EOA
        address[3] guardians;      // [personal1, personal2, community/address(0)]
        // Guardian rescue state (replaces "owner rotation" — EOA address can't change)
        address  rescueTo;              // proposed rescue destination
        uint256  rescueTimestamp;       // when rescue was initiated (0 = none pending)
        uint8    rescueApprovals;       // bitmask: bit0=g1, bit1=g2, bit2=g3
        bool     rescueApproved;        // reached approval threshold (2-of-3)
        uint8    rescueCancellations;   // bitmask: same guardian indices, for cancel votes
    }

    function _ds() private pure returns (DelegateStorage storage ds) {
        assembly { ds.slot := 0x3251860799ccffe5dbc5b59b0d67c129b3e2ea13b1cea6f53b8a6ed43c720a00 }
    }

    // ─── Transient Storage (algId queue, EIP-1153) ────────────────────────────

    /// @dev Base slot for algId queue in transient storage.
    ///      Offset from base: +0=writeIdx, +1=readIdx, +2..=queue entries.
    ///      Using slot 100 to avoid collision with other contracts' transient use (slot 0 = reentrancy).
    uint256 private constant _TSTORE_BASE = 100;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @dev ERC-4337 EntryPoint v0.7 (canonical address, same across chains)
    IEntryPoint internal constant ENTRY_POINT =
        IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

    uint8 internal constant ALG_ECDSA = 0x02;

    /// @dev Rescue requires 2-of-3 guardian approvals. Timelock: 2 days.
    uint256 internal constant RESCUE_TIMELOCK = 2 days;
    uint8   internal constant RESCUE_THRESHOLD = 2;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error NotInitialized();
    error OnlySelfOrEntryPoint();
    error OnlySelf();
    error OnlyGuardian();
    error InvalidGuardianSignature(address guardian);
    error NoRescuePending();
    error RescueTimelockNotExpired();
    error RescueNotApproved();
    error GuardianAlreadyApproved();
    error GuardianAlreadyCancelVoted();
    error RescueAlreadyPending();
    error InvalidAddress();
    error ArrayLengthMismatch();
    error CallFailed(bytes reason);

    // ─── Events ───────────────────────────────────────────────────────────────

    event DelegateInitialized(address indexed eoa, address guard, address g1, address g2);
    event RescueInitiated(address indexed eoa, address rescueTo, address indexed initiator);
    event RescueApproved(address indexed eoa, address indexed guardian, uint8 approvals);
    event RescueExecuted(address indexed eoa, address rescueTo, uint256 ethAmount);
    event RescueCancelled(address indexed eoa);

    // ─── Initialization ───────────────────────────────────────────────────────

    /**
     * @notice Initialize AirAccount features for this EOA. Must be called after 7702 delegation.
     *
     * @dev Must be called FROM the EOA itself (msg.sender == address(this)).
     *      With 7702, the EOA sends a regular tx to its own address calling this function.
     *
     * @param guardian1  First personal guardian address
     * @param g1Sig      Guardian1's acceptance signature over domain hash
     * @param guardian2  Second personal guardian address
     * @param g2Sig      Guardian2's acceptance signature over domain hash
     * @param dailyLimit ETH daily spending limit in wei (0 = unlimited)
     *
     * @dev ⚠️ GUARDIAN TRUST WARNING:
     *      Two guardians acting together can initiate and approve a rescue transfer of all
     *      ETH to any address — including their own. The 2-day timelock gives the EOA owner
     *      a window to cancel, but ONLY if the private key is still accessible.
     *      Choose guardians you trust as much as your private key.
     */
    function initialize(
        address guardian1,
        bytes calldata g1Sig,
        address guardian2,
        bytes calldata g2Sig,
        uint256 dailyLimit
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();

        DelegateStorage storage ds = _ds();
        if (ds.initialized) revert AlreadyInitialized();

        if (guardian1 == address(0) || guardian2 == address(0)) revert InvalidAddress();

        // Verify guardian acceptance signatures
        bytes32 domainHash = _buildGuardianDomain(guardian1);
        if (ECDSA.recover(domainHash.toEthSignedMessageHash(), g1Sig) != guardian1)
            revert InvalidGuardianSignature(guardian1);

        domainHash = _buildGuardianDomain(guardian2);
        if (ECDSA.recover(domainHash.toEthSignedMessageHash(), g2Sig) != guardian2)
            revert InvalidGuardianSignature(guardian2);

        // Deploy a guard bound to this EOA (address(this) = the EOA)
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;
        address[] memory emptyTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory emptyCfgs = new AAStarGlobalGuard.TokenConfig[](0);

        address guardAddr = address(new AAStarGlobalGuard(
            address(this),   // account = this EOA
            dailyLimit,
            algIds,
            0,               // minDailyLimit
            emptyTokens,
            emptyCfgs
        ));

        ds.initialized = true;
        ds.guard = guardAddr;
        ds.guardians[0] = guardian1;
        ds.guardians[1] = guardian2;

        emit DelegateInitialized(address(this), guardAddr, guardian1, guardian2);
    }

    // ─── ERC-4337 Interface ───────────────────────────────────────────────────

    /**
     * @notice Validate a UserOperation. Called by EntryPoint during validation phase.
     * @dev For 7702 EOA: owner = address(this). ECDSA signature must recover to address(this).
     *      algId byte prefix is optional (raw 65-byte ECDSA also accepted for compatibility).
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != address(ENTRY_POINT)) revert OnlySelfOrEntryPoint();

        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();

        bytes calldata sig = userOp.signature;

        if (sig.length == 0) return 1;

        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        address signer;

        if (sig.length == 66 && uint8(sig[0]) == ALG_ECDSA) {
            // Prefixed format: [0x02][r(32)][s(32)][v(1)]
            signer = ECDSA.recover(ethHash, sig[1:]);
        } else if (sig.length == 65) {
            // Raw ECDSA: [r(32)][s(32)][v(1)] — backwards compat
            signer = ECDSA.recover(ethHash, sig);
        } else {
            return 1; // unsupported format
        }

        if (signer != address(this)) return 1;

        _storeAlgId(ALG_ECDSA);

        if (missingFunds > 0) {
            (bool ok,) = address(ENTRY_POINT).call{value: missingFunds}("");
            if (!ok) return 1;
        }

        return 0; // success
    }

    // ─── Execution ────────────────────────────────────────────────────────────

    /**
     * @notice Execute a single call. Caller must be EntryPoint or the EOA itself.
     * @dev Enforces ETH daily limit via guard before executing.
     */
    function execute(address dest, uint256 value, bytes calldata data) external {
        if (msg.sender != address(ENTRY_POINT) && msg.sender != address(this))
            revert OnlySelfOrEntryPoint();

        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();

        uint8 algId = msg.sender == address(ENTRY_POINT) ? _consumeAlgId() : ALG_ECDSA;

        // Guard: ETH daily limit + algorithm whitelist
        if (address(ds.guard) != address(0)) {
            AAStarGlobalGuard(ds.guard).checkTransaction(value, algId);
        }

        _call(dest, value, data);
    }

    /**
     * @notice Execute a batch of calls atomically.
     */
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata data
    ) external {
        if (msg.sender != address(ENTRY_POINT) && msg.sender != address(this))
            revert OnlySelfOrEntryPoint();

        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();

        if (dest.length != value.length || dest.length != data.length) revert ArrayLengthMismatch();

        uint8 algId = msg.sender == address(ENTRY_POINT) ? _consumeAlgId() : ALG_ECDSA;

        for (uint256 i = 0; i < dest.length; i++) {
            if (address(ds.guard) != address(0)) {
                AAStarGlobalGuard(ds.guard).checkTransaction(value[i], algId);
            }
            _call(dest[i], value[i], data[i]);
        }
    }

    // ─── Guardian Rescue ──────────────────────────────────────────────────────

    /**
     * @notice Initiate emergency rescue — propose transferring all ETH to a new address.
     *
     * @dev Called by a guardian when the EOA private key is compromised or lost.
     *      Once initiated, other guardians call approveRescue(). After RESCUE_THRESHOLD
     *      approvals and a 2-day timelock, anyone calls executeRescue().
     *
     *      Once a rescue is pending, it cannot be overridden by another guardian
     *      (prevents DoS via competing initiations). Only the EOA owner can cancel
     *      via cancelRescue() if the key is still accessible.
     *
     * @param rescueTo Destination address to transfer all ETH to (must be non-zero)
     */
    function initiateRescue(address rescueTo) external {
        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();

        (uint8 gIdx, bool isGuardian) = _guardianIndex(msg.sender, ds);
        if (!isGuardian) revert OnlyGuardian();
        if (rescueTo == address(0)) revert InvalidAddress();
        // Block any override once a rescue is pending — prevents DoS by rogue guardian.
        // Cancel via cancelRescue() (EOA self only) if the destination needs to change.
        if (ds.rescueTimestamp != 0) revert RescueAlreadyPending();

        ds.rescueTo = rescueTo;
        ds.rescueTimestamp = block.timestamp;
        ds.rescueApprovals = uint8(1) << gIdx; // initiator's vote
        ds.rescueApproved = (RESCUE_THRESHOLD == 1);
        ds.rescueCancellations = 0; // reset cancel votes on new rescue

        emit RescueInitiated(address(this), rescueTo, msg.sender);
        emit RescueApproved(address(this), msg.sender, uint8(1) << gIdx);
    }

    /**
     * @notice Add guardian approval to an active rescue proposal.
     */
    function approveRescue() external {
        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();
        if (ds.rescueTimestamp == 0) revert NoRescuePending();

        (uint8 gIdx, bool isGuardian) = _guardianIndex(msg.sender, ds);
        if (!isGuardian) revert OnlyGuardian();

        uint8 bit = uint8(1) << gIdx;
        if (ds.rescueApprovals & bit != 0) revert GuardianAlreadyApproved();

        ds.rescueApprovals |= bit;

        // Count set bits
        uint8 count = 0;
        uint8 a = ds.rescueApprovals;
        while (a != 0) { count += a & 1; a >>= 1; }

        if (count >= RESCUE_THRESHOLD) ds.rescueApproved = true;

        emit RescueApproved(address(this), msg.sender, ds.rescueApprovals);
    }

    /**
     * @notice Execute the rescue after threshold + timelock.
     *         Transfers all ETH from this EOA to the approved rescue destination.
     */
    function executeRescue() external {
        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();
        if (ds.rescueTimestamp == 0) revert NoRescuePending();
        if (!ds.rescueApproved) revert RescueNotApproved();
        if (block.timestamp < ds.rescueTimestamp + RESCUE_TIMELOCK)
            revert RescueTimelockNotExpired();

        address to = ds.rescueTo;

        // Clear rescue state
        ds.rescueTo = address(0);
        ds.rescueTimestamp = 0;
        ds.rescueApprovals = 0;
        ds.rescueApproved = false;
        ds.rescueCancellations = 0;

        uint256 amount = address(this).balance;
        emit RescueExecuted(address(this), to, amount);

        if (amount > 0) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert CallFailed("");
        }
    }

    /**
     * @notice Vote to cancel a pending rescue. Requires RESCUE_THRESHOLD guardian votes.
     *
     * @dev Mirrors AAStarAirAccountBase.cancelRecovery() design rationale:
     *      The EOA private key holder CANNOT cancel — if the key is stolen, the attacker
     *      could cancel any rescue and prevent asset recovery. Only a guardian threshold
     *      can cancel, giving guardians full control over the rescue lifecycle.
     *
     *      Each guardian votes independently. When threshold is reached the rescue is cancelled.
     *      A guardian cannot vote to cancel after already voting to approve.
     */
    function cancelRescue() external {
        DelegateStorage storage ds = _ds();
        if (!ds.initialized) revert NotInitialized();
        if (ds.rescueTimestamp == 0) revert NoRescuePending();

        (uint8 gIdx, bool isGuardian) = _guardianIndex(msg.sender, ds);
        if (!isGuardian) revert OnlyGuardian();

        uint8 bit = uint8(1) << gIdx;
        if (ds.rescueCancellations & bit != 0) revert GuardianAlreadyCancelVoted();

        ds.rescueCancellations |= bit;

        // Count cancel votes
        uint8 count = 0;
        uint8 c = ds.rescueCancellations;
        while (c != 0) { count += c & 1; c >>= 1; }

        if (count >= RESCUE_THRESHOLD) {
            ds.rescueTo = address(0);
            ds.rescueTimestamp = 0;
            ds.rescueApprovals = 0;
            ds.rescueApproved = false;
            ds.rescueCancellations = 0;
            emit RescueCancelled(address(this));
        }
    }

    // ─── EntryPoint Deposit Management ────────────────────────────────────────

    function addDeposit() external payable {
        ENTRY_POINT.depositTo{value: msg.value}(address(this));
    }

    function getDeposit() external view returns (uint256) {
        return ENTRY_POINT.balanceOf(address(this));
    }

    function withdrawDepositTo(address payable to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        ENTRY_POINT.withdrawTo(to, amount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice The owner of this account is always the EOA itself.
    function owner() external view returns (address) {
        return address(this);
    }

    function entryPoint() external pure returns (address) {
        return address(ENTRY_POINT);
    }

    function getGuard() external view returns (address) {
        return _ds().guard;
    }

    function getGuardians() external view returns (address[3] memory) {
        return _ds().guardians;
    }

    function isInitialized() external view returns (bool) {
        return _ds().initialized;
    }

    function getRescueState() external view returns (
        address rescueTo,
        uint256 rescueTimestamp,
        uint8 rescueApprovals,
        bool approved,
        uint8 cancellations
    ) {
        DelegateStorage storage ds = _ds();
        return (ds.rescueTo, ds.rescueTimestamp, ds.rescueApprovals, ds.rescueApproved, ds.rescueCancellations);
    }

    // ─── Receive ETH ──────────────────────────────────────────────────────────

    receive() external payable {}

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _call(address dest, uint256 value, bytes calldata data) internal {
        (bool success, bytes memory result) = dest.call{value: value}(data);
        if (!success) revert CallFailed(result);
    }

    /// @dev Domain hash for guardian acceptance.
    ///      Domain: keccak256(abi.encodePacked("ACCEPT_GUARDIAN_7702", chainId, delegateImpl, eoa))
    ///      This binds acceptance to a specific (chain, implementation, EOA) tuple.
    function _buildGuardianDomain(address guardian) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "ACCEPT_GUARDIAN_7702",
            block.chainid,
            address(this),   // the EOA address (address(this) is the delegating EOA)
            guardian
        ));
    }

    /// @dev Returns (index, isGuardian) for a given address.
    function _guardianIndex(
        address who,
        DelegateStorage storage ds
    ) internal view returns (uint8 idx, bool found) {
        for (uint8 i = 0; i < 3; i++) {
            if (ds.guardians[i] == who && who != address(0)) return (i, true);
        }
        return (0, false);
    }

    // ─── ERC-5564 Stealth Address (M7.13) ────────────────────────────────────────

    /// @notice Publish a stealth address announcement via ERC-5564 Announcer.
    /// @dev This allows the recipient to scan announcements and find stealth payments.
    ///      The stealth address derivation is done OFF-CHAIN — this contract just publishes the announcement.
    ///      Receiving assets at stealth addresses requires no special handling (just a regular receive).
    /// @param announcer ERC-5564 Announcer contract address
    ///        (Ethereum: 0x55649E01B5Df198D18D95b5cc5051630cfD45564, Sepolia: 0x55649E01B5Df198D18D95b5cc5051630cfD45564)
    /// @param stealthAddress The one-time stealth address derived from recipient's stealth meta-address
    /// @param ephemeralPubKey The sender's ephemeral public key (33 bytes for secp256k1)
    /// @param metadata Protocol-specific metadata (can encode view tag for efficient scanning)
    function announceForStealth(
        address announcer,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        require(announcer != address(0), "Invalid announcer");
        IERC5564Announcer(announcer).announce(
            1, // schemeId=1 for secp256k1 stealth addresses
            stealthAddress,
            ephemeralPubKey,
            metadata
        );
    }

    // ─── Transient Storage (algId queue) ─────────────────────────────────────

    function _storeAlgId(uint8 algId) internal {
        assembly {
            let base := 100 // _TSTORE_BASE
            let wIdx := tload(base)
            tstore(add(add(base, 2), wIdx), algId)
            tstore(base, add(wIdx, 1))
        }
    }

    function _consumeAlgId() internal returns (uint8 algId) {
        assembly {
            let base := 100 // _TSTORE_BASE
            let rIdx := tload(add(base, 1))
            algId := tload(add(add(base, 2), rIdx))
            tstore(add(base, 1), add(rIdx, 1))
        }
    }
}
