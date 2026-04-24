import hre from "hardhat";

async function main() {
  console.log("=== Testing DiktiToken Deployment ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer address:", deployer.address);
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);

  // Get balance
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  console.log("Deploying DiktiToken...");

  // Get contract factory
  const DiktiToken = await hre.ethers.getContractFactory("DiktiToken");

  // Deploy with settings from successful deployment
  const dkt = await DiktiToken.deploy(deployer.address, {
    gasLimit: 3000000, // 3M gas
    type: 0, // Legacy transaction
  });

  console.log("Transaction sent, waiting for deployment...");
  await dkt.waitForDeployment();

  const address = await dkt.getAddress();
  console.log("\n✅ DiktiToken deployed to:", address);

  // Verify it has code
  const code = await hre.ethers.provider.getCode(address);
  console.log("Contract has bytecode:", code !== "0x");

  if (code !== "0x") {
    // Test the contract
    const name = await dkt.name();
    const symbol = await dkt.symbol();
    console.log("\nContract works!");
    console.log("Name:", name);
    console.log("Symbol:", symbol);
  }

  console.log("\n=== COPY THIS ===");
  console.log(`NEXT_PUBLIC_DKT_ADDRESS=${address}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:");
    console.error(error.message);
    if (error.transaction) {
      console.log("\nTransaction hash:", error.transaction.hash);
    }
    process.exit(1);
  });
