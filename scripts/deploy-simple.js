import hre from "hardhat";

async function main() {
  console.log("=== Deploying Contracts to DChain ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Network:", hre.network.name);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  const opts = { gasLimit: 3000000, type: 0 };

  // 1. DiktiToken
  console.log("1. Deploying DiktiToken...");
  const DiktiToken = await hre.ethers.getContractFactory("DiktiToken");
  const dkt = await DiktiToken.deploy(deployer.address, opts);
  await dkt.waitForDeployment();
  const dktAddr = await dkt.getAddress();
  console.log("✅ DiktiToken:", dktAddr);

  // 2. FundingPool
  console.log("\n2. Deploying FundingPool...");
  const FundingPool = await hre.ethers.getContractFactory("FundingPool");
  const fundingPool = await FundingPool.deploy(deployer.address, dktAddr, opts);
  await fundingPool.waitForDeployment();
  const fundingPoolAddr = await fundingPool.getAddress();
  console.log("✅ FundingPool:", fundingPoolAddr);

  // 3. StakingVault
  console.log("\n3. Deploying StakingVault...");
  const StakingVault = await hre.ethers.getContractFactory("StakingVault");
  const stakingVault = await StakingVault.deploy(opts);
  await stakingVault.waitForDeployment();
  const stakingVaultAddr = await stakingVault.getAddress();
  console.log("✅ StakingVault:", stakingVaultAddr);

  // 4. YieldDistributor
  console.log("\n4. Deploying YieldDistributor...");
  const YieldDistributor = await hre.ethers.getContractFactory("YieldDistributor");
  const yieldDist = await YieldDistributor.deploy(opts);
  await yieldDist.waitForDeployment();
  const yieldDistAddr = await yieldDist.getAddress();
  console.log("✅ YieldDistributor:", yieldDistAddr);

  // Initialize them
  console.log("\n   Initializing StakingVault...");
  const lockPeriod = 7 * 24 * 60 * 60; // 7 days in seconds
  await stakingVault.initialize(deployer.address, dktAddr, yieldDistAddr, lockPeriod);
  console.log("   ✓ StakingVault initialized");

  console.log("   Initializing YieldDistributor...");
  const initialYieldRate = hre.ethers.parseEther("0.1"); // 10% initial yield rate
  await yieldDist.initialize(deployer.address, initialYieldRate, dktAddr);
  console.log("   ✓ YieldDistributor initialized");

  // 5. ProjectFactory
  console.log("\n5. Deploying ProjectFactory...");
  const ProjectFactory = await hre.ethers.getContractFactory("ProjectFactory");
  const factory = await ProjectFactory.deploy(
    fundingPoolAddr,
    stakingVaultAddr,
    yieldDistAddr,
    opts
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("✅ ProjectFactory:", factoryAddr);

  console.log("\n=== Summary ===");
  console.log(`DiktiToken: ${dktAddr}`);
  console.log(`FundingPool: ${fundingPoolAddr}`);
  console.log(`StakingVault: ${stakingVaultAddr}`);
  console.log(`YieldDistributor: ${yieldDistAddr}`);
  console.log(`ProjectFactory: ${factoryAddr}`);

  console.log("\n=== Copy to frontend/.env.local ===");
  console.log(`NEXT_PUBLIC_DKT_ADDRESS=${dktAddr}`);
  console.log(`NEXT_PUBLIC_FUNDING_POOL_ADDRESS=${fundingPoolAddr}`);
  console.log(`NEXT_PUBLIC_STAKING_VAULT_ADDRESS=${stakingVaultAddr}`);
  console.log(`NEXT_PUBLIC_YIELD_DISTRIBUTOR_ADDRESS=${yieldDistAddr}`);
  console.log(`NEXT_PUBLIC_PROJECT_FACTORY_ADDRESS=${factoryAddr}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:");
    console.error(error.message);
    console.error(error);
    process.exit(1);
  });
