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

        // Create one project for donation tests
        vm.prank(researcher);
        address projectAddr = factory.createProject("Quantum Computing Research", GOAL, DURATION);
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

    /// @notice L1-C: Direct DKT donation to research project
    function test_L1_Donate_ToProject() public {
        vm.prank(alice);
        project.donate(DONATION_AMOUNT);
    }

    /// @notice L1-D: Donate that triggers GoalReached event
    function test_L1_Donate_TriggerGoalReached() public {
        vm.prank(alice);
        project.donate(2000 ether);
        vm.prank(bob);
        project.donate(2000 ether);
        vm.prank(alice);
        project.donate(1000 ether); // crosses threshold
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

    /// @notice L3-C: Finalize project (success path) — DKT routed to FundingPool
    function test_L3_Finalize_ProjectSuccess() public {
        vm.prank(alice);
        project.donate(GOAL);
        project.finalize();
    }

    function test_L3_Finalize_ProjectFailed() public {
        vm.prank(alice);
        project.donate(1000 ether);
        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();
    }

    /// @notice L3-E: Fund yield pool with DKT (ERC-20 transferFrom + SSTORE)
    function test_L3_FundYieldPool() public {
        vm.prank(alice);
        dkt.approve(address(dist), 5000 ether);
        vm.prank(alice);
        dist.fundYieldPool(5000 ether);
    }

    function test_L3_ClaimRefund() public {
        vm.prank(alice);
        project.donate(1000 ether);
        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();
        vm.prank(alice);
        project.claimRefund();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 4 — Contract creation
    // ═══════════════════════════════════════════════════════════════════════════

    function test_L4_CreateProject_ViaFactory() public {
        vm.prank(researcher);
        factory.createProject("New Climate Research Project", 10_000 ether, 60 days);
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
