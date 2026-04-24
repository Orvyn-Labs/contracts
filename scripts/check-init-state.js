import hre from "hardhat";

async function main() {
  console.log("=== Checking Contract State ===\n");

  const addresses = {
    stakingVault: "0xd9E1cf5dC55BF9Ba0DF9620dA658c6127AD29C6A",
    yieldDistributor: "0xcfAA081C8C164e53A4cDEfB4cA285a0e8fAc8b0d",
  };

  // Check StakingVault
  const StakingVault = await hre.ethers.getContractFactory("StakingVault");
  const stakingVault = StakingVault.attach(addresses.stakingVault);

  console.log("StakingVault:");
  try {
    // Try to read some state that would be set during initialization
    const code = await hre.ethers.provider.getCode(addresses.stakingVault);
    console.log("  Has bytecode:", code !== "0x");
    console.log("  Bytecode length:", code.length);

    // Try calling a view function to see if it reverts
    try {
      // Most upgradeable contracts have a version() or similar function
      const owner = await stakingVault.owner();
      console.log("  Owner:", owner);
      console.log("  ✅ Contract appears to be initialized");
    } catch (e) {
      console.log("  ⚠️  Could not read owner, might not be initialized");
    }
  } catch (error) {
    console.log("  ❌ Error:", error.message);
  }

  console.log("\nYieldDistributor:");
  const YieldDistributor = await hre.ethers.getContractFactory("YieldDistributor");
  const yieldDist = YieldDistributor.attach(addresses.yieldDistributor);

  try {
    const code = await hre.ethers.provider.getCode(addresses.yieldDistributor);
    console.log("  Has bytecode:", code !== "0x");
    console.log("  Bytecode length:", code.length);

    try {
      const owner = await yieldDist.owner();
      console.log("  Owner:", owner);
      console.log("  ✅ Contract appears to be initialized");
    } catch (e) {
      console.log("  ⚠️  Could not read owner, might not be initialized");
    }
  } catch (error) {
    console.log("  ❌ Error:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
