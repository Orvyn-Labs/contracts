// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/tokens/DiktiToken.sol";
import "../src/FundingPool.sol";
import "../src/ProjectFactory.sol";
import "../src/ResearchProject.sol";

/**
 * @title ForkRealTest
 * @notice Fork test against deployed DChain contracts to diagnose createProject failure.
 */
contract ForkRealTest is Test {
    DiktiToken public dkt;
    FundingPool public pool;
    ProjectFactory public factory;

    address constant DKT_ADDR    = 0xe03fe86f156D0f0bb365aC1f5a4cC2E484AEC1Ea;
    address constant POOL_ADDR   = 0xf769F07598EBB31EAc93FA715b90fFA5170ADc0B;
    address constant FACTORY_ADDR = 0x22fC49730344c09510931C6f2f87cC75ac3db281;

    address public deployer;
    address public researcher = makeAddr("researcher");
    address public donor      = makeAddr("donor");

    function setUp() public {
        string memory rpc = "https://mainnet.dchain.id";
        vm.createSelectFork(rpc);

        dkt     = DiktiToken(DKT_ADDR);
        pool    = FundingPool(POOL_ADDR);
        factory = ProjectFactory(FACTORY_ADDR);

        uint256 pk = 0x8e300b1de89308565770c14123994cb6582559b3406b5dbe318c7d227504fd7f;
        deployer = vm.addr(pk);
    }

    // ─── Diagnosis ────────────────────────────────────────────────────────────

    function test_Diag_FactoryHasAdminRoleOnPool() public view {
        bool hasAdmin = pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), address(factory));
        console.log("Factory has DEFAULT_ADMIN_ROLE on pool:", hasAdmin);
        assertTrue(hasAdmin, "Factory missing DEFAULT_ADMIN_ROLE on FundingPool - createProject will revert!");
    }

    function test_Diag_FactoryHasDepositorRoleOnPool() public view {
        bool hasDepositor = pool.hasRole(pool.DEPOSITOR_ROLE(), address(factory));
        console.log("Factory has DEPOSITOR_ROLE on pool:", hasDepositor);
    }

    function test_Diag_DeployerHasAdminRoleOnPool() public view {
        bool hasAdmin = pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), deployer);
        console.log("Deployer has DEFAULT_ADMIN_ROLE on pool:", hasAdmin);
    }

    function test_Diag_FactoryBeacon() public view {
        address beacon = address(factory.beacon());
        console.log("Factory beacon:", beacon);
        assertTrue(beacon != address(0), "Beacon is zero");
    }

    function test_Diag_FactoryFundingPool() public view {
        address fp = address(factory.fundingPool());
        console.log("Factory fundingPool:", fp);
        assertEq(fp, POOL_ADDR, "FundingPool mismatch");
    }

    function test_Diag_FactoryDkt() public view {
        address d = address(factory.dkt());
        console.log("Factory dkt:", d);
        assertEq(d, DKT_ADDR, "DKT mismatch");
    }

    function test_Diag_CurrentImpl() public view {
        address impl = factory.currentImplementation();
        console.log("Current beacon implementation:", impl);
        assertTrue(impl != address(0), "Impl is zero");
    }

    function test_Diag_ExistingProjectCount() public view {
        uint256 total = factory.totalProjects();
        console.log("Total existing projects:", total);
    }

    // ─── Real createProject ───────────────────────────────────────────────────

    function test_CreateProject_OnFork() public {
        string[] memory titles    = new string[](1);
        uint256[] memory goals    = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        titles[0]    = "Fork Test Project";
        goals[0]     = 1000 ether;
        durations[0] = 30 days;

        vm.prank(deployer);
        address p = factory.createProject("Fork Test", titles, goals, durations);
        console.log("Created project at:", p);
        assertTrue(p != address(0));

        ResearchProject proj = ResearchProject(p);
        assertEq(proj.researcher(), deployer);
        assertEq(proj.milestoneCount(), 1);
        assertTrue(pool.hasRole(pool.DEPOSITOR_ROLE(), p));
    }

    // ─── Full flow: create → donate → proof → vote → finalize ────────────────

    function test_FullFlow_OnFork() public {
        string[] memory titles    = new string[](2);
        uint256[] memory goals    = new uint256[](1);
        uint256[] memory durations = new uint256[](1);

        // Fix: make arrays same length
        goals     = new uint256[](2);
        durations = new uint256[](2);
        titles[0]    = "Phase 1: Research";
        titles[1]    = "Phase 2: Development";
        goals[0]     = 500 ether;
        goals[1]     = 1000 ether;
        durations[0] = 1 days;
        durations[1] = 2 days;

        // --- Step 1: Create project ---
        vm.prank(deployer);
        address p = factory.createProject("Full Flow Test", titles, goals, durations);
        console.log("Step 1 - Created project:", p);
        ResearchProject proj = ResearchProject(p);

        // --- Step 2: Mint & approve DKT for donor ---
        vm.prank(deployer);
        dkt.mint(donor, 10000 ether);

        vm.prank(donor);
        dkt.approve(address(proj), 500 ether);

        // --- Step 3: Donate ---
        vm.prank(donor);
        proj.donate(500 ether);
        console.log("Step 3 - Donated 500 DKT");

        ResearchProject.Milestone memory ms0 = proj.getMilestone(0);
        assertEq(ms0.raised, 500 ether);

        // --- Step 4: Advance time past deadline ---
        vm.warp(block.timestamp + 1 days + 1);
        console.log("Step 4 - Time advanced past deadline");

        // --- Step 5: Researcher submits proof ---
        vm.prank(deployer);
        proj.submitProof("ipfs://QmTestProofHash123");
        console.log("Step 5 - Proof submitted");

        // --- Step 6: Donor votes YES ---
        vm.prank(donor);
        proj.vote(true);
        console.log("Step 6 - Donor voted YES");

        // --- Step 7: Check milestone finalized as Approved ---
        ResearchProject.Milestone memory msFinal = proj.getMilestone(0);
        console.log("Votes YES:", msFinal.votesYes);
        console.log("Votes NO:", msFinal.votesNo);
        assertEq(uint256(msFinal.status), uint256(ResearchProject.MilestoneStatus.Approved));
        console.log("Step 7 - Milestone APPROVED, funds sent to researcher");
    }
}
