// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

/**
 * @title AAStarAirAccountBase
 * @notice Milestone 1 minimal base contract for AirAccount — a non-upgradable ERC-4337 smart wallet.
 * @dev Abstract base providing ECDSA signature validation, execution, and EntryPoint deposit management.
 *      - No proxy/UUPS pattern (non-upgradable by design)
 *      - Inline ECDSA only (no BLS, no P256, no validator routing — those come in M2+)
 *      - `owner` serves as both account owner and ECDSA signer in M1
 *      - Child contracts (V7/V8 wrappers) implement `validateUserOp` from IAccount
 */
abstract contract AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Immutable State ─────────────────────────────────────────────

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint;

    /// @notice Account owner and M1 ECDSA signer
    address public immutable owner;

    // ─── Custom Errors ───────────────────────────────────────────────

    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error NotOwner();
    error ArrayLengthMismatch();
    error CallFailed(bytes returnData);

    // ─── Modifiers ───────────────────────────────────────────────────

    modifier onlyEntryPoint() {
        _checkEntryPoint();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        _checkOwnerOrEntryPoint();
        _;
    }

    function _checkEntryPoint() internal view {
        if (msg.sender != entryPoint) revert NotEntryPoint();
    }

    function _checkOwnerOrEntryPoint() internal view {
        if (msg.sender != owner && msg.sender != entryPoint) revert NotOwnerOrEntryPoint();
    }

    // ─── Constructor ─────────────────────────────────────────────────

    constructor(address _entryPoint, address _owner) {
        entryPoint = _entryPoint;
        owner = _owner;
    }

    // ─── Signature Validation ────────────────────────────────────────

    /**
     * @dev Validate an ECDSA signature against the owner.
     * @param userOpHash Hash of the UserOperation (provided by EntryPoint).
     * @param signature  The ECDSA signature to verify.
     * @return validationData 0 on success, 1 (SIG_VALIDATION_FAILED) on failure.
     */
    function _validateSignature(
        bytes32 userOpHash,
        bytes calldata signature
    ) internal view returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(signature);
        if (recovered != owner) {
            return 1; // SIG_VALIDATION_FAILED
        }
        return 0;
    }

    // ─── Execution ───────────────────────────────────────────────────

    /**
     * @notice Execute a single call from this account.
     * @param dest  Target address.
     * @param value ETH value to send.
     * @param func  Calldata for the target.
     */
    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyOwnerOrEntryPoint {
        _call(dest, value, func);
    }

    /**
     * @notice Execute a batch of calls from this account.
     * @param dest  Array of target addresses.
     * @param value Array of ETH values.
     * @param func  Array of calldata payloads.
     */
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata func
    ) external onlyOwnerOrEntryPoint {
        if (dest.length != value.length || dest.length != func.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], value[i], func[i]);
        }
    }

    // ─── EntryPoint Deposit Management ───────────────────────────────

    /**
     * @notice Deposit ETH into the EntryPoint on behalf of this account.
     */
    function addDeposit() public payable {
        IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Query this account's deposit balance in the EntryPoint.
     * @return The current deposit balance.
     */
    function getDeposit() public view returns (uint256) {
        return IEntryPoint(entryPoint).balanceOf(address(this));
    }

    /**
     * @notice Withdraw deposit from the EntryPoint to a specified address.
     * @param to     Recipient of the withdrawn funds.
     * @param amount Amount to withdraw.
     */
    function withdrawDepositTo(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        IEntryPoint(entryPoint).withdrawTo(to, amount);
    }

    // ─── Internal Helpers ────────────────────────────────────────────

    /**
     * @dev Pay the EntryPoint the required prefund for gas.
     * @param missingAccountFunds The amount the EntryPoint requires.
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            // Silently ignore failure — EntryPoint will revert if deposit is insufficient.
            (success);
        }
    }

    /**
     * @dev Low-level call helper that bubbles up revert data on failure.
     */
    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            // Bubble up the revert reason
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ─── Receive ETH ─────────────────────────────────────────────────

    receive() external payable {}
}
