// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/DiktiToken.sol";
import "../src/StakingVault.sol";
import "../src/YieldDistributor.sol";
import "../src/FundingPool.sol";
import "../src/ResearchProject.sol";
import "../src/ProjectFactory.sol";

/**
 * @title Deploy
 * @notice Full deployment script for the research crowdfunding system.
 *
 * Usage:
 *   # Local Anvil fork
 *   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast -vvv
 *
 *   # Base Sepolia testnet
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --verifier-url https://api-sepolia.basescan.org/api \
 *     --etherscan-api-key $BASESCAN_API_KEY \
 *     -vvv
 *
 * Deployment order (dependency graph):
 *   1. DiktiToken
 *   2. YieldDistributor implementation + UUPS proxy
 *   3. StakingVault implementation + UUPS proxy
 *   4. FundingPool
 *   5. ResearchProject implementation
 *   6. ProjectFactory (deploys UpgradeableBeacon internally)
 *   7. Wire: setStakingVault on YieldDistributor
 *   8. Wire: grant DEPOSITOR_ROLE + DEFAULT_ADMIN_ROLE to ProjectFactory on FundingPool
 *   9. (Optional) Fund yield pool with initial ETH
 */
contract Deploy is Script {
    // ─── Configuration (override via environment variables) ──────────────────
    uint256 constant INITIAL_YIELD_RATE = 0.10e18;  // 10% APY
    uint256 constant INITIAL_LOCK_PERIOD = 7 days;   // 7-day stake lock

    // Initial ETH to fund the yield pool (set to 0 to skip)
    uint256 constant INITIAL_YIELD_POOL_FUNDING = 0.1 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Research Crowdfunding dApp Deployment ===");
        console.log("Deployer:   ", deployer);
        console.log("Chain ID:   ", block.chainid);
        console.log("Block:      ", block.number);
        console.log("Timestamp:  ", block.timestamp);
        console.log("---------------------------------------------");

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. DiktiToken ────────────────────────────────────────────────────
        DiktiToken dkt = new DiktiToken(deployer);
        console.log("DiktiToken (DKT):          ", address(dkt));

        // ── 2. YieldDistributor (UUPS proxy) ─────────────────────────────────
        YieldDistributor distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(
            YieldDistributor.initialize,
            (deployer, INITIAL_YIELD_RATE)
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(distImpl), distInit);
        YieldDistributor dist = YieldDistributor(payable(address(distProxy)));
        console.log("YieldDistributor impl:     ", address(distImpl));
        console.log("YieldDistributor proxy:    ", address(dist));

        // ── 3. StakingVault (UUPS proxy) ──────────────────────────────────────
        StakingVault vaultImpl = new StakingVault();
        bytes memory vaultInit = abi.encodeCall(
            StakingVault.initialize,
            (deployer, address(dkt), address(dist), INITIAL_LOCK_PERIOD)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInit);
        StakingVault vault = StakingVault(address(vaultProxy));
        console.log("StakingVault impl:         ", address(vaultImpl));
        console.log("StakingVault proxy:        ", address(vault));

        // ── 4. FundingPool ────────────────────────────────────────────────────
        FundingPool fundingPool = new FundingPool(deployer);
        console.log("FundingPool:               ", address(fundingPool));

        // ── 5. ResearchProject implementation ────────────────────────────────
        ResearchProject projectImpl = new ResearchProject();
        console.log("ResearchProject impl:      ", address(projectImpl));

        // ── 6. ProjectFactory (creates UpgradeableBeacon internally) ─────────
        ProjectFactory factory = new ProjectFactory(
            deployer,
            address(projectImpl),
            payable(address(fundingPool))
        );
        console.log("ProjectFactory:            ", address(factory));
        console.log("UpgradeableBeacon:         ", address(factory.beacon()));

        // ── 7. Wire: StakingVault → YieldDistributor ──────────────────────────
        dist.setStakingVault(address(vault));
        console.log("YieldDistributor.stakingVault set to:", address(vault));

        // ── 8. Wire: FundingPool roles ────────────────────────────────────────
        // ProjectFactory needs DEFAULT_ADMIN_ROLE on FundingPool to grant DEPOSITOR_ROLE
        // to each newly deployed ResearchProject
        fundingPool.grantRole(fundingPool.DEFAULT_ADMIN_ROLE(), address(factory));
        console.log("FundingPool: DEFAULT_ADMIN_ROLE granted to factory");

        // ── 9. (Optional) Fund yield pool ────────────────────────────────────
        if (INITIAL_YIELD_POOL_FUNDING > 0 && deployer.balance >= INITIAL_YIELD_POOL_FUNDING) {
            dist.fundYieldPool{value: INITIAL_YIELD_POOL_FUNDING}();
            console.log("YieldPool funded with:     ", INITIAL_YIELD_POOL_FUNDING);
        }

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────────────────
        console.log("---------------------------------------------");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Copy these addresses to your .env / frontend config:");
        console.log("NEXT_PUBLIC_DKT_ADDRESS=",            address(dkt));
        console.log("NEXT_PUBLIC_YIELD_DISTRIBUTOR=",      address(dist));
        console.log("NEXT_PUBLIC_STAKING_VAULT=",          address(vault));
        console.log("NEXT_PUBLIC_FUNDING_POOL=",           address(fundingPool));
        console.log("NEXT_PUBLIC_PROJECT_FACTORY=",        address(factory));
        console.log("NEXT_PUBLIC_CHAIN_ID=",               block.chainid);
    }
}
