// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AlgTierLib
/// @notice Shared algorithm-to-security-tier mapping for AAStarAirAccountBase and AAStarGlobalGuard.
/// @dev When adding a new algId: update ONLY this library. Both contracts derive tier from here.
library AlgTierLib {
    /// @notice Map an algId to its security tier level (0-3).
    /// @dev Tier 0 = unrecognised / resolved externally (ALG_WEIGHTED).
    ///      Tier 1 = single-factor (ECDSA, P256, COMBINED_T1, SESSION_KEY).
    ///      Tier 2 = dual-factor (P256 + BLS DVT).
    ///      Tier 3 = triple-factor (P256 + BLS + Guardian ECDSA).
    function algTier(uint8 algId) internal pure returns (uint8) {
        // Tier 3 - triple factor
        if (algId == 0x05 || algId == 0x01 || algId == 0x0a) return 3; // ALG_CUMULATIVE_T3, ALG_BLS legacy triple, ALG_CUMULATIVE_T3_WA
        // Tier 2 - dual factor
        if (algId == 0x04 || algId == 0x09) return 2;                   // ALG_CUMULATIVE_T2, ALG_CUMULATIVE_T2_WA
        // Tier 1 - single factor
        if (algId == 0x02 || algId == 0x03 || algId == 0x06 || algId == 0x08) return 1; // ECDSA, P256, COMBINED_T1, SESSION_KEY
        // ALG_WEIGHTED (0x07) is resolved to a concrete algId before tier checks.
        return 0;
    }
}
