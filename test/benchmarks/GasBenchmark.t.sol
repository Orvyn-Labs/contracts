// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../../src/tokens/DiktiToken.sol";
import "../../src/StakingVault.sol";
import "../../src/YieldDistributor.sol";
import "../../src/FundingPool.sol";
import "../../src/ResearchProject.sol";
import "../../src/ProjectFactory.sol";

/**
 * @title GasBenchmark
 * @notice Gas measurement tests — all operations use DKT (no ETH).
 *         Run with: forge test --match-contract GasBenchmark --gas-report -vvv
 *
 * @dev Updated for milestone-based ResearchProject:
 *      - createProject() now takes (title, string[], uint256[], uint256[])
 *      - No more finalize() — replaced by submitProof() + vote() + finalizeMilestone()
 *      - claimRefund() now takes milestoneIdx argument
 */
contract GasBenchmark is Test {
    DiktiToken public dkt;
    StakingVault public vault;
    YieldDistributor public dist;
    FundingPool public fundingPool;
    ProjectFactory public factory;
    ResearchProject public project;

    address public admin      = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public alice      = makeAddr("alice");
    address public bob        = makeAddr("bob");

    uint256 constant STAKE_AMOUNT    = 1_000 ether;
    uint256 constant DONATION_AMOUNT = 500 ether;
    uint256 constant GOAL            = 5_000 ether;
    uint256 constant DURATION        = 30 days;
    uint256 constant YIELD_SEED      = 100_000 ether;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _singleMilestoneTitles() internal pure returns (string[] memory t) {
        t = new string[](1);
        t[0] = "Milestone 1";
    }

    function _singleMilestoneGoals() internal pure returns (uint256[] memory g) {
        g = new uint256[](1);
        g[0] = GOAL;
    }

    function _singleMilestoneDurations() internal pure returns (uint256[] memory d) {
        d = new uint256[](1);
        d[0] = DURATION;
    }

    function setUp() public {
        // 1. DiktiToken
        dkt = new DiktiToken(admin);

        // 2. YieldDistributor (UUPS proxy)
        YieldDistributor distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(YieldDistributor.initialize, (admin, 0.1e18, address(dkt)));
        dist = YieldDistributor(address(new ERC1967Proxy(address(distImpl), distInit)));

        // 3. StakingVault (UUPS proxy)
        StakingVault vaultImpl = new StakingVault();
        bytes memory vaultInit = abi.encodeCall(
            StakingVault.initialize, (admin, address(dkt), address(dist), 0)
        );
        vault = StakingVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // 4. FundingPool
        fundingPool = new FundingPool(admin, address(dkt));

        // 5. ProjectFactory
        ResearchProject projectImpl = new ResearchProject();
        factory = new ProjectFactory(admin, address(projectImpl), payable(address(fundingPool)), address(dkt));

        // Wire everything
        vm.startPrank(admin);
        fundingPool.grantRole(fundingPool.DEFAULT_ADMIN_ROLE(), address(factory));
        fundingPool.grantRole(fundingPool.DEPOSITOR_ROLE(), address(dist));
        dist.setStakingVault(address(vault));
        dist.setFundingPool(address(fundingPool));

        // Mint DKT
        dkt.mint(admin,  YIELD_SEED + 1_000_000 ether);
        dkt.mint(alice,  1_000_000 ether);
        dkt.mint(bob,    1_000_000 ether);
        dkt.mint(researcher, 100_000 ether);

        // Fund yield pool with DKT
        dkt.approve(address(dist), YIELD_SEED);
        dist.fundYieldPool(YIELD_SEED);
        vm.stopPrank();

        // Pre-approve for staking
        vm.prank(alice); dkt.approve(address(vault), type(uint256).max);
        vm.prank(bob);   dkt.approve(address(vault), type(uint256).max);

        // Create one project for donation tests (single milestone)
        vm.prank(researcher);
        address projectAddr = factory.createProject(
            "Quantum Computing Research",
            _singleMilestoneTitles(),
            _singleMilestoneGoals(),
            _singleMilestoneDurations()
        );
        project = ResearchProject(payable(projectAddr));

        // Pre-approve project for alice/bob donations
        vm.prank(alice); dkt.approve(address(project), type(uint256).max);
        vm.prank(bob);   dkt.approve(address(project), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 1 — Baseline
    // ═══════════════════════════════════════════════════════════════════════════

    function test_L1_Mint_DiktiToken() public {
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        dkt.mint(recipient, 1000 ether);
    }

    function test_L1_Transfer_DiktiToken() public {
        vm.prank(alice);
        dkt.transfer(bob, 100 ether);
    }

    /// @notice L1-C: Direct DKT donation to research project (current milestone)
    function test_L1_Donate_ToProject() public {
        vm.prank(alice);
        project.donate(DONATION_AMOUNT);
    }

    /// @notice L1-D: Multiple donations to current milestone
    function test_L1_Donate_Multiple() public {
        vm.prank(alice);
        project.donate(2000 ether);
        vm.prank(bob);
        project.donate(2000 ether);
        vm.prank(alice);
        project.donate(1000 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 2 — Medium
    // ═══════════════════════════════════════════════════════════════════════════

    function test_L2_Stake_DKT() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
    }

    function test_L2_Unstake_DKT() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vault.unstake(STAKE_AMOUNT);
    }

    function test_L2_Stake_WithExistingStakers_N10() public {
        for (uint256 i = 0; i < 9; i++) {
            address user = makeAddr(string(abi.encodePacked("staker", i)));
            vm.prank(admin);
            dkt.mint(user, 1000 ether);
            vm.startPrank(user);
            dkt.approve(address(vault), 1000 ether);
            vault.stake(1000 ether, address(0), 0);
            vm.stopPrank();
        }
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
    }

    function test_L2_Approve_DKT() public {
        address spender = makeAddr("spender");
        vm.prank(alice);
        dkt.approve(spender, 1000 ether);
    }

    /// @notice L2-C: Submit milestone proof (after deadline, with donations)
    function test_L2_SubmitProof() public {
        vm.prank(alice);
        project.donate(1000 ether);
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmBenchmarkProof");
    }

    /// @notice L2-D: Vote on a milestone
    function test_L2_Vote_OnMilestone() public {
        vm.prank(alice);
        project.donate(DONATION_AMOUNT);
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");
        vm.prank(alice);
        project.vote(true); // alice is 100% weight → auto-approves
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 3 — High
    // ═══════════════════════════════════════════════════════════════════════════

    function test_L3_ClaimYield() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        dist.claimYield();
    }

    function test_L3_AdvanceEpoch() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(admin);
        dist.advanceEpoch();
    }

    /// @notice L3-C: Full milestone approval — donate → proof → vote → auto-approve
    ///         DKT transferred directly to researcher on approval.
    function test_L3_FinalizeMilestone_Approved() public {
        vm.prank(alice);
        project.donate(GOAL);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        vm.prank(alice);
        project.vote(true); // 100% weight → auto-approve
    }

    /// @notice L3-D: Milestone rejection path — donate → proof → vote NO → auto-reject
    function test_L3_FinalizeMilestone_Rejected() public {
        vm.prank(alice);
        project.donate(1000 ether);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        vm.prank(alice);
        project.vote(false); // 100% weight → auto-reject
    }

    /// @notice L3-E: Fund yield pool with DKT (ERC-20 transferFrom + SSTORE)
    function test_L3_FundYieldPool() public {
        vm.prank(alice);
        dkt.approve(address(dist), 5000 ether);
        vm.prank(alice);
        dist.fundYieldPool(5000 ether);
    }

    /// @notice L3-F: Donor claims refund from rejected milestone
    function test_L3_ClaimRefund() public {
        vm.prank(alice);
        project.donate(1000 ether);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        vm.prank(alice);
        project.vote(false); // auto-reject

        vm.prank(alice);
        project.claimRefund(0); // milestoneIdx = 0
    }

    /// @notice L3-G: Full milestone approval path — DKT transferred directly to researcher on approval
    function test_L3_ApproveMilestone_DirectTransfer() public {
        vm.prank(alice);
        project.donate(GOAL);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        // Vote approves → DKT immediately sent to researcher (no separate withdraw needed)
        vm.prank(alice);
        project.vote(true); // 100% weight → auto-approve → direct transfer
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 4 — Contract creation
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice L4-A: Deploy new project (single milestone) via factory
    function test_L4_CreateProject_SingleMilestone() public {
        vm.prank(researcher);
        factory.createProject(
            "New Climate Research Project",
            _singleMilestoneTitles(),
            _singleMilestoneGoals(),
            _singleMilestoneDurations()
        );
    }

    /// @notice L4-B: Deploy new project with 3 milestones via factory
    function test_L4_CreateProject_ThreeMilestones() public {
        string[] memory titles = new string[](3);
        titles[0] = "Phase 1";
        titles[1] = "Phase 2";
        titles[2] = "Phase 3";

        uint256[] memory goals = new uint256[](3);
        goals[0] = 1_000 ether;
        goals[1] = 2_000 ether;
        goals[2] = 3_000 ether;

        uint256[] memory durs = new uint256[](3);
        durs[0] = 30 days;
        durs[1] = 30 days;
        durs[2] = 30 days;

        vm.prank(researcher);
        factory.createProject("Three-Phase Research", titles, goals, durs);
    }

    function test_L4_Upgrade_StakingVault() public {
        StakingVault newImpl = new StakingVault();
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_L4_Upgrade_Beacon() public {
        ResearchProject newImpl = new ResearchProject();
        vm.prank(admin);
        factory.upgradeBeacon(address(newImpl));
    }

    function test_L4_Deploy_YieldDistributor() public {
        YieldDistributor newImpl = new YieldDistributor();
        bytes memory initData = abi.encodeCall(YieldDistributor.initialize, (admin, 0.05e18, address(dkt)));
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCALING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Scale_Stake_N1() public {
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    function test_Scale_Stake_N50() public {
        _setupStakers(50);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    function test_Scale_Stake_N100() public {
        _setupStakers(100);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    function test_Scale_ClaimYield_N1() public {
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        dist.claimYield();
    }

    function test_Scale_ClaimYield_N100() public {
        _setupStakers(100);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        dist.claimYield();
    }

    /// @notice Scale: multiple donors voting on same milestone
    function test_Scale_Vote_N10Donors() public {
        // Create a fresh project for this test
        vm.prank(researcher);
        address projectAddr = factory.createProject(
            "Scale Vote Project",
            _singleMilestoneTitles(),
            _singleMilestoneGoals(),
            _singleMilestoneDurations()
        );
        ResearchProject p = ResearchProject(payable(projectAddr));

        // 10 donors each donate 100 DKT
        for (uint256 i = 0; i < 10; i++) {
            address donor = makeAddr(string(abi.encodePacked("voter", i)));
            vm.prank(admin);
            dkt.mint(donor, 100 ether);
            vm.startPrank(donor);
            dkt.approve(address(p), 100 ether);
            p.donate(100 ether);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(researcher);
        p.submitProof("ipfs://ScaleProof");

        // 10th vote is the measured one
        address lastDonor = makeAddr(string(abi.encodePacked("voter", uint256(9))));
        vm.prank(lastDonor);
        p.vote(true);
    }

    function _setupStakers(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address user = makeAddr(string(abi.encodePacked("scaleStaker", i)));
            vm.prank(admin);
            dkt.mint(user, 100 ether);
            vm.startPrank(user);
            dkt.approve(address(vault), 100 ether);
            vault.stake(100 ether, address(0), 0);
            vm.stopPrank();
        }
    }
}
