// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Script, console2} from "forge-std/Script.sol";
import {ForceExitModule} from "../src/core/ForceExitModule.sol";

/// @title DeployForceExitOnly — Re-deploy just ForceExitModule for v0.17.2-beta.2.
/// @notice The v0.17.2-beta.2 release contains a single Solidity source change
///         in ForceExitModule.sol (LOW-3 stale-guardian check). All other 10
///         contracts deployed at v0.17.2-beta.1 keep their addresses. Only the
///         ForceExitModule singleton is redeployed.
///
///         Old ForceExitModule (v0.17.2-beta.1, no LOW-3 fix):
///           0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9 — DEPRECATED
///
/// @dev Same env var pattern as DeployV0172Beta.s.sol — broadcaster taken from
///      DEPLOYER_KEY env (Anni's key in .env.sepolia).
contract DeployForceExitOnly is Script {
    function run() external {
        console2.log("=== Deploy ForceExitModule v0.17.2-beta.2 (LOW-3 stale-guardian fix) ===");
        console2.log("chainid          :", block.chainid);

        uint256 deployerKey = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        ForceExitModule fem = new ForceExitModule();
        console2.log("Deployed ForceExitModule (v0.17.2-beta.2):", address(fem));

        vm.stopBroadcast();
    }
}
