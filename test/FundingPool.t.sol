// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FundingPool.sol";
import "../src/tokens/DiktiToken.sol";

/**
 * @title FundingPoolTest
 * @notice Test suite for FundingPool — DKT aggregation, yield routing, allocations.
 *
 *   Covers:
 *     - Constructor validation
 *     - receiveDonation (role-gated, accounting)
 *     - receiveYield (role-gated, accounting)
 *     - receiveYieldForProject (role-gated, project credit)
 *     - allocateToProject (admin role-gated)
 *     - withdrawAllocation (pull-pattern for projects)
 *     - poolMetrics view
 *     - Access control reverts
 */
contract FundingPoolTest is Test {
    DiktiToken public dkt;
    FundingPool public pool;

    address public admin    = makeAddr("admin");
    address public depositor = makeAddr("depositor");
    address public allocator = makeAddr("allocator");
    address public project  = makeAddr("project");
    address public donor    = makeAddr("donor");
    address public stranger = makeAddr("stranger");

    uint256 constant MINT = 100_000 ether;

    function setUp() public {
        dkt  = new DiktiToken(admin);
        pool = new FundingPool(admin, address(dkt));

        // Grant roles
        vm.startPrank(admin);
        pool.grantRole(pool.DEPOSITOR_ROLE(), depositor);
        pool.grantRole(pool.ALLOCATOR_ROLE(), allocator);
        // Mint DKT to depositor and project so they can push tokens
        dkt.mint(depositor, MINT);
        dkt.mint(project,   MINT);
        vm.stopPrank();
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_Constructor_SetsAdmin() public view {
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_SetsAllocatorRole() public view {
        assertTrue(pool.hasRole(pool.ALLOCATOR_ROLE(), admin));
    }

    function test_Constructor_DktAddress() public view {
        assertEq(address(pool.dkt()), address(dkt));
    }

    function test_Constructor_RevertsZeroAdmin() public {
        vm.expectRevert(FundingPool.ZeroAddress.selector);
        new FundingPool(address(0), address(dkt));
    }

    function test_Constructor_RevertsZeroDkt() public {
        vm.expectRevert(FundingPool.ZeroAddress.selector);
        new FundingPool(admin, address(0));
    }

    // ─── receiveDonation ──────────────────────────────────────────────────────

    function test_ReceiveDonation_UpdatesProjectAllocation() public {
        uint256 amount = 500 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        assertEq(pool.projectAllocations(project), amount);
    }

    function test_ReceiveDonation_UpdatesTotalDonations() public {
        uint256 amount = 500 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        assertEq(pool.totalDonations(), amount);
    }

    function test_ReceiveDonation_PullsTokens() public {
        uint256 amount = 500 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        assertEq(dkt.balanceOf(address(pool)), amount);
    }

    function test_ReceiveDonation_EmitsEvent() public {
        uint256 amount = 500 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);

        vm.expectEmit(true, true, false, false);
        emit FundingPool.DonationReceived(project, donor, amount, 0, block.number);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();
    }

    function test_ReceiveDonation_RevertsWithoutRole() public {
        vm.expectRevert();
        vm.prank(stranger);
        pool.receiveDonation(project, donor, 100 ether);
    }

    function test_ReceiveDonation_RevertsZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(FundingPool.ZeroAmount.selector);
        pool.receiveDonation(project, donor, 0);
    }

    function test_ReceiveDonation_RevertsZeroProject() public {
        uint256 amount = 100 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        vm.expectRevert(FundingPool.ZeroAddress.selector);
        pool.receiveDonation(address(0), donor, amount);
        vm.stopPrank();
    }

    // ─── receiveYield ─────────────────────────────────────────────────────────

    function test_ReceiveYield_UpdatesTotalPool() public {
        uint256 amount = 1_000 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveYield(depositor, amount);
        vm.stopPrank();

        assertEq(pool.totalPool(), amount);
    }

    function test_ReceiveYield_UpdatesTotalYieldReceived() public {
        uint256 amount = 1_000 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveYield(depositor, amount);
        vm.stopPrank();

        assertEq(pool.totalYieldDistributed(), amount);
    }

    function test_ReceiveYield_RevertsWithoutRole() public {
        vm.expectRevert();
        vm.prank(stranger);
        pool.receiveYield(stranger, 100 ether);
    }

    function test_ReceiveYield_RevertsZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(FundingPool.ZeroAmount.selector);
        pool.receiveYield(depositor, 0);
    }

    // ─── receiveYieldForProject ───────────────────────────────────────────────

    function test_ReceiveYieldForProject_CreditsProject() public {
        uint256 amount = 200 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveYieldForProject(project, donor, amount);
        vm.stopPrank();

        assertEq(pool.projectAllocations(project), amount);
    }

    function test_ReceiveYieldForProject_UpdatesYieldRouted() public {
        uint256 amount = 200 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveYieldForProject(project, donor, amount);
        vm.stopPrank();

        assertEq(pool.totalYieldDistributed(), amount);
    }

    function test_ReceiveYieldForProject_RevertsWithoutRole() public {
        vm.expectRevert();
        vm.prank(stranger);
        pool.receiveYieldForProject(project, donor, 100 ether);
    }

    function test_ReceiveYieldForProject_RevertsZeroProject() public {
        uint256 amount = 100 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        vm.expectRevert(FundingPool.ZeroAddress.selector);
        pool.receiveYieldForProject(address(0), donor, amount);
        vm.stopPrank();
    }

    // ─── allocateToProject ────────────────────────────────────────────────────

    function test_AllocateToProject_CreditsProject() public {
        // First fund the pool via yield
        uint256 poolFund = 1_000 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), poolFund);
        pool.receiveYield(depositor, poolFund);
        vm.stopPrank();

        uint256 allocAmount = 300 ether;
        vm.prank(allocator);
        pool.allocateToProject(project, allocAmount);

        assertEq(pool.projectAllocations(project), allocAmount);
        assertEq(pool.totalPool(), poolFund - allocAmount);
    }

    function test_AllocateToProject_RevertsWithoutRole() public {
        vm.expectRevert();
        vm.prank(stranger);
        pool.allocateToProject(project, 100 ether);
    }

    function test_AllocateToProject_RevertsInsufficientPool() public {
        vm.prank(allocator);
        vm.expectRevert();
        pool.allocateToProject(project, 100 ether); // pool is empty
    }

    function test_AllocateToProject_RevertsZeroAmount() public {
        vm.prank(allocator);
        vm.expectRevert(FundingPool.ZeroAmount.selector);
        pool.allocateToProject(project, 0);
    }

    // ─── withdrawAllocation ───────────────────────────────────────────────────

    function test_WithdrawAllocation_TransfersTokens() public {
        // Give project an allocation via donation path
        uint256 amount = 400 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        uint256 balBefore = dkt.balanceOf(project);
        vm.prank(project);
        pool.withdrawAllocation(amount);

        assertEq(dkt.balanceOf(project) - balBefore, amount);
        assertEq(pool.projectAllocations(project), 0);
    }

    function test_WithdrawAllocation_EmitsEvent() public {
        uint256 amount = 400 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit FundingPool.AllocationWithdrawn(project, amount, block.number);
        vm.prank(project);
        pool.withdrawAllocation(amount);
    }

    function test_WithdrawAllocation_RevertsInsufficientAllocation() public {
        vm.prank(project);
        vm.expectRevert();
        pool.withdrawAllocation(100 ether); // no allocation
    }

    function test_WithdrawAllocation_RevertsZeroAmount() public {
        vm.prank(project);
        vm.expectRevert(FundingPool.ZeroAmount.selector);
        pool.withdrawAllocation(0);
    }

    // ─── poolMetrics ──────────────────────────────────────────────────────────

    function test_PoolMetrics_ReturnsCorrectValues() public {
        uint256 yieldAmount = 500 ether;
        vm.startPrank(depositor);
        dkt.approve(address(pool), yieldAmount);
        pool.receiveYield(depositor, yieldAmount);
        vm.stopPrank();

        (uint256 poolBal, uint256 donations, uint256 yield, uint256 balance) = pool.poolMetrics();
        assertEq(poolBal,   yieldAmount);
        assertEq(donations, 0);
        assertEq(yield,     yieldAmount);
        assertEq(balance,   dkt.balanceOf(address(pool)));
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_ReceiveDonation_Credits(uint96 amount) public {
        // Bound to avoid exceeding DKT max supply (depositor already has MINT from setUp)
        uint256 maxMint = dkt.remainingSupply();
        vm.assume(amount > 0 && uint256(amount) <= maxMint);
        vm.startPrank(admin);
        dkt.mint(depositor, uint256(amount));
        vm.stopPrank();

        vm.startPrank(depositor);
        dkt.approve(address(pool), amount);
        pool.receiveDonation(project, donor, amount);
        vm.stopPrank();

        assertEq(pool.projectAllocations(project), amount);
        assertEq(pool.totalDonations(), amount);
    }
}
