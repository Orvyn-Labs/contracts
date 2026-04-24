import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://mainnet.dchain.id");
const address = process.argv[2];

const code = await provider.getCode(address);
console.log("Address:", address);
console.log("Code length:", code.length);
console.log("Has bytecode:", code !== "0x");
