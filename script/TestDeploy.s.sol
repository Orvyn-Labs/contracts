// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Simple test contract
contract SimpleToken {
    string public name = "Test";
    uint256 public totalSupply = 1000000;
}

contract TestDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Testing DChain deployment...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        SimpleToken token = new SimpleToken();
        console.log("SimpleToken deployed at:", address(token));

        vm.stopBroadcast();
    }
}
