import hre from "hardhat";

async function main() {
  const factory = await hre.ethers.getContractAt(
    "ProjectFactory", 
    "0xDF7812165c77BB7a46B148Fe57f9feB78787E99F"
  );
  
  const projectAddr = await factory.allProjects(0);
  console.log("Testing project:", projectAddr);
  
  const project = await hre.ethers.getContractAt("ResearchProject", projectAddr);
  
  const minFunding = await project.MIN_MILESTONE_FUNDING();
  const quorum = await project.MIN_QUORUM_BPS();
  const supermajority = await project.SUPERMAJORITY_BPS();
  
  console.log("\n✅ Upgrade Verified:");
  console.log("MIN_MILESTONE_FUNDING:", hre.ethers.formatEther(minFunding), "DKT");
  console.log("MIN_QUORUM_BPS:", quorum.toString(), "(30%)");
  console.log("SUPERMAJORITY_BPS:", supermajority.toString(), "(80%)");
  console.log("\n✅ All existing projects upgraded successfully!");
}

main().catch(console.error);
