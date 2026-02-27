// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/ResearchProject.sol";
import "../src/FundingPool.sol";
import "../src/tokens/DiktiToken.sol";

contract ResearchProjectTest is Test {
    DiktiToken public dkt;
    ResearchProject public impl;
    FundingPool public fundingPool;
    ResearchProject public project;

    address public admin    = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");
    address public carol    = makeAddr("carol");

    uint256 constant GOAL     = 5_000 ether; // 5000 DKT
    uint256 constant DURATION = 30 days;
    uint256 constant MINT     = 10_000 ether;

    function setUp() public {
        // Deploy DKT
        dkt = new DiktiToken(admin);

        // Deploy FundingPool
        fundingPool = new FundingPool(admin, address(dkt));

        // Deploy ResearchProject via BeaconProxy
        impl = new ResearchProject();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);

        bytes memory initData = abi.encodeCall(
            ResearchProject.initialize,
            (researcher, address(fundingPool), address(dkt), "AI Research Project", GOAL, DURATION)
        );
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        project = ResearchProject(address(proxy));

        // Grant project DEPOSITOR_ROLE on FundingPool (admin holds DEFAULT_ADMIN_ROLE)
        bytes32 depositorRole = fundingPool.DEPOSITOR_ROLE();
        vm.prank(admin);
        fundingPool.grantRole(depositorRole, address(project));

        // Mint DKT to test users
        vm.startPrank(admin);
        dkt.mint(alice, MINT);
        dkt.mint(bob, MINT);
        dkt.mint(carol, MINT);
        vm.stopPrank();

        // Pre-approve project for users
        vm.prank(alice);  dkt.approve(address(project), type(uint256).max);
        vm.prank(bob);    dkt.approve(address(project), type(uint256).max);
        vm.prank(carol);  dkt.approve(address(project), type(uint256).max);
    }

    // ─── Initialization ───────────────────────────────────────────────────────
    function test_Init_CorrectState() public view {
        assertEq(project.researcher(), researcher);
        assertEq(address(project.fundingPool()), address(fundingPool));
        assertEq(address(project.dkt()), address(dkt));
        assertEq(project.title(), "AI Research Project");
        assertEq(project.goalAmount(), GOAL);
        assertEq(project.totalRaised(), 0);
        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Active));
        assertFalse(project.fundsWithdrawn());
    }

    function test_Init_DeadlineIsCorrect() public view {
        assertEq(project.deadline(), block.timestamp + DURATION);
    }

    function test_Init_ProjectIdIsSet() public view {
        assertNotEq(project.projectId(), bytes32(0));
    }

    // ─── Donating ─────────────────────────────────────────────────────────────
    function test_Donate_AcceptsDonation() public {
        vm.prank(alice);
        project.donate(1000 ether);

        assertEq(project.totalRaised(), 1000 ether);
        assertEq(project.donations(alice), 1000 ether);
        assertEq(dkt.balanceOf(address(project)), 1000 ether);
    }

    function test_Donate_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ResearchProject.DonationReceived(alice, 1000 ether, 1000 ether, block.number);
        project.donate(1000 ether);
    }

    function test_Donate_EmitsGoalReached() public {
        vm.prank(alice);
        project.donate(2000 ether);
        vm.prank(bob);
        project.donate(2000 ether);
        // This donation pushes over goal
        vm.prank(carol);
        vm.expectEmit(false, false, false, false);
        emit ResearchProject.GoalReached(GOAL, block.number);
        project.donate(1000 ether);
    }

    function test_Donate_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ResearchProject.ZeroAmount.selector);
        project.donate(0);
    }

    function test_Donate_RevertsAfterDeadline() public {
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert();
        project.donate(1000 ether);
    }

    function test_Donate_RevertsIfNotActive() public {
        vm.prank(researcher);
        project.cancel();
        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotActive.selector);
        project.donate(1000 ether);
    }

    function test_Donate_AccumulatesFromMultipleDonors() public {
        vm.prank(alice);
        project.donate(2000 ether);
        vm.prank(bob);
        project.donate(3000 ether);

        assertEq(project.totalRaised(), 5000 ether);
        assertEq(project.donations(alice), 2000 ether);
        assertEq(project.donations(bob), 3000 ether);
    }

    // ─── Finalization ─────────────────────────────────────────────────────────
    function test_Finalize_SucceedsWhenGoalMet() public {
        vm.prank(alice);
        project.donate(GOAL);
        project.finalize();
        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Succeeded));
    }

    function test_Finalize_ForwardsDKTToFundingPool() public {
        vm.prank(alice);
        project.donate(GOAL);

        project.finalize();

        // Project should be empty, FundingPool has the tokens
        assertEq(dkt.balanceOf(address(project)), 0);
        assertEq(fundingPool.totalPool(), GOAL);
    }

    function test_Finalize_FailedWhenDeadlineMissed() public {
        vm.prank(alice);
        project.donate(1000 ether);

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Failed));
    }

    function test_Finalize_RevertsIfDeadlineNotReached() public {
        vm.expectRevert();
        project.finalize();
    }

    function test_Finalize_RevertsIfAlreadyFinalized() public {
        vm.prank(alice);
        project.donate(GOAL);
        project.finalize();

        vm.expectRevert(ResearchProject.NotActive.selector);
        project.finalize();
    }

    // ─── Refunds ──────────────────────────────────────────────────────────────
    function test_Refund_DonorGetsDKTBack() public {
        vm.prank(alice);
        project.donate(1000 ether);

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize(); // -> Failed

        uint256 aliceBefore = dkt.balanceOf(alice);
        vm.prank(alice);
        project.claimRefund();

        assertEq(dkt.balanceOf(alice), aliceBefore + 1000 ether);
        assertEq(project.donations(alice), 0);
    }

    function test_Refund_RevertsIfNotFailed() public {
        vm.prank(alice);
        project.donate(GOAL);
        project.finalize(); // -> Succeeded

        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotFailed.selector);
        project.claimRefund();
    }

    function test_Refund_RevertsIfNothingToRefund() public {
        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        vm.prank(alice);
        vm.expectRevert(ResearchProject.NothingToRefund.selector);
        project.claimRefund();
    }

    function test_Refund_MultiDonorAllRefunded() public {
        vm.prank(alice);
        project.donate(1000 ether);
        vm.prank(bob);
        project.donate(2000 ether);

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        uint256 aliceBefore = dkt.balanceOf(alice);
        uint256 bobBefore   = dkt.balanceOf(bob);

        vm.prank(alice);
        project.claimRefund();
        vm.prank(bob);
        project.claimRefund();

        assertEq(dkt.balanceOf(alice), aliceBefore + 1000 ether);
        assertEq(dkt.balanceOf(bob),   bobBefore   + 2000 ether);
    }

    // ─── Cancel ───────────────────────────────────────────────────────────────
    function test_Cancel_ResearcherCanCancel() public {
        vm.prank(researcher);
        project.cancel();
        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Cancelled));
    }

    function test_Cancel_RevertsIfNotResearcher() public {
        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotResearcher.selector);
        project.cancel();
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    function test_FundingProgress_BasisPoints() public {
        vm.prank(alice);
        project.donate(2500 ether); // 50% of 5000 DKT goal
        assertEq(project.fundingProgress(), 5_000);
    }

    function test_FundingProgress_Zero_Initially() public view {
        assertEq(project.fundingProgress(), 0);
    }

    function test_TimeRemaining_Decreases() public {
        assertEq(project.timeRemaining(), DURATION);
        vm.warp(block.timestamp + 10 days);
        assertEq(project.timeRemaining(), DURATION - 10 days);
    }

    function test_TimeRemaining_ZeroAfterDeadline() public {
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(project.timeRemaining(), 0);
    }

    function test_ProjectInfo_ReturnsAllFields() public view {
        (
            address _researcher,
            string memory _title,
            uint256 _goal,
            uint256 _raised,
            uint256 _deadline,
            ResearchProject.Status _status,
            bool _goalMet
        ) = project.projectInfo();

        assertEq(_researcher, researcher);
        assertEq(_title, "AI Research Project");
        assertEq(_goal, GOAL);
        assertEq(_raised, 0);
        assertEq(_deadline, block.timestamp + DURATION);
        assertEq(uint8(_status), uint8(ResearchProject.Status.Active));
        assertFalse(_goalMet);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────
    function testFuzz_Donate_AnyAmount(uint96 amount) public {
        vm.assume(amount > 0 && uint256(amount) <= MINT);
        vm.prank(alice);
        project.donate(uint256(amount));
        assertEq(project.donations(alice), uint256(amount));
    }
}
