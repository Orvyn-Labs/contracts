import hre from "hardhat";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║     ResearchProject Security v2.0 Upgrade Script         ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("Network:", hre.network.name);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "DCoin\n");

  const factoryAddr = "0xDF7812165c77BB7a46B148Fe57f9feB78787E99F";
  const opts = { gasLimit: 3000000, type: 0 };

  const factory = new hre.ethers.Contract(
    factoryAddr,
    [
      "function beacon() view returns (address)",
      "function currentImplementation() view returns (address)",
      "function upgradeBeacon(address newImpl)",
      "function totalProjects() view returns (uint256)",
    ],
    deployer
  );

  const oldImpl = await factory.currentImplementation();
  const totalProjects = await factory.totalProjects();

  console.log("Current Implementation:", oldImpl);
  console.log("Total Existing Projects:", totalProjects.toString());
  console.log("All projects will be upgraded to v2.0\n");

  // 1. Deploy new ResearchProject v2.0 implementation
  console.log("═══════════════════════════════════════════════════════════");
  console.log("STEP 1: Deploying ResearchProject v2.0 Implementation");
  console.log("═══════════════════════════════════════════════════════════");

  const ResearchProject = await hre.ethers.getContractFactory("ResearchProject");
  const newImpl = await ResearchProject.deploy(opts);
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();

  console.log("✅ New Implementation:", newImplAddr);
  console.log("");

  // 2. Verify new constants exist
  console.log("═══════════════════════════════════════════════════════════");
  console.log("STEP 2: Verifying Security Constants");
  console.log("═══════════════════════════════════════════════════════════");

  try {
    const MIN_MILESTONE_FUNDING = await newImpl.MIN_MILESTONE_FUNDING();
    const MIN_QUORUM_BPS = await newImpl.MIN_QUORUM_BPS();
    const SUPERMAJORITY_BPS = await newImpl.SUPERMAJORITY_BPS();
    const REFUND_DEADLINE = await newImpl.REFUND_DEADLINE();
    const RESEARCHER_TRANSFER_DELAY = await newImpl.RESEARCHER_TRANSFER_DELAY();
    const VOTE_PERIOD = await newImpl.VOTE_PERIOD();

    console.log("MIN_MILESTONE_FUNDING:      ", hre.ethers.formatEther(MIN_MILESTONE_FUNDING), "DKT");
    console.log("MIN_QUORUM_BPS:             ", MIN_QUORUM_BPS.toString(), "(30%)");
    console.log("SUPERMAJORITY_BPS:          ", SUPERMAJORITY_BPS.toString(), "(80%)");
    console.log("REFUND_DEADLINE:            ", (Number(REFUND_DEADLINE) / 86400).toString(), "days");
    console.log("RESEARCHER_TRANSFER_DELAY:  ", (Number(RESEARCHER_TRANSFER_DELAY) / 86400).toString(), "days");
    console.log("VOTE_PERIOD:                ", (Number(VOTE_PERIOD) / 86400).toString(), "days");
    console.log("✅ All security constants verified!\n");
  } catch (err) {
    console.error("❌ ERROR: Failed to read security constants");
    console.error(err.message);
    process.exit(1);
  }

  // 3. Upgrade the beacon
  console.log("═══════════════════════════════════════════════════════════");
  console.log("STEP 3: Upgrading Beacon");
  console.log("═══════════════════════════════════════════════════════════");
  console.log("Upgrading beacon to new implementation...");

  const tx = await factory.upgradeBeacon(newImplAddr, { gasLimit: 500000 });
  console.log("Transaction hash:", tx.hash);
  await tx.wait();
  console.log("✅ Beacon upgraded successfully!\n");

  // 4. Verify upgrade
  console.log("═══════════════════════════════════════════════════════════");
  console.log("STEP 4: Verifying Upgrade");
  console.log("═══════════════════════════════════════════════════════════");

  const currentImpl = await factory.currentImplementation();
  console.log("Current Implementation:", currentImpl);

  if (currentImpl.toLowerCase() === newImplAddr.toLowerCase()) {
    console.log("✅ Upgrade verified successfully!");
  } else {
    console.log("❌ ERROR: Implementation mismatch!");
    console.log("Expected:", newImplAddr);
    console.log("Got:", currentImpl);
    process.exit(1);
  }

  // 5. Summary
  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║              UPGRADE COMPLETED SUCCESSFULLY              ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  console.log("📊 SUMMARY:");
  console.log("─────────────────────────────────────────────────────────────");
  console.log("Old Implementation:     ", oldImpl);
  console.log("New Implementation:     ", newImplAddr);
  console.log("Total Projects Upgraded:", totalProjects.toString());
  console.log("");

  console.log("🔒 SECURITY FEATURES ENABLED:");
  console.log("─────────────────────────────────────────────────────────────");
  console.log("✅ Self-funding attack prevention (100 DKT minimum)");
  console.log("✅ Low-turnout approval prevention (30% quorum)");
  console.log("✅ Cancel griefing prevention (blocked during voting)");
  console.log("✅ Early finalization (80% supermajority)");
  console.log("✅ Refund deadline enforcement (1 year)");
  console.log("✅ Researcher transfer mechanism (7-day timelock)");
  console.log("✅ Unique donor tracking");
  console.log("");

  console.log("📝 NEW FUNCTIONS AVAILABLE:");
  console.log("─────────────────────────────────────────────────────────────");
  console.log("• initiateResearcherTransfer(address)");
  console.log("• acceptResearcherTransfer()");
  console.log("• cancelResearcherTransfer()");
  console.log("");

  console.log("⚠️  BACKWARD COMPATIBILITY:");
  console.log("─────────────────────────────────────────────────────────────");
  console.log("• Old projects with refundDeadline=0 can still claim refunds");
  console.log("• Existing approved milestones remain valid");
  console.log("• New security rules apply to all future milestone submissions");
  console.log("");

  console.log("🚀 NEXT STEPS:");
  console.log("─────────────────────────────────────────────────────────────");
  console.log("1. Update frontend .env.local (addresses unchanged)");
  console.log("2. Test on existing project contracts");
  console.log("3. Create new project to test security features");
  console.log("4. Document upgrade in CHANGELOG.md");
  console.log("");

  console.log("═══════════════════════════════════════════════════════════");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("\n❌ UPGRADE FAILED:");
    console.error(e.message);
    process.exit(1);
  });
