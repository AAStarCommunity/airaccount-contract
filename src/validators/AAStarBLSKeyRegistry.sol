// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title AAStarBLSKeyRegistry - Safe-owned BLS12-381 node key registry + aggregate signature verification
/// @dev Renamed from AAStarBLSAlgorithm (CC-27): resolves the cross-repo name collision with
///      YetAnotherAA-Validator's AAStarBLSAlgorithm (the permissionless stake-bound DVT node
///      registry with registerWithProof). This contract is the protocol Safe-curated key set
///      (owner-gated registerPublicKey, no PoP/stake) — an independent contract, not a fork.
/// @notice Extracted from YetAnotherAA AAStarValidator with assembly optimizations.
///         ABI-compatible with the NestJS backend (registerPublicKey, isRegistered, etc.)
/// @dev Uses EIP-2537 precompiles: G1Add (0x0b), Pairing (0x0f)
contract AAStarBLSKeyRegistry is IAAStarAlgorithm {
    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev nodeId → G1 public key (128 bytes EIP-2537 format)
    mapping(bytes32 => bytes) public registeredKeys;

    /// @dev nodeId → registration status
    mapping(bytes32 => bool) public isRegistered;

    /// @dev All registered node identifiers
    bytes32[] public registeredNodes;

    /// @dev v0.17.2-beta.1 security review HIGH-1 (Codex round 5): the previous
    ///      `cachedAggKeys` mapping has been removed. The cached aggregate was not
    ///      invalidated on `updatePublicKey` / `revokePublicKey`, so a compromised
    ///      key remained usable through any cached node set indefinitely. There is
    ///      no safe per-call invalidation strategy without a per-node `keyVersion`,
    ///      and the cache savings are small relative to the pairing precompile cost.
    ///      The mapping is gone; aggregation is now always on-demand in `_aggregateNodeKeys`.
    ///      `cacheAggregatedKey()` is retained as a deprecated no-op-revert for SDK
    ///      callers that haven't migrated yet — they get a clear `CacheDeprecated` revert.

    /// @dev Contract owner for admin functions. Intended to be transferred (two-step) to the
    ///      protocol Gnosis Safe multisig after the deployer EOA has registered the node keys.
    address public owner;

    /// @dev Pending owner for the two-step ownership transfer (Ownable2Step pattern). The EOA→Safe
    ///      handover requires the new owner to explicitly `acceptOwnership()`, so a fat-fingered
    ///      wrong address can never end up owning the registry.
    address public pendingOwner;

    /// @dev issue #45 Part B: the single, protocol-level batch BLS aggregator. ONE canonical
    ///      aggregator for the whole protocol — set only by `owner` (the Safe). Accounts read this
    ///      value during BLS validation (`blsAlgorithm.aggregator()`); end users have NO way to
    ///      change it. Zero ⇒ batch aggregation disabled, accounts use inline single-op BLS.
    address public aggregator;

    // ─── Constants ────────────────────────────────────────────────────

    /// @dev EIP-2537 precompile addresses (final Pectra/Prague mainnet addressing).
    ///      Verified on the target chain via the working G1ADD/PAIRING used below
    ///      (Sepolia M2 BLS E2E) and an empirical local probe under `--evm-version prague`:
    ///      0x0b=G1ADD, 0x0d=G2ADD, 0x0f=PAIRING_CHECK, 0x10=MAP_FP_TO_G1, 0x11=MAP_FP2_TO_G2.
    ///      #104 (v0.18.0-beta.2): the dead legacy `g2Add()` helper that used 0x0e
    ///      (BLS12_G2MSM in the final addressing — a latent bug) has been removed. The only
    ///      G2 addition on the live hash-to-curve path is `_g2AddPoints`, which uses 0x0d.
    address private constant G1ADD_PRECOMPILE = address(0x0b);
    address private constant PAIRING_PRECOMPILE = address(0x0f);
    address private constant SHA256_PRECOMPILE = address(0x02);
    address private constant MODEXP_PRECOMPILE = address(0x05);
    address private constant G2ADD_PRECOMPILE = address(0x0d);
    address private constant MAP_FP2_TO_G2_PRECOMPILE = address(0x11);

    uint256 private constant G1_POINT_LENGTH = 128;
    uint256 private constant G2_POINT_LENGTH = 256;
    uint256 private constant FP2_INPUT_LENGTH = 128; // EIP-2537 MAP_FP2_TO_G2 input
    uint256 private constant PAIRING_INPUT_LENGTH = 768; // 2 × (G1 + G2)

    /// @dev BLS12-381 field modulus p (split into two 256-bit limbs)
    uint256 private constant P_HIGH = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f624;
    uint256 private constant P_LOW = 0x1eabfffeb153ffffb9feffffffffaaab;

    /// @dev RFC 9380 hash-to-curve parameters (issue #45 Fix 1). These MUST byte-match the
    ///      off-chain DVT signer (YetAnotherAA-Validator/src/utils/bls.util.ts) so that the
    ///      message point recomputed on-chain equals `bls12_381.G2.hashToCurve(userOpHash, {DST})`.

    /// @dev Domain separation tag — identical to BLS_DST in the DVT util (43 bytes).
    bytes private constant DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

    /// @dev BLS12-381 base field modulus p as 48-byte big-endian (modexp modulus = P_HIGH‖P_LOW).
    bytes private constant FIELD_MODULUS =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    /// @dev expand_message_xmd output length for G2 hash_to_curve:
    ///      count(2) × m(2 for Fp2) × L(64) = 256 bytes → ell = 256/32 = 8 SHA-256 blocks.
    uint256 private constant XMD_LEN = 256;
    uint256 private constant XMD_ELL = 8;

    /// @dev G1 generator point in EIP-2537 format (128 bytes)
    bytes private constant GENERATOR_POINT =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    // ─── Events ───────────────────────────────────────────────────────

    event PublicKeyRegistered(bytes32 indexed nodeId, bytes publicKey);
    event PublicKeyUpdated(bytes32 indexed nodeId, bytes oldKey, bytes newKey);
    event PublicKeyRevoked(bytes32 indexed nodeId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev Two-step ownership: emitted when `transferOwnership` records a pending owner.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    /// @dev issue #45 Part B: emitted when the protocol-level aggregator value changes.
    event AggregatorSet(address indexed aggregator);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyOwner();
    error NotPendingOwner();
    error InvalidNodeId();
    error InvalidKeyLength();
    error NodeAlreadyRegistered();
    error NodeNotRegistered();
    error ArrayLengthMismatch();
    error EmptyArrays();
    error NoNodesProvided();
    error InvalidSignatureLength();
    error InvalidMessageLength();
    error PairingFailed();
    /// @dev v0.17.2-beta.1 round 5 HIGH-2 / LOW-2: reject G1/G2 point at infinity
    ///      (all-zero encoding). Pairings involving infinity evaluate to the identity,
    ///      which would let a caller satisfy BLS verification with a zero signature.
    error BLSPointAtInfinity();
    /// @dev v0.17.2-beta.1 round 5 HIGH-1: aggregate-key cache removed.
    error CacheDeprecated();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─── IAAStarAlgorithm Implementation ──────────────────────────────

    /// @inheritdoc IAAStarAlgorithm
    /// @dev issue #45 Fix 1 (Option B): signature format is now `[nodeIds...][blsSignature(256)]`.
    ///      The trailing caller-supplied `messagePoint(256)` has been REMOVED. The message point
    ///      is recomputed on-chain from `hash` (= the ERC-4337 userOpHash) via RFC 9380
    ///      hash_to_curve and the pairing is verified against THAT. This binds the BLS aggregate
    ///      to this exact operation: a valid (messagePoint, aggSig) produced for userOpHash_A can
    ///      no longer be replayed against userOpHash_B (the old code ignored `hash` and verified
    ///      against whatever point the caller supplied).
    ///      The nodeIds count is derived from (sig.length - 256) / 32.
    function validate(bytes32 hash, bytes calldata signature) external view override returns (uint256) {
        // Parse: variable-length nodeIds + 256-byte BLS sig (messagePoint dropped — see above).
        uint256 fixedLen = G2_POINT_LENGTH; // 256
        if (signature.length <= fixedLen) return 1;

        uint256 nodeIdsBytes = signature.length - fixedLen;
        if (nodeIdsBytes == 0 || nodeIdsBytes % 32 != 0) return 1;

        uint256 nodeCount = nodeIdsBytes / 32;
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        for (uint256 i = 0; i < nodeCount; i++) {
            nodeIds[i] = bytes32(signature[i * 32:(i + 1) * 32]);
        }

        bytes calldata blsSignature = signature[nodeIdsBytes:nodeIdsBytes + G2_POINT_LENGTH];

        // v0.17.2-beta.1 round 5 HIGH-2: reject point-at-infinity. Pairings with infinity
        // evaluate to identity and would let an owner-key-only attacker satisfy the BLS factor.
        if (_isG2InfinityCalldata(blsSignature)) return 1;

        // issue #45 Fix 1: recompute the message point from userOpHash (same DST/suite as the DVT).
        bytes memory messagePoint = _hashToG2(hash);
        // Defensive: hash_to_curve never returns infinity, but assert it (keeps the prior invariant).
        if (_isG2InfinityMemory(messagePoint)) return 1;

        bool valid = _validateBLSSignature(nodeIds, blsSignature, messagePoint);
        return valid ? 0 : 1;
    }

    // ─── RFC 9380 hash_to_curve (issue #45 Fix 1) ─────────────────────

    /// @notice Map a 32-byte message (the userOpHash) to a BLS12-381 G2 point, byte-identical to
    ///         `bls12_381.G2.hashToCurve(getBytes(message), { DST })` in noble-curves (the DVT).
    /// @dev Exposed as an external view for golden-vector testing / off-chain cross-checking.
    ///      No security impact: it is a pure function of `message` (no storage, no msg.sender).
    function hashToG2(bytes32 message) external view returns (bytes memory) {
        return _hashToG2(message);
    }

    /// @dev RFC 9380 `hash_to_curve` for suite BLS12381G2_XMD:SHA-256_SSWU_RO_.
    ///      1. expand_message_xmd(message, DST, 256) → 256 uniform bytes.
    ///      2. hash_to_field → two Fp2 elements u0,u1 (four 64-byte chunks reduced mod p).
    ///      3. MAP_FP2_TO_G2(u0), MAP_FP2_TO_G2(u1)   (EIP-2537 0x11; isogeny + cofactor clearing).
    ///      4. G2ADD(q0, q1)                          (EIP-2537 0x0d).
    ///      Step 4 equals RFC's clear_cofactor(map(u0)+map(u1)) because cofactor clearing is a
    ///      scalar multiplication and therefore distributes over point addition.
    function _hashToG2(bytes32 message) internal view returns (bytes memory point) {
        bytes memory uniform = _expandMessageXmd(message); // 256 bytes

        // RFC 9380 §5.3 ordering: u0 = (chunk0, chunk1), u1 = (chunk2, chunk3); each chunk mod p
        // is the c0/c1 coordinate of the Fp2 element, encoded EIP-2537-style (16-byte left pad).
        bytes memory map0 = new bytes(FP2_INPUT_LENGTH);
        bytes memory map1 = new bytes(FP2_INPUT_LENGTH);
        _placeFieldElement(map0, 0, uniform, 0); // u0.c0
        _placeFieldElement(map0, 1, uniform, 1); // u0.c1
        _placeFieldElement(map1, 0, uniform, 2); // u1.c0
        _placeFieldElement(map1, 1, uniform, 3); // u1.c1

        bytes memory q0 = _mapFp2ToG2(map0);
        bytes memory q1 = _mapFp2ToG2(map1);
        point = _g2AddPoints(q0, q1);
    }

    /// @dev RFC 9380 §5.3.1 expand_message_xmd with SHA-256, len_in_bytes = 256, ell = 8.
    function _expandMessageXmd(bytes32 message) internal view returns (bytes memory uniform) {
        // DST_prime = DST || I2OSP(len(DST), 1)
        bytes memory dstPrime = abi.encodePacked(DST, uint8(DST.length));
        // msg_prime = Z_pad(s_in_bytes=64) || msg || I2OSP(len_in_bytes,2) || I2OSP(0,1) || DST_prime
        bytes memory msgPrime = abi.encodePacked(
            new bytes(64), // Z_pad
            message,
            uint16(XMD_LEN), // l_i_b_str = I2OSP(256,2) = 0x0100
            uint8(0),
            dstPrime
        );
        bytes32 b0 = sha256(msgPrime);
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), dstPrime));

        uniform = new bytes(XMD_LEN);
        _writeWord(uniform, 0, b1);
        bytes32 prev = b1;
        for (uint256 i = 2; i <= XMD_ELL; i++) {
            bytes32 bi = sha256(abi.encodePacked(b0 ^ prev, uint8(i), dstPrime));
            _writeWord(uniform, (i - 1) * 32, bi);
            prev = bi;
        }
    }

    /// @dev Reduce the `chunkIndex`-th 64-byte chunk of `uniform` mod p (via MODEXP, exp = 1) and
    ///      write the 48-byte result into `mapInput` at the EIP-2537 Fp slot (`slot` ∈ {0,1}).
    function _placeFieldElement(
        bytes memory mapInput,
        uint256 slot,
        bytes memory uniform,
        uint256 chunkIndex
    ) internal view {
        // MODEXP input (EIP-198): Blen(32)|Elen(32)|Mlen(32)|B(64)|E(1)|M(48) = 209 bytes.
        bytes memory input = new bytes(209);
        bytes memory modulus = FIELD_MODULUS;
        // out is the Fp slot inside mapInput: slot 0 → bytes[16:64], slot 1 → bytes[80:128].
        uint256 dstOff = slot == 0 ? 16 : 80;
        assembly {
            let p := add(input, 0x20)
            mstore(p, 64) // Blen
            mstore(add(p, 32), 1) // Elen
            mstore(add(p, 64), 48) // Mlen
            // B: 64 bytes from uniform[chunkIndex*64 :]
            mcopy(add(p, 96), add(add(uniform, 0x20), mul(chunkIndex, 64)), 64)
            mstore8(add(p, 160), 1) // E = 0x01
            mcopy(add(p, 161), add(modulus, 0x20), 48) // M = p
            // MODEXP (0x05) → 48-byte reduced value written straight into the map slot.
            let ok := staticcall(gas(), 0x05, p, 209, add(add(mapInput, 0x20), dstOff), 48)
            if iszero(ok) { revert(0, 0) }
        }
    }

    /// @dev EIP-2537 BLS12_MAP_FP2_TO_G2 (0x11): Fp2 (128 bytes) → G2 point (256 bytes).
    function _mapFp2ToG2(bytes memory fp2) internal view returns (bytes memory out) {
        out = new bytes(G2_POINT_LENGTH);
        assembly {
            // MAP_FP2_TO_G2 (0x11)
            let ok := staticcall(gas(), 0x11, add(fp2, 0x20), FP2_INPUT_LENGTH, add(out, 0x20), 256)
            if iszero(ok) { revert(0, 0) }
        }
    }

    /// @dev EIP-2537 BLS12_G2ADD (0x0d): add two G2 points (memory operands).
    function _g2AddPoints(bytes memory a, bytes memory b) internal view returns (bytes memory out) {
        out = new bytes(G2_POINT_LENGTH);
        assembly {
            let input := mload(0x40)
            mstore(0x40, add(input, 512))
            mcopy(input, add(a, 0x20), 256)
            mcopy(add(input, 256), add(b, 0x20), 256)
            // G2ADD (0x0d)
            let ok := staticcall(gas(), 0x0d, input, 512, add(out, 0x20), 256)
            if iszero(ok) { revert(0, 0) }
        }
    }

    /// @dev Write a 32-byte word into `buf` at byte offset `off`.
    function _writeWord(bytes memory buf, uint256 off, bytes32 val) internal pure {
        assembly {
            mstore(add(add(buf, 0x20), off), val)
        }
    }

    /// @dev Returns true if a G2 point (256-byte EIP-2537 format) in memory is the point at infinity.
    function _isG2InfinityMemory(bytes memory point) internal pure returns (bool) {
        if (point.length != G2_POINT_LENGTH) return false;
        for (uint256 i = 0; i < G2_POINT_LENGTH; i++) {
            if (point[i] != 0) return false;
        }
        return true;
    }

    // ─── BLS Verification (NestJS-compatible ABI) ─────────────────────

    /// @notice ⚠️ SECURITY (issue #45, Codex LOW): `validateAggregateSignature` /
    ///         `verifyAggregateSignature` are GENERIC aggregate-verification utilities that check a
    ///         signature against a CALLER-SUPPLIED `messagePoint`. They are NOT bound to any
    ///         userOpHash and MUST NOT be used to authorize an ERC-4337 UserOperation — doing so
    ///         reintroduces the #45 replay (a valid (messagePoint, aggSig) pair is reusable across
    ///         operations). For operation authorization use the account path / `validate(userOpHash,
    ///         …)`, which recomputes the message point on-chain from the userOpHash. These remain
    ///         only for off-chain NestJS-backend ABI compatibility (generic, non-op-bound checks).

    /// @notice Verify aggregate BLS signature against a caller-supplied point (view, no events).
    ///         ⚠️ NOT op-bound — see the security note above. Do not use for UserOp authorization.
    function validateAggregateSignature(
        bytes32[] calldata nodeIds,
        bytes calldata signature,
        bytes calldata messagePoint
    ) external view returns (bool) {
        if (nodeIds.length == 0) revert NoNodesProvided();
        if (signature.length != G2_POINT_LENGTH) revert InvalidSignatureLength();
        if (messagePoint.length != G2_POINT_LENGTH) revert InvalidMessageLength();
        // v0.17.2-beta.1 round 5 HIGH-2: reject infinity (see validate() above).
        if (_isG2InfinityCalldata(signature)) revert BLSPointAtInfinity();
        if (_isG2InfinityCalldata(messagePoint)) revert BLSPointAtInfinity();
        return _validateBLSSignature(nodeIds, signature, messagePoint);
    }

    /// @notice Verify aggregate BLS signature (state-changing for event compat)
    function verifyAggregateSignature(
        bytes32[] calldata nodeIds,
        bytes calldata signature,
        bytes calldata messagePoint
    ) external returns (bool) {
        if (nodeIds.length == 0) revert NoNodesProvided();
        if (signature.length != G2_POINT_LENGTH) revert InvalidSignatureLength();
        if (messagePoint.length != G2_POINT_LENGTH) revert InvalidMessageLength();
        if (_isG2InfinityCalldata(signature)) revert BLSPointAtInfinity();
        if (_isG2InfinityCalldata(messagePoint)) revert BLSPointAtInfinity();
        return _validateBLSSignature(nodeIds, signature, messagePoint);
    }

    // ─── Core BLS Logic (Assembly Optimized) ──────────────────────────

    function _validateBLSSignature(
        bytes32[] memory nodeIds,
        bytes calldata signature,
        bytes memory messagePoint
    ) internal view returns (bool) {
        // 1. Load public keys from storage and aggregate
        bytes memory aggregatedKey = _aggregateNodeKeys(nodeIds);

        // 2. Negate aggregated key
        bytes memory negatedKey = _negateG1PointAssembly(aggregatedKey);

        // 3. Build pairing input and verify
        return _verifyPairing(negatedKey, signature, messagePoint, nodeIds.length);
    }

    /// @dev Aggregate public keys of registered nodes using G1Add precompile.
    ///      Always on-demand (no cache). See `CacheDeprecated` notes above for why
    ///      the previous `cachedAggKeys` mapping was removed in v0.17.2-beta.1.
    function _aggregateNodeKeys(bytes32[] memory nodeIds) internal view returns (bytes memory result) {
        bytes32 firstNodeId = nodeIds[0];
        if (!isRegistered[firstNodeId]) revert NodeNotRegistered();
        result = registeredKeys[firstNodeId];

        for (uint256 i = 1; i < nodeIds.length; i++) {
            bytes32 nodeId = nodeIds[i];
            if (!isRegistered[nodeId]) revert NodeNotRegistered();
            bytes memory key = registeredKeys[nodeId];
            result = _g1Add(result, key);
        }
    }

    /// @notice DEPRECATED in v0.17.2-beta.1 — cache mechanism removed (Codex round 5 HIGH-1).
    ///         The previous design cached aggregate keys per `keccak256(nodeIds)` but did not
    ///         invalidate them on `updatePublicKey` / `revokePublicKey`, so a compromised key
    ///         remained usable through any cached set. Aggregation is now always on-demand.
    /// @dev SDK / NestJS backend callers that still invoke this will get a clear revert and
    ///      can drop the call site — `_aggregateNodeKeys` no longer needs pre-warming.
    function cacheAggregatedKey(bytes32[] calldata /*nodeIds*/) external pure {
        revert CacheDeprecated();
    }

    /// @notice Compute the cache key for a set of nodeIds (retained for off-chain compatibility).
    function computeSetHash(bytes32[] memory nodeIds) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(nodeIds));
    }

    // ─── Infinity-point rejection helpers (v0.17.2-beta.1 round 5 HIGH-2 / LOW-2) ──

    /// @dev Returns true if a G1 point (128 bytes EIP-2537 format) is the point at infinity.
    ///      EIP-2537 encodes infinity as all-zero bytes.
    function _isG1Infinity(bytes memory point) internal pure returns (bool) {
        if (point.length != G1_POINT_LENGTH) return false;
        for (uint256 i = 0; i < G1_POINT_LENGTH; i++) {
            if (point[i] != 0) return false;
        }
        return true;
    }

    /// @dev Same as above for G1 calldata bytes.
    function _isG1InfinityCalldata(bytes calldata point) internal pure returns (bool) {
        if (point.length != G1_POINT_LENGTH) return false;
        for (uint256 i = 0; i < G1_POINT_LENGTH; i++) {
            if (point[i] != 0) return false;
        }
        return true;
    }

    /// @dev Returns true if a G2 point (256 bytes EIP-2537 format) is the point at infinity.
    function _isG2InfinityCalldata(bytes calldata point) internal pure returns (bool) {
        if (point.length != G2_POINT_LENGTH) return false;
        for (uint256 i = 0; i < G2_POINT_LENGTH; i++) {
            if (point[i] != 0) return false;
        }
        return true;
    }

    /// @dev G1 point addition via EIP-2537 precompile with assembly
    function _g1Add(bytes memory p1, bytes memory p2) internal view returns (bytes memory result) {
        result = new bytes(G1_POINT_LENGTH);
        assembly {
            // Allocate 256 bytes for input (p1 || p2)
            let input := mload(0x40)
            mstore(0x40, add(input, 256))

            // Copy p1 (128 bytes from p1+32)
            let src := add(p1, 0x20)
            let dst := input
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
            mstore(add(dst, 0x40), mload(add(src, 0x40)))
            mstore(add(dst, 0x60), mload(add(src, 0x60)))

            // Copy p2 (128 bytes from p2+32)
            src := add(p2, 0x20)
            dst := add(input, 128)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
            mstore(add(dst, 0x40), mload(add(src, 0x40)))
            mstore(add(dst, 0x60), mload(add(src, 0x60)))

            // staticcall G1Add precompile
            let success := staticcall(gas(), 0x0b, input, 256, add(result, 0x20), 128)
            if iszero(success) { revert(0, 0) }
        }
    }

    /// @dev Negate G1 point: -P = (x, p - y). Assembly-optimized.
    function _negateG1PointAssembly(bytes memory point) internal pure returns (bytes memory negated) {
        negated = new bytes(G1_POINT_LENGTH);
        assembly {
            let src := add(point, 0x20)
            let dst := add(negated, 0x20)

            // Copy x coordinate unchanged (first 64 bytes = 2 words)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))

            // Check if point is infinity (all zeros)
            let isZero := 1
            for { let i := 0 } lt(i, 4) { i := add(i, 1) } {
                if mload(add(src, mul(i, 0x20))) { isZero := 0 }
            }

            if iszero(isZero) {
                // Extract y coordinate: bytes 80-127 (48 bytes within 64-byte chunk)
                // y_high = 32 bytes at offset 80
                let yPtr := add(src, 80)
                let y_high := mload(yPtr)
                // y_low = 16 bytes at offset 112, shifted right 128
                let y_low := shr(128, mload(add(yPtr, 32)))

                // Compute p - y (two-limb subtraction)
                let p_high := P_HIGH
                let p_low := P_LOW

                let neg_y_low
                let neg_y_high
                switch lt(p_low, y_low)
                case 0 {
                    neg_y_low := sub(p_low, y_low)
                    neg_y_high := sub(p_high, y_high)
                }
                default {
                    // Borrow needed
                    neg_y_low := add(sub(p_low, y_low), add(not(0), 1))
                    neg_y_high := sub(sub(p_high, y_high), 1)
                }

                // Store negated y: zero padding at bytes 64-79, then neg_y at bytes 80-127
                mstore(add(dst, 0x40), 0) // Zero padding (bytes 64-95, top 16 bytes)
                mstore(add(dst, 80), neg_y_high) // bytes 80-111
                mstore(add(dst, 112), shl(128, neg_y_low)) // bytes 112-127 (16 bytes)
            }
        }
    }

    /// @dev Build pairing data and verify via precompile. Assembly-optimized.
    function _verifyPairing(
        bytes memory negatedKey,
        bytes calldata signature,
        bytes memory messagePoint,
        uint256 nodeCount
    ) internal view returns (bool) {
        uint256 requiredGas = _calculateRequiredGas(nodeCount);

        // Load generator point into memory (can't reference bytes constant in assembly)
        bytes memory gen = GENERATOR_POINT;

        bool isValid;
        assembly {
            // Allocate 768 bytes for pairing input
            let pairingData := mload(0x40)
            mstore(0x40, add(pairingData, 768))

            // ── First pairing: (generator, signature) ──
            let genPtr := add(gen, 0x20)
            let dst := pairingData
            mstore(dst, mload(genPtr))
            mstore(add(dst, 0x20), mload(add(genPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(genPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(genPtr, 0x60)))

            // Copy signature (256 bytes from calldata)
            dst := add(pairingData, 128)
            calldatacopy(dst, signature.offset, 256)

            // ── Second pairing: (negatedKey, messagePoint) ──
            let nkPtr := add(negatedKey, 0x20)
            dst := add(pairingData, 384)
            mstore(dst, mload(nkPtr))
            mstore(add(dst, 0x20), mload(add(nkPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(nkPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(nkPtr, 0x60)))

            // Copy messagePoint (256 bytes from memory — recomputed via _hashToG2)
            dst := add(pairingData, 512)
            mcopy(dst, add(messagePoint, 0x20), 256)

            // ── Call pairing precompile ──
            let resultPtr := mload(0x40)
            mstore(0x40, add(resultPtr, 0x20))

            let success := staticcall(requiredGas, 0x0f, pairingData, 768, resultPtr, 0x20)

            if success {
                isValid := eq(mload(resultPtr), 1)
            }
        }

        return isValid;
    }

    // ─── Gas Calculation ──────────────────────────────────────────────

    function _calculateRequiredGas(uint256 nodeCount) internal pure returns (uint256 requiredGas) {
        if (nodeCount == 0) return 0;

        // EIP-2537 pairing: 32600 * k + 37700, k = 2 pairings
        uint256 pairingCost = 102_900;
        // G1Add: (nodeCount - 1) * 500
        uint256 g1AddCost = nodeCount > 1 ? (nodeCount - 1) * 500 : 0;
        // Storage reads: nodeCount * 2100
        uint256 storageCost = nodeCount * 2100;
        // EVM overhead
        uint256 evmCost = 50_000 + (nodeCount * 1000);

        requiredGas = ((pairingCost + g1AddCost + storageCost + evmCost) * 125) / 100;

        // Clamp to [150k, 2M]
        if (requiredGas < 150_000) requiredGas = 150_000;
        if (requiredGas > 2_000_000) requiredGas = 2_000_000;
    }

    /// @notice Public gas estimate (NestJS-compatible)
    function getGasEstimate(uint256 nodeCount) external pure returns (uint256) {
        return _calculateRequiredGas(nodeCount);
    }

    // ─── Node Management (ABI-compatible with YetAA) ──────────────────

    function registerPublicKey(bytes32 nodeId, bytes calldata publicKey) external onlyOwner {
        if (nodeId == bytes32(0)) revert InvalidNodeId();
        if (publicKey.length != G1_POINT_LENGTH) revert InvalidKeyLength();
        if (isRegistered[nodeId]) revert NodeAlreadyRegistered();
        // v0.17.2-beta.1 round 5 LOW-2: refuse infinity G1 keys at registration time.
        if (_isG1InfinityCalldata(publicKey)) revert BLSPointAtInfinity();

        registeredKeys[nodeId] = publicKey;
        isRegistered[nodeId] = true;
        registeredNodes.push(nodeId);

        emit PublicKeyRegistered(nodeId, publicKey);
    }

    function updatePublicKey(bytes32 nodeId, bytes calldata newPublicKey) external onlyOwner {
        if (!isRegistered[nodeId]) revert NodeNotRegistered();
        if (newPublicKey.length != G1_POINT_LENGTH) revert InvalidKeyLength();
        if (_isG1InfinityCalldata(newPublicKey)) revert BLSPointAtInfinity();

        bytes memory oldKey = registeredKeys[nodeId];
        registeredKeys[nodeId] = newPublicKey;

        emit PublicKeyUpdated(nodeId, oldKey, newPublicKey);
    }

    function revokePublicKey(bytes32 nodeId) external onlyOwner {
        if (!isRegistered[nodeId]) revert NodeNotRegistered();

        delete registeredKeys[nodeId];
        isRegistered[nodeId] = false;

        // Pop-and-swap removal
        uint256 len = registeredNodes.length;
        for (uint256 i = 0; i < len; i++) {
            if (registeredNodes[i] == nodeId) {
                registeredNodes[i] = registeredNodes[len - 1];
                registeredNodes.pop();
                break;
            }
        }

        emit PublicKeyRevoked(nodeId);
    }

    function batchRegisterPublicKeys(bytes32[] calldata nodeIds, bytes[] calldata publicKeys) external onlyOwner {
        if (nodeIds.length != publicKeys.length) revert ArrayLengthMismatch();
        if (nodeIds.length == 0) revert EmptyArrays();

        for (uint256 i = 0; i < nodeIds.length; i++) {
            if (nodeIds[i] == bytes32(0)) revert InvalidNodeId();
            if (publicKeys[i].length != G1_POINT_LENGTH) revert InvalidKeyLength();
            if (isRegistered[nodeIds[i]]) revert NodeAlreadyRegistered();
            // v0.17.2-beta.1 round 5 LOW-2: refuse infinity G1 keys at registration time.
            if (_isG1Infinity(publicKeys[i])) revert BLSPointAtInfinity();

            registeredKeys[nodeIds[i]] = publicKeys[i];
            isRegistered[nodeIds[i]] = true;
            registeredNodes.push(nodeIds[i]);

            emit PublicKeyRegistered(nodeIds[i], publicKeys[i]);
        }
    }

    function getRegisteredNodeCount() external view returns (uint256) {
        return registeredNodes.length;
    }

    function getRegisteredNodes(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory nodeIds, bytes[] memory publicKeys) {
        uint256 total = registeredNodes.length;
        if (offset >= total) {
            return (new bytes32[](0), new bytes[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 length = end - offset;

        nodeIds = new bytes32[](length);
        publicKeys = new bytes[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 nid = registeredNodes[offset + i];
            nodeIds[i] = nid;
            publicKeys[i] = registeredKeys[nid];
        }
    }

    /// @notice Public aggregation for external callers (e.g., BLSAggregator).
    ///         Always on-demand — cache removed in v0.17.2-beta.1 (see HIGH-1 above).
    function aggregateKeys(bytes32[] calldata nodeIds) external view returns (bytes memory) {
        if (nodeIds.length == 0) revert NoNodesProvided();

        bytes memory result = registeredKeys[nodeIds[0]];
        if (!isRegistered[nodeIds[0]]) revert NodeNotRegistered();

        for (uint256 i = 1; i < nodeIds.length; i++) {
            if (!isRegistered[nodeIds[i]]) revert NodeNotRegistered();
            result = _g1Add(result, registeredKeys[nodeIds[i]]);
        }
        return result;
    }

    /// @notice issue #45 Part B: set the single protocol-level batch BLS aggregator.
    ///         Only `owner` (intended to be the protocol Gnosis Safe) may call this. There is no
    ///         per-account aggregator and no end-user setter — this one value governs the batch
    ///         path for every account that reads `blsAlgorithm.aggregator()`. Pass `address(0)` to
    ///         disable batch aggregation protocol-wide (accounts fall back to inline single-op BLS).
    function setAggregator(address agg) external onlyOwner {
        aggregator = agg;
        emit AggregatorSet(agg);
    }

    /// @notice Begin a two-step ownership transfer (Ownable2Step). Records `newOwner` as pending;
    ///         the transfer only completes when `newOwner` calls `acceptOwnership()`. Use this for
    ///         the deployer-EOA → protocol-Safe handover so a wrong address cannot take ownership.
    ///         Pass `address(0)` to cancel a pending transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete a two-step ownership transfer. Only the pending owner may accept.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }
}
