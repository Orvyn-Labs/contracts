import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";

export default {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: "paris",
    },
  },
  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache_hardhat",
    artifacts: "./artifacts"
  },
  networks: {
    dchain: {
      url: "https://mainnet.dchain.id",
      chainId: 17845,
      accounts: ["0x8e300b1de89308565770c14123994cb6582559b3406b5dbe318c7d227504fd7f"],
      gasPrice: 1500000008,
    },
  },
};
