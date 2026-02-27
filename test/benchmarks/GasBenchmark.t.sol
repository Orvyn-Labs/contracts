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
 * @notice Explicit gas measurement tests for every transaction complexity level.
 *         Run with: forge test --match-contract GasBenchmark --gas-report -vvv
 *         Snapshot: forge snapshot --match-contract GasBenchmark
 *
 * Each test function maps to one row in the academic thesis gas comparison table.
 *
 * Complexity levels:
 *   L1 — Simple value transfer / storage write (donate, mint)
 *   L2 — Multi-SSTORE + ERC-20 (stake, unstake)
 *   L3 — Computation + cross-contract (claimYield, finalize)
 *   L4 — Contract creation (createProject, upgrade)
 */
contract GasBenchmark is Test {
    // ─── Contracts ────────────────────────────────────────────────────────────
    DiktiToken public dkt;
    StakingVault public vault;
    YieldDistributor public dist;
    FundingPool public fundingPool;
    ProjectFactory public factory;
    ResearchProject public project;

    address public admin = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant DONATION_AMOUNT = 0.5 ether;
    uint256 constant GOAL = 5 ether;
    uint256 constant DURATION = 30 days;

    function setUp() public {
        // 1. DiktiToken
        dkt = new DiktiToken(admin);

        // 2. YieldDistributor (UUPS proxy)
        YieldDistributor distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(YieldDistributor.initialize, (admin, 0.1e18));
        dist = YieldDistributor(payable(address(new ERC1967Proxy(address(distImpl), distInit))));

        // 3. StakingVault (UUPS proxy)
        StakingVault vaultImpl = new StakingVault();
        bytes memory vaultInit = abi.encodeCall(
            StakingVault.initialize, (admin, address(dkt), address(dist), 0)
        );
        vault = StakingVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // 4. FundingPool
        fundingPool = new FundingPool(admin);

        // 5. ProjectFactory (with beacon)
        ResearchProject projectImpl = new ResearchProject();
        factory = new ProjectFactory(admin, address(projectImpl), payable(address(fundingPool)));

        // Grant DEPOSITOR_ROLE to factory (it grants to each project)
        vm.startPrank(admin);
        fundingPool.grantRole(fundingPool.DEFAULT_ADMIN_ROLE(), address(factory));
        dist.setStakingVault(address(vault));
        dkt.mint(alice, 100_000 ether);
        dkt.mint(bob, 100_000 ether);
        vm.stopPrank();

        // Fund yield pool
        vm.deal(admin, 100 ether);
        vm.prank(admin);
        dist.fundYieldPool{value: 100 ether}();

        // Pre-approve DKT for staking
        vm.prank(alice);
        dkt.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        dkt.approve(address(vault), type(uint256).max);

        // Create one project for donation tests
        vm.deal(researcher, 10 ether);
        vm.prank(researcher);
        address projectAddr = factory.createProject("Quantum Computing Research", GOAL, DURATION);
        project = ResearchProject(payable(projectAddr));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 1 — Baseline (simple storage writes)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice L1-A: ERC-20 mint (zero→nonzero SSTORE)
     *         Baseline: cheapest meaningful transaction.
     */
    function test_L1_Mint_DiktiToken() public {
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        dkt.mint(recipient, 1000 ether);
    }

    /**
     * @notice L1-B: ERC-20 transfer (nonzero→nonzero SSTORE x2)
     */
    function test_L1_Transfer_DiktiToken() public {
        vm.prank(alice);
        dkt.transfer(bob, 100 ether);
    }

    /**
     * @notice L1-C: Direct ETH donation to research project
     *         Core crowdfunding operation — primary funding stream.
     */
    function test_L1_Donate_ToProject() public {
        vm.prank(alice);
        project.donate{value: DONATION_AMOUNT}();
    }

    /**
     * @notice L1-D: Donate that triggers GoalReached event
     *         Tests the conditional branch inside donate().
     */
    function test_L1_Donate_TriggerGoalReached() public {
        vm.prank(alice);
        project.donate{value: 2 ether}();
        vm.prank(bob);
        project.donate{value: 2 ether}();
        // This one crosses the threshold
        vm.prank(alice);
        project.donate{value: 1 ether}();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 2 — Medium (ERC-20 + multi-SSTORE + external call)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice L2-A: Stake DKT tokens
     *         ERC-20 transferFrom + 3 SSTOREs + external call to YieldDistributor
     */
    function test_L2_Stake_DKT() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
    }

    /**
     * @notice L2-B: Unstake DKT tokens
     *         2 SSTOREs + external call to YieldDistributor + ERC-20 transfer
     */
    function test_L2_Unstake_DKT() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);

        vm.warp(block.timestamp + 1); // lock period = 0 in tests
        vm.prank(alice);
        vault.unstake(STAKE_AMOUNT);
    }

    /**
     * @notice L2-C: Stake with multiple existing stakers
     *         Demonstrates how totalStaked scale affects gas (it shouldn't — O(1)).
     */
    function test_L2_Stake_WithExistingStakers_N10() public {
        // Pre-populate 9 other stakers
        for (uint256 i = 0; i < 9; i++) {
            address user = makeAddr(string(abi.encodePacked("staker", i)));
            vm.prank(admin);
            dkt.mint(user, 1000 ether);
            vm.startPrank(user);
            dkt.approve(address(vault), 1000 ether);
            vault.stake(1000 ether, address(0), 0);
            vm.stopPrank();
        }

        // Measure: alice stakes with 9 existing stakers
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);
    }

    /**
     * @notice L2-D: ERC-20 approve (separate operation, often forgotten in benchmarks)
     */
    function test_L2_Approve_DKT() public {
        address spender = makeAddr("spender");
        vm.prank(alice);
        dkt.approve(spender, 1000 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 3 — High (computation + cross-contract state changes)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice L3-A: Claim simulated yield
     *         Reward index math + ETH transfer = computation-heavy.
     */
    function test_L3_ClaimYield() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);

        // Advance 30 days so yield accrues
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        dist.claimYield();
    }

    /**
     * @notice L3-B: Advance epoch
     *         Epoch snapshot + index accrual + event emission.
     */
    function test_L3_AdvanceEpoch() public {
        vm.prank(alice);
        vault.stake(STAKE_AMOUNT, address(0), 0);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(admin);
        dist.advanceEpoch();
    }

    /**
     * @notice L3-C: Finalize project (success path)
     *         Status change + ETH routing to FundingPool (cross-contract).
     */
    function test_L3_Finalize_ProjectSuccess() public {
        vm.prank(alice);
        project.donate{value: GOAL}();

        project.finalize();
    }

    /**
     * @notice L3-D: Finalize project (failure path — deadline missed)
     */
    function test_L3_Finalize_ProjectFailed() public {
        vm.prank(alice);
        project.donate{value: 1 ether}(); // below goal

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();
    }

    /**
     * @notice L3-E: Fund yield pool (ETH deposit into distributor)
     */
    function test_L3_FundYieldPool() public {
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        dist.fundYieldPool{value: 1 ether}();
    }

    /**
     * @notice L3-F: Claim refund after project failure
     */
    function test_L3_ClaimRefund() public {
        vm.prank(alice);
        project.donate{value: 1 ether}();

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        vm.prank(alice);
        project.claimRefund();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEXITY LEVEL 4 — Highest (contract creation / proxy operations)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice L4-A: Deploy a new ResearchProject via factory (BeaconProxy creation)
     *         Most expensive single user operation.
     */
    function test_L4_CreateProject_ViaFactory() public {
        vm.prank(researcher);
        factory.createProject("New Climate Research Project", 10 ether, 60 days);
    }

    /**
     * @notice L4-B: Upgrade UUPS proxy implementation (StakingVault)
     *         Demonstrates proxy upgrade cost for academic comparison.
     */
    function test_L4_Upgrade_StakingVault() public {
        StakingVault newImpl = new StakingVault();
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImpl), "");
    }

    /**
     * @notice L4-C: Upgrade beacon (affects ALL ResearchProject instances)
     *         Single transaction that upgrades all deployed projects.
     */
    function test_L4_Upgrade_Beacon() public {
        ResearchProject newImpl = new ResearchProject();
        vm.prank(admin);
        factory.upgradeBeacon(address(newImpl));
    }

    /**
     * @notice L4-D: Deploy YieldDistributor (fresh contract creation baseline)
     */
    function test_L4_Deploy_YieldDistributor() public {
        YieldDistributor newImpl = new YieldDistributor();
        bytes memory initData = abi.encodeCall(YieldDistributor.initialize, (admin, 0.05e18));
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCALING TESTS — measures O(1) behavior vs O(n) anti-patterns
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Scale-1: Stake with N=1 staker → baseline
     */
    function test_Scale_Stake_N1() public {
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    /**
     * @notice Scale-50: Stake with N=50 existing stakers
     *         Should cost approximately the same gas as N=1 (O(1) design).
     */
    function test_Scale_Stake_N50() public {
        _setupStakers(50);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    /**
     * @notice Scale-100: Stake with N=100 existing stakers
     *         Final proof of O(1) scaling — gas should not grow with staker count.
     */
    function test_Scale_Stake_N100() public {
        _setupStakers(100);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
    }

    /**
     * @notice Scale-ClaimYield with N=1 staker
     */
    function test_Scale_ClaimYield_N1() public {
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        dist.claimYield();
    }

    /**
     * @notice Scale-ClaimYield with N=100 stakers
     *         Should cost the same as N=1 (global index, no iteration).
     */
    function test_Scale_ClaimYield_N100() public {
        _setupStakers(100);
        vm.prank(alice);
        vault.stake(100 ether, address(0), 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        dist.claimYield();
    }

    // ─── Helper ──────────────────────────────────────────────────────────────
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
