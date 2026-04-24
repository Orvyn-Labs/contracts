import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://mainnet.dchain.id");
const txHash = process.argv[2];

const tx = await provider.getTransaction(txHash);
const receipt = await provider.getTransactionReceipt(txHash);

console.log("Transaction:", txHash);
console.log("\nTransaction data:");
console.log("  Data length:", tx.data.length);
console.log("  Data (first 100):", tx.data.substring(0, 100));
console.log("  To:", tx.to);
console.log("  Gas limit:", tx.gasLimit.toString());
console.log("  Type:", tx.type);

console.log("\nReceipt:");
console.log("  Status:", receipt.status);
console.log("  Gas used:", receipt.gasUsed.toString());
console.log("  Contract address:", receipt.contractAddress);

if (receipt.contractAddress) {
  const code = await provider.getCode(receipt.contractAddress);
  console.log("\nContract bytecode:");
  console.log("  Length:", code.length);
  console.log("  Has code:", code !== "0x");
}
