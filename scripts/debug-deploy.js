import hre from "hardhat";

async function main() {
  console.log("=== Debug Deployment ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const TestMinimal = await hre.ethers.getContractFactory("TestMinimal");

  // Get the deployment transaction data
  const deployTx = await TestMinimal.getDeployTransaction();

  console.log("\nDeployment transaction:");
  console.log("Data length:", deployTx.data.length);
  console.log("Data (first 100 chars):", deployTx.data.substring(0, 100));

  // Manually send the transaction
  console.log("\nSending transaction...");
  const tx = await deployer.sendTransaction({
    data: deployTx.data,
    gasLimit: 5000000,
    type: 0,
  });

  console.log("TX hash:", tx.hash);
  console.log("TX data length:", tx.data.length);

  const receipt = await tx.wait();
  console.log("\nReceipt:");
  console.log("Status:", receipt.status);
  console.log("Gas used:", receipt.gasUsed.toString());
  console.log("Contract address:", receipt.contractAddress);

  if (receipt.contractAddress) {
    const code = await hre.ethers.provider.getCode(receipt.contractAddress);
    console.log("\nContract bytecode length:", code.length);
    console.log("Has bytecode:", code !== "0x");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:", error.message);
    console.error(error);
    process.exit(1);
  });
