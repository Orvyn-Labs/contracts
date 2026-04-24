import hre from "hardhat";

async function main() {
  console.log("=== Initializing Deployed Contracts ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const addresses = {
    dkt: "0xe03fe86f156D0f0bb365aC1f5a4cC2E484AEC1Ea",
    fundingPool: "0xf769F07598EBB31EAc93FA715b90fFA5170ADc0B",
    stakingVault: "0xd9E1cf5dC55BF9Ba0DF9620dA658c6127AD29C6A",
    yieldDistributor: "0xcfAA081C8C164e53A4cDEfB4cA285a0e8fAc8b0d",
  };

  // Attach to deployed contracts
  const StakingVault = await hre.ethers.getContractFactory("StakingVault");
  const stakingVault = StakingVault.attach(addresses.stakingVault);

  const YieldDistributor = await hre.ethers.getContractFactory("YieldDistributor");
  const yieldDist = YieldDistributor.attach(addresses.yieldDistributor);

  // Try to initialize StakingVault
  console.log("Initializing StakingVault...");
  try {
    const lockPeriod = 7 * 24 * 60 * 60; // 7 days
    const tx = await stakingVault.initialize(
      deployer.address,
      addresses.dkt,
      addresses.yieldDistributor,
      lockPeriod,
      { gasLimit: 3000000, type: 0 }
    );
    console.log("TX hash:", tx.hash);
    await tx.wait();
    console.log("✅ StakingVault initialized");
  } catch (error) {
    console.log("❌ StakingVault initialization failed:");
    console.log("Error:", error.message);
    if (error.data) {
      console.log("Error data:", error.data);
    }
  }

  // Try to initialize YieldDistributor
  console.log("\nInitializing YieldDistributor...");
  try {
    const initialYieldRate = hre.ethers.parseEther("0.1"); // 10%
    const tx = await yieldDist.initialize(
      deployer.address,
      initialYieldRate,
      addresses.dkt,
      { gasLimit: 3000000, type: 0 }
    );
    console.log("TX hash:", tx.hash);
    await tx.wait();
    console.log("✅ YieldDistributor initialized");
  } catch (error) {
    console.log("❌ YieldDistributor initialization failed:");
    console.log("Error:", error.message);
    if (error.data) {
      console.log("Error data:", error.data);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Fatal error:");
    console.error(error);
    process.exit(1);
  });
