import hre from "hardhat";

async function main() {
  console.log("=== Deploying Contracts with Proxies ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  const opts = { gasLimit: 3000000, type: 0 };

  // Use existing DiktiToken and FundingPool
  const dktAddr = "0xe03fe86f156D0f0bb365aC1f5a4cC2E484AEC1Ea";
  const fundingPoolAddr = "0xf769F07598EBB31EAc93FA715b90fFA5170ADc0B";

  // Deploy StakingVault implementation
  console.log("1. Deploying StakingVault implementation...");
  const StakingVault = await hre.ethers.getContractFactory("StakingVault");
  const stakingVaultImpl = await StakingVault.deploy(opts);
  await stakingVaultImpl.waitForDeployment();
  const stakingVaultImplAddr = await stakingVaultImpl.getAddress();
  console.log("✅ Implementation:", stakingVaultImplAddr);

  // Deploy YieldDistributor implementation
  console.log("\n2. Deploying YieldDistributor implementation...");
  const YieldDistributor = await hre.ethers.getContractFactory("YieldDistributor");
  const yieldDistImpl = await YieldDistributor.deploy(opts);
  await yieldDistImpl.waitForDeployment();
  const yieldDistImplAddr = await yieldDistImpl.getAddress();
  console.log("✅ Implementation:", yieldDistImplAddr);

  // Deploy ERC1967Proxy for StakingVault
  console.log("\n3. Deploying StakingVault proxy...");
  const lockPeriod = 7 * 24 * 60 * 60; // 7 days
  const stakingInitData = StakingVault.interface.encodeFunctionData("initialize", [
    deployer.address,
    dktAddr,
    yieldDistImplAddr, // temporary, will update after YieldDist proxy
    lockPeriod,
  ]);

  const ERC1967Proxy = await hre.ethers.getContractFactory("MyERC1967Proxy");
  const stakingProxy = await ERC1967Proxy.deploy(
    stakingVaultImplAddr,
    stakingInitData,
    opts
  );
  await stakingProxy.waitForDeployment();
  const stakingProxyAddr = await stakingProxy.getAddress();
  console.log("✅ Proxy:", stakingProxyAddr);

  // Deploy ERC1967Proxy for YieldDistributor
  console.log("\n4. Deploying YieldDistributor proxy...");
  const initialYieldRate = hre.ethers.parseEther("0.1"); // 10%
  const yieldInitData = YieldDistributor.interface.encodeFunctionData("initialize", [
    deployer.address,
    initialYieldRate,
    dktAddr,
  ]);

  const yieldProxy = await ERC1967Proxy.deploy(
    yieldDistImplAddr,
    yieldInitData,
    opts
  );
  await yieldProxy.waitForDeployment();
  const yieldProxyAddr = await yieldProxy.getAddress();
  console.log("✅ Proxy:", yieldProxyAddr);

  // Deploy ResearchProject implementation
  console.log("\n5. Deploying ResearchProject implementation...");
  const ResearchProject = await hre.ethers.getContractFactory("ResearchProject");
  const researchProjectImpl = await ResearchProject.deploy(opts);
  await researchProjectImpl.waitForDeployment();
  const researchProjectImplAddr = await researchProjectImpl.getAddress();
  console.log("✅ Implementation:", researchProjectImplAddr);

  // Deploy ProjectFactory
  console.log("\n6. Deploying ProjectFactory...");
  const ProjectFactory = await hre.ethers.getContractFactory("ProjectFactory");
  const factory = await ProjectFactory.deploy(
    deployer.address,
    researchProjectImplAddr,
    fundingPoolAddr,
    dktAddr,
    opts
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("✅ ProjectFactory:", factoryAddr);

  console.log("\n=== DEPLOYMENT SUMMARY ===");
  console.log(`DiktiToken: ${dktAddr}`);
  console.log(`FundingPool: ${fundingPoolAddr}`);
  console.log(`StakingVault (Proxy): ${stakingProxyAddr}`);
  console.log(`YieldDistributor (Proxy): ${yieldProxyAddr}`);
  console.log(`ProjectFactory: ${factoryAddr}`);

  console.log("\n=== Copy to frontend/.env.local ===");
  console.log(`NEXT_PUBLIC_DKT_ADDRESS=${dktAddr}`);
  console.log(`NEXT_PUBLIC_FUNDING_POOL_ADDRESS=${fundingPoolAddr}`);
  console.log(`NEXT_PUBLIC_STAKING_VAULT_ADDRESS=${stakingProxyAddr}`);
  console.log(`NEXT_PUBLIC_YIELD_DISTRIBUTOR_ADDRESS=${yieldProxyAddr}`);
  console.log(`NEXT_PUBLIC_PROJECT_FACTORY_ADDRESS=${factoryAddr}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:");
    console.error(error);
    process.exit(1);
  });
