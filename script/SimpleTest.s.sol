// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

contract HelloDChain {
    string public message = "Hello from DChain!";
    uint256 public number = 42;

    function setMessage(string memory _msg) public {
        message = _msg;
    }
}

contract SimpleTest is Script {
    function run() external {
        vm.startBroadcast();

        HelloDChain hello = new HelloDChain();
        console.log("HelloDChain deployed at:", address(hello));

        vm.stopBroadcast();
    }
}
