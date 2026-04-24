// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PureToken.sol";

contract DeployWithGas is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy with explicit high gas
        PureToken token = new PureToken(1000000 * 10**18);

        console.log("PureToken deployed at:", address(token));

        vm.stopBroadcast();
    }
}
