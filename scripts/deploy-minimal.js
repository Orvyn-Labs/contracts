import hre from "hardhat";

async function main() {
  console.log("=== Testing Minimal Contract Deployment ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer address:", deployer.address);
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  console.log("Deploying TestMinimal...");

  const TestMinimal = await hre.ethers.getContractFactory("TestMinimal");

  // Try with higher gas limit and legacy transaction
  const contract = await TestMinimal.deploy({
    gasLimit: 5000000, // 5M gas
    type: 0, // Legacy transaction
  });

  console.log("Transaction sent, waiting for deployment...");
  console.log("Transaction hash:", contract.deploymentTransaction()?.hash);

  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log("\n✅ TestMinimal deployed to:", address);

  // Verify it has code
  const code = await hre.ethers.provider.getCode(address);
  console.log("Contract has bytecode:", code !== "0x");
  console.log("Bytecode length:", code.length);

  if (code !== "0x") {
    const number = await contract.number();
    console.log("\nContract works!");
    console.log("Number:", number.toString());
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:");
    console.error(error.message);
    if (error.transaction) {
      console.log("\nTransaction:", error.transaction);
    }
    if (error.receipt) {
      console.log("\nReceipt:", error.receipt);
    }
    process.exit(1);
  });
