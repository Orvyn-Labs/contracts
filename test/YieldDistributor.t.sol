// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/DiktiToken.sol";
import "../src/YieldDistributor.sol";
import "../src/FundingPool.sol";
import "../src/StakingVault.sol";
import "../src/interfaces/IYieldDistributor.sol";

/**
 * @title YieldDistributorTest
 * @notice Test suite for YieldDistributor — O(1) index-based yield accumulation & distribution.
 *
 *   Covers:
 *     - Initialization validation
 *     - notifyStake / notifyUnstake (StakingVault-only)
 *     - claimYield (happy path, split, zero balance, insufficient pool)
 *     - advanceEpoch (admin-only, timing guard)
 *     - setYieldRate / setStakingVault / setFundingPool (admin-only)
 *     - fundYieldPool / withdrawUnclaimedYield
 *     - Access control reverts
 *     - View functions (pendingYield, yieldSplit, epochInfo)
 */
contract YieldDistributorTest is Test {
    DiktiToken public dkt;
    YieldDistributor public dist;
    StakingVault public vault;
    FundingPool public fundingPool;

    YieldDistributor public distImpl;
    StakingVault public vaultImpl;

    address public admin    = makeAddr("admin");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");
    address public stranger = makeAddr("stranger");
    address public project  = makeAddr("project");

    uint256 constant LOCK_PERIOD  = 7 days;
    uint256 constant INITIAL_RATE = 0.1e18;  // 10% APY
    uint256 constant MINT         = 100_000 ether;
    uint256 constant YIELD_FUND   = 10_000 ether;

    function setUp() public {
        dkt = new DiktiToken(admin);
        fundingPool = new FundingPool(admin, address(dkt));

        // Deploy YieldDistributor via UUPS proxy
        distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(YieldDistributor.initialize, (admin, INITIAL_RATE, address(dkt)));
        ERC1967Proxy distProxy = new ERC1967Proxy(address(distImpl), distInit);
        dist = YieldDistributor(address(distProxy));

        // Deploy StakingVault via UUPS proxy
        vaultImpl = new StakingVault();
        bytes memory vaultInit = abi.encodeCall(
            StakingVault.initialize,
            (admin, address(dkt), address(dist), LOCK_PERIOD)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInit);
        vault = StakingVault(address(vaultProxy));

        // Wire up
        vm.startPrank(admin);
        dist.setStakingVault(address(vault));
        dist.setFundingPool(address(fundingPool));
        fundingPool.grantRole(fundingPool.DEPOSITOR_ROLE(), address(dist));

        // Mint and fund
        dkt.mint(alice, MINT);
        dkt.mint(bob, MINT);
        dkt.mint(admin, YIELD_FUND * 2);
        dkt.approve(address(dist), YIELD_FUND);
        dist.fundYieldPool(YIELD_FUND);
        vm.stopPrank();
    }

    // ─── Initializer ──────────────────────────────────────────────────────────

    function test_Initialize_SetsYieldRate() public view {
        assertEq(dist.yieldRateWAD(), INITIAL_RATE);
    }

    function test_Initialize_SetsRewardIndex() public view {
        assertEq(dist.rewardIndex(), dist.WAD());
    }

    function test_Initialize_SetsCurrentEpochZero() public view {
        assertEq(dist.currentEpoch(), 0);
    }

    function test_Initialize_RevertsZeroAdmin() public {
        YieldDistributor impl2 = new YieldDistributor();
        bytes memory init = abi.encodeCall(YieldDistributor.initialize, (address(0), INITIAL_RATE, address(dkt)));
        vm.expectRevert();
        new ERC1967Proxy(address(impl2), init);
    }

    function test_Initialize_RevertsRateExceedsMax() public {
        YieldDistributor impl2 = new YieldDistributor();
        uint256 overRate = dist.MAX_YIELD_RATE_WAD() + 1;
        bytes memory init = abi.encodeCall(YieldDistributor.initialize, (admin, overRate, address(dkt)));
        vm.expectRevert();
        new ERC1967Proxy(address(impl2), init);
    }

    // ─── fundYieldPool ────────────────────────────────────────────────────────

    function test_FundYieldPool_UpdatesYieldPool() public view {
        assertEq(dist.yieldPool(), YIELD_FUND);
    }

    function test_FundYieldPool_EmitsEvent() public {
        uint256 amount = 500 ether;
        vm.startPrank(admin);
        dkt.approve(address(dist), amount);
        vm.expectEmit(true, false, false, true);
        emit IYieldDistributor.YieldPoolFunded(admin, amount);
        dist.fundYieldPool(amount);
        vm.stopPrank();
    }

    function test_FundYieldPool_RevertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert();
        dist.fundYieldPool(0);
    }

    // ─── notifyStake / notifyUnstake ──────────────────────────────────────────

    function test_NotifyStake_OnlyVaultCanCall() public {
        vm.prank(stranger);
        vm.expectRevert();
        dist.notifyStake(alice, 100 ether, address(0), 0);
    }

    function test_NotifyStake_UpdatesTotalStaked() public {
        uint256 amount = 1_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), amount);
        vault.stake(amount, address(0), 0);
        vm.stopPrank();

        assertEq(dist.totalStaked(), amount);
        assertEq(dist.userStakedBalance(alice), amount);
    }

    function test_NotifyUnstake_UpdatesTotalStaked() public {
        uint256 amount = 1_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), amount);
        vault.stake(amount, address(0), 0);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        vm.prank(alice);
        vault.unstake(amount);

        assertEq(dist.totalStaked(), 0);
        assertEq(dist.userStakedBalance(alice), 0);
    }

    // ─── claimYield ───────────────────────────────────────────────────────────

    function test_ClaimYield_AccruesToStaker() public {
        uint256 stakeAmount = 10_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, address(0), 0);
        vm.stopPrank();

        // Advance time to accrue yield
        vm.warp(block.timestamp + 365 days);

        uint256 pending = dist.pendingYield(alice);
        assertGt(pending, 0);

        uint256 balBefore = dkt.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = dist.claimYield();

        assertEq(claimed, pending);
        assertEq(dkt.balanceOf(alice) - balBefore, claimed);
    }

    function test_ClaimYield_EmitsYieldClaimed() public {
        uint256 stakeAmount = 10_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, address(0), 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit IYieldDistributor.YieldClaimed(alice, 0, 0, 0, address(0), 0, block.number);
        dist.claimYield();
    }

    function test_ClaimYield_WithProjectSplit_SendsPortionToFundingPool() public {
        uint256 stakeAmount = 10_000 ether;

        // Make project address valid in FundingPool (grant DEPOSITOR to dist already done in setUp)
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, project, 5_000); // 50% to project
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 pending = dist.pendingYield(alice);
        assertGt(pending, 0);

        uint256 aliceBefore   = dkt.balanceOf(alice);
        uint256 projectAlloc  = fundingPool.projectAllocations(project);

        vm.prank(alice);
        uint256 claimed = dist.claimYield();

        uint256 toProject = (claimed * 5_000) / 10_000;
        uint256 toStaker  = claimed - toProject;

        assertEq(dkt.balanceOf(alice) - aliceBefore, toStaker);
        assertEq(fundingPool.projectAllocations(project) - projectAlloc, toProject);
    }

    function test_ClaimYield_RevertsNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert();
        dist.claimYield(); // no stake → nothing to claim
    }

    function test_ClaimYield_RevertsInsufficientYieldPool() public {
        // Drain yield pool first by admin withdraw
        vm.startPrank(admin);
        dist.withdrawUnclaimedYield(admin, YIELD_FUND);
        vm.stopPrank();

        uint256 stakeAmount = 10_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, address(0), 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        vm.expectRevert();
        dist.claimYield();
    }

    // ─── advanceEpoch ─────────────────────────────────────────────────────────

    function test_AdvanceEpoch_IncrementsEpoch() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(admin);
        dist.advanceEpoch();

        assertEq(dist.currentEpoch(), 1);
    }

    function test_AdvanceEpoch_StoresEpochInfo() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(admin);
        dist.advanceEpoch();

        IYieldDistributor.EpochInfo memory info = dist.epochInfo(0);
        assertEq(info.yieldRateWAD, INITIAL_RATE);
    }

    function test_AdvanceEpoch_RevertsForNonAdmin() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(stranger);
        vm.expectRevert();
        dist.advanceEpoch();
    }

    function test_AdvanceEpoch_RevertsIfTooEarly() public {
        vm.prank(admin);
        vm.expectRevert(); // < MIN_EPOCH_DURATION
        dist.advanceEpoch();
    }

    // ─── setYieldRate ─────────────────────────────────────────────────────────

    function test_SetYieldRate_UpdatesRate() public {
        uint256 newRate = 0.2e18; // 20%
        vm.prank(admin);
        dist.setYieldRate(newRate);
        assertEq(dist.yieldRateWAD(), newRate);
    }

    function test_SetYieldRate_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        dist.setYieldRate(0.2e18);
    }

    function test_SetYieldRate_RevertsExceedsMax() public {
        uint256 tooHigh = dist.MAX_YIELD_RATE_WAD() + 1;
        vm.prank(admin);
        vm.expectRevert();
        dist.setYieldRate(tooHigh);
    }

    // ─── setStakingVault / setFundingPool ─────────────────────────────────────

    function test_SetStakingVault_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        dist.setStakingVault(address(vault));
    }

    function test_SetStakingVault_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        dist.setStakingVault(address(0));
    }

    function test_SetFundingPool_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        dist.setFundingPool(address(fundingPool));
    }

    function test_SetFundingPool_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        dist.setFundingPool(address(0));
    }

    // ─── withdrawUnclaimedYield ───────────────────────────────────────────────

    function test_WithdrawUnclaimedYield_AdminCanWithdraw() public {
        uint256 balBefore = dkt.balanceOf(admin);
        vm.prank(admin);
        dist.withdrawUnclaimedYield(admin, YIELD_FUND);

        assertEq(dkt.balanceOf(admin) - balBefore, YIELD_FUND);
        assertEq(dist.yieldPool(), 0);
    }

    function test_WithdrawUnclaimedYield_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        dist.withdrawUnclaimedYield(stranger, 100 ether);
    }

    function test_WithdrawUnclaimedYield_RevertsInsufficientPool() public {
        vm.prank(admin);
        vm.expectRevert();
        dist.withdrawUnclaimedYield(admin, YIELD_FUND + 1 ether);
    }

    // ─── pendingYield view ────────────────────────────────────────────────────

    function test_PendingYield_ZeroForNoStake() public view {
        assertEq(dist.pendingYield(alice), 0);
    }

    function test_PendingYield_AccruessAfterStake() public {
        uint256 stakeAmount = 10_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, address(0), 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        assertGt(dist.pendingYield(alice), 0);
    }

    // ─── yieldSplit view ──────────────────────────────────────────────────────

    function test_YieldSplit_SetOnStake() public {
        uint256 stakeAmount = 1_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, project, 3_000); // 30% to project
        vm.stopPrank();

        IYieldDistributor.YieldSplit memory split = dist.yieldSplit(alice);
        assertEq(split.targetProject, project);
        assertEq(split.donateBps, 3_000);
    }

    function test_YieldSplit_ClearedOnFullUnstake() public {
        uint256 stakeAmount = 1_000 ether;
        vm.startPrank(alice);
        dkt.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount, project, 3_000);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        vm.prank(alice);
        vault.unstake(stakeAmount);

        IYieldDistributor.YieldSplit memory split = dist.yieldSplit(alice);
        assertEq(split.donateBps, 0);
        assertEq(split.targetProject, address(0));
    }
}
