// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PureToken.sol";

contract DeployPure is Script {
    function run() external {
        vm.startBroadcast();

        PureToken token = new PureToken(1000000 * 10**18);

        console.log("PureToken deployed at:", address(token));
        console.log("Balance:", token.balanceOf(msg.sender));

        vm.stopBroadcast();
    }
}
