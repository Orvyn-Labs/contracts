import hre from "hardhat";

async function main() {
  console.log("=== Deploying All Contracts to DChain ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  const deploymentOptions = {
    gasLimit: 3000000,
    type: 0,
  };

  // 1. Deploy DiktiToken
  console.log("1. Deploying DiktiToken...");
  const DiktiToken = await hre.ethers.getContractFactory("DiktiToken");
  const dkt = await DiktiToken.deploy(deployer.address, deploymentOptions);
  await dkt.waitForDeployment();
  const dktAddress = await dkt.getAddress();
  console.log("✅ DiktiToken:", dktAddress);

  // 2. Deploy StakingVault (UUPS Proxy)
  console.log("\n2. Deploying StakingVault...");
  const StakingVault = await hre.ethers.getContractFactory("StakingVault");
  const stakingVault = await hre.ethers.upgrades.deployProxy(
    StakingVault,
    [dktAddress],
    { kind: "uups", ...deploymentOptions }
  );
  await stakingVault.waitForDeployment();
  const stakingVaultAddress = await stakingVault.getAddress();
  console.log("✅ StakingVault:", stakingVaultAddress);

  // 3. Deploy YieldDistributor (UUPS Proxy)
  console.log("\n3. Deploying YieldDistributor...");
  const YieldDistributor = await hre.ethers.getContractFactory("YieldDistributor");
  const yieldDistributor = await hre.ethers.upgrades.deployProxy(
    YieldDistributor,
    [stakingVaultAddress],
    { kind: "uups", ...deploymentOptions }
  );
  await yieldDistributor.waitForDeployment();
  const yieldDistributorAddress = await yieldDistributor.getAddress();
  console.log("✅ YieldDistributor:", yieldDistributorAddress);

  // 4. Deploy FundingPool
  console.log("\n4. Deploying FundingPool...");
  const FundingPool = await hre.ethers.getContractFactory("FundingPool");
  const fundingPool = await FundingPool.deploy(deploymentOptions);
  await fundingPool.waitForDeployment();
  const fundingPoolAddress = await fundingPool.getAddress();
  console.log("✅ FundingPool:", fundingPoolAddress);

  // 5. Deploy ProjectFactory
  console.log("\n5. Deploying ProjectFactory...");
  const ProjectFactory = await hre.ethers.getContractFactory("ProjectFactory");
  const projectFactory = await ProjectFactory.deploy(
    fundingPoolAddress,
    stakingVaultAddress,
    yieldDistributorAddress,
    deploymentOptions
  );
  await projectFactory.waitForDeployment();
  const projectFactoryAddress = await projectFactory.getAddress();
  console.log("✅ ProjectFactory:", projectFactoryAddress);

  // Print summary
  console.log("\n=== Deployment Summary ===");
  console.log(`DiktiToken: ${dktAddress}`);
  console.log(`StakingVault: ${stakingVaultAddress}`);
  console.log(`YieldDistributor: ${yieldDistributorAddress}`);
  console.log(`FundingPool: ${fundingPoolAddress}`);
  console.log(`ProjectFactory: ${projectFactoryAddress}`);

  console.log("\n=== Copy to frontend/.env.local ===");
  console.log(`NEXT_PUBLIC_DKT_ADDRESS=${dktAddress}`);
  console.log(`NEXT_PUBLIC_STAKING_VAULT_ADDRESS=${stakingVaultAddress}`);
  console.log(`NEXT_PUBLIC_YIELD_DISTRIBUTOR_ADDRESS=${yieldDistributorAddress}`);
  console.log(`NEXT_PUBLIC_FUNDING_POOL_ADDRESS=${fundingPoolAddress}`);
  console.log(`NEXT_PUBLIC_PROJECT_FACTORY_ADDRESS=${projectFactoryAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:");
    console.error(error);
    process.exit(1);
  });
