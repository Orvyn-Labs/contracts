// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/tokens/DiktiToken.sol";

/**
 * @title DeploySimple
 * @notice Deploy ONLY DiktiToken (no proxies) to test DChain compatibility
 */
contract DeploySimple is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Simple DChain Test ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy ONLY the token (no proxies, no complex setup)
        DiktiToken dkt = new DiktiToken(deployer);
        console.log("DiktiToken deployed at:", address(dkt));

        // Mint some tokens to verify it works
        dkt.mint(deployer, 1000 ether);
        console.log("Minted 1000 DKT to deployer");

        // Check balance
        uint256 balance = dkt.balanceOf(deployer);
        console.log("Balance:", balance);

        vm.stopBroadcast();

        console.log("=== Test Complete ===");
        console.log("If you see this, deployment worked!");
    }
}
