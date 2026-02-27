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
 * @notice Full deployment script for the research crowdfunding system (DKT-everywhere v3).
 *
 * All amounts — donations, yield, refunds — are denominated in DKT (18 decimals).
 * No native ETH is used in the protocol logic.
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --verifier-url https://api-sepolia.basescan.org/api \
 *     --etherscan-api-key $BASESCAN_API_KEY \
 *     -vvv
 */
contract Deploy is Script {
    uint256 constant INITIAL_YIELD_RATE    = 0.10e18;   // 10% APY
    uint256 constant INITIAL_LOCK_PERIOD   = 7 days;
    uint256 constant INITIAL_YIELD_POOL_DKT = 10_000 ether; // 10,000 DKT seed

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DChain Deployment (DKT-everywhere v3) ===");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Block:     ", block.number);

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. DiktiToken ────────────────────────────────────────────────────
        DiktiToken dkt = new DiktiToken(deployer);
        console.log("DiktiToken:                ", address(dkt));

        // Mint deployer enough DKT to seed the yield pool + some for testing
        dkt.mint(deployer, INITIAL_YIELD_POOL_DKT + 100_000 ether);
        console.log("Minted to deployer:        ", INITIAL_YIELD_POOL_DKT + 100_000 ether);

        // ── 2. YieldDistributor (UUPS proxy) ─────────────────────────────────
        YieldDistributor distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(
            YieldDistributor.initialize,
            (deployer, INITIAL_YIELD_RATE, address(dkt))
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(distImpl), distInit);
        YieldDistributor dist = YieldDistributor(address(distProxy));
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
        FundingPool fundingPool = new FundingPool(deployer, address(dkt));
        console.log("FundingPool:               ", address(fundingPool));

        // ── 5. ResearchProject implementation ────────────────────────────────
        ResearchProject projectImpl = new ResearchProject();
        console.log("ResearchProject impl:      ", address(projectImpl));

        // ── 6. ProjectFactory ─────────────────────────────────────────────────
        ProjectFactory factory = new ProjectFactory(
            deployer,
            address(projectImpl),
            payable(address(fundingPool)),
            address(dkt)
        );
        console.log("ProjectFactory:            ", address(factory));
        console.log("UpgradeableBeacon:         ", address(factory.beacon()));

        // ── 7. Wire: StakingVault → YieldDistributor ──────────────────────────
        dist.setStakingVault(address(vault));

        // ── 8. Wire: FundingPool roles ────────────────────────────────────────
        fundingPool.grantRole(fundingPool.DEFAULT_ADMIN_ROLE(), address(factory));
        fundingPool.grantRole(fundingPool.DEPOSITOR_ROLE(), address(dist));
        dist.setFundingPool(address(fundingPool));

        // ── 9. Approve + fund yield pool with DKT ────────────────────────────
        dkt.approve(address(dist), INITIAL_YIELD_POOL_DKT);
        dist.fundYieldPool(INITIAL_YIELD_POOL_DKT);
        console.log("YieldPool funded with DKT: ", INITIAL_YIELD_POOL_DKT);

        vm.stopBroadcast();

        console.log("---------------------------------------------");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Copy to .env.local:");
        console.log("NEXT_PUBLIC_DKT_ADDRESS=",            address(dkt));
        console.log("NEXT_PUBLIC_YIELD_DISTRIBUTOR=",      address(dist));
        console.log("NEXT_PUBLIC_STAKING_VAULT=",          address(vault));
        console.log("NEXT_PUBLIC_FUNDING_POOL=",           address(fundingPool));
        console.log("NEXT_PUBLIC_PROJECT_FACTORY=",        address(factory));
        console.log("NEXT_PUBLIC_CHAIN_ID=",               block.chainid);
    }
}
