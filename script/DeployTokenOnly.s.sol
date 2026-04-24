// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/tokens/DiktiToken.sol";

contract DeployTokenOnly is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying ONLY DiktiToken ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        DiktiToken dkt = new DiktiToken(deployer);

        console.log("DiktiToken:", address(dkt));
        console.log("Success!");

        vm.stopBroadcast();
    }
}
