import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://mainnet.dchain.id");

// The successful contract address from earlier
const contractAddress = "0xdf8C6401E6375e84184cf33d7bC2314970C89996";

console.log("Analyzing successful deployment...\n");

// Get the bytecode
const code = await provider.getCode(contractAddress);
console.log("Contract has bytecode:", code !== "0x");
console.log("Bytecode length:", code.length);

// Try to find creation transaction
// We need to scan blocks to find it
console.log("\nNote: Finding the creation transaction requires block scanning");
console.log("Contract address:", contractAddress);
