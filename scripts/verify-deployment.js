import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://mainnet.dchain.id");

const addresses = {
  DiktiToken: "0xe03fe86f156D0f0bb365aC1f5a4cC2E484AEC1Ea",
  FundingPool: "0xf769F07598EBB31EAc93FA715b90fFA5170ADc0B",
  StakingVault: "0xd9E1cf5dC55BF9Ba0DF9620dA658c6127AD29C6A",
  YieldDistributor: "0xcfAA081C8C164e53A4cDEfB4cA285a0e8fAc8b0d",
};

console.log("=== Verifying DChain Deployment ===\n");

for (const [name, address] of Object.entries(addresses)) {
  const code = await provider.getCode(address);
  const hasCode = code !== "0x";
  console.log(`${name}:`);
  console.log(`  Address: ${address}`);
  console.log(`  Deployed: ${hasCode ? "✅ YES" : "❌ NO"}`);
  console.log(`  Bytecode length: ${code.length}`);
  console.log();
}
