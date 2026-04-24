import fs from "fs";

const contractPath = process.argv[2];
const data = JSON.parse(fs.readFileSync(contractPath, "utf-8"));

console.log("Contract:", contractPath.split("/").pop().replace(".json", ""));
console.log("Bytecode length:", data.bytecode.length);
console.log("Has bytecode:", data.bytecode !== "0x");
console.log("First 100 chars:", data.bytecode.substring(0, 100));
