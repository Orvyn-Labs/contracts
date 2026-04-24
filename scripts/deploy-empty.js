import hre from "hardhat";

async function main() {
  console.log("=== Testing Empty Contract ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Network:", hre.network.name);

  const Empty = await hre.ethers.getContractFactory("Empty");

  console.log("\nDeploying Empty contract...");

  const contract = await Empty.deploy({
    gasLimit: 1000000,
    type: 0,
  });

  console.log("TX hash:", contract.deploymentTransaction()?.hash);
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log("\n✅ Deployed to:", address);

  const code = await hre.ethers.provider.getCode(address);
  console.log("Has bytecode:", code !== "0x");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:", error.message);
    process.exit(1);
  });
