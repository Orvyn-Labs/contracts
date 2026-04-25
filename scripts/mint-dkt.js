import hre from "hardhat";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Minter:", deployer.address);
  console.log("Network:", hre.network.name);

  const dktAddr = process.env.NEXT_PUBLIC_DKT_ADDRESS || "0xe03fe86f156D0f0bb365aC1f5a4cC2E484AEC1Ea";
  const DiktiToken = await hre.ethers.getContractFactory("DiktiToken");
  const dkt = DiktiToken.attach(dktAddr);

  const minterRole = await dkt.MINTER_ROLE();
  const hasRole = await dkt.hasRole(minterRole, deployer.address);
  console.log("Has MINTER_ROLE:", hasRole);
  if (!hasRole) {
    console.error("Deployer does NOT have MINTER_ROLE. Cannot mint.");
    process.exit(1);
  }

  const recipient = process.argv[2];
  const amount = process.argv[3];

  if (!recipient || !amount) {
    console.log("Usage: npx hardhat run scripts/mint-dkt.js --network dchain <ADDRESS> <AMOUNT_IN_DKT>");
    console.log("\nExample:");
    console.log("  npx hardhat run scripts/mint-dkt.js --network dchain 0xAb5801... 1000");
    process.exit(0);
  }

  const parsedAmount = hre.ethers.parseEther(amount);
  const remaining = await dkt.remainingSupply();
  console.log("Remaining supply:", hre.ethers.formatEther(remaining), "DKT");

  if (parsedAmount > remaining) {
    console.error("Amount exceeds remaining supply!");
    process.exit(1);
  }

  console.log(`\nMinting ${amount} DKT to ${recipient}...`);
  const tx = await dkt.mint(recipient, parsedAmount, { gasLimit: 100000 });
  console.log("TX Hash:", tx.hash);
  await tx.wait();
  console.log("Minted successfully!");

  const newRemaining = await dkt.remainingSupply();
  console.log("New remaining supply:", hre.ethers.formatEther(newRemaining), "DKT");
  console.log("New total supply:", hre.ethers.formatEther(await dkt.totalSupply()), "DKT");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error.message);
    process.exit(1);
  });
