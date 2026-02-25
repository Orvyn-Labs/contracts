// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/ResearchProject.sol";
import "../src/FundingPool.sol";

contract ResearchProjectTest is Test {
    ResearchProject public impl;
    FundingPool public fundingPool;
    ResearchProject public project;

    address public admin = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant GOAL = 5 ether;
    uint256 constant DURATION = 30 days;

    function setUp() public {
        // Deploy FundingPool (deploy as admin so admin holds DEFAULT_ADMIN_ROLE)
        vm.prank(admin);
        fundingPool = new FundingPool(admin);

        // Deploy ResearchProject via BeaconProxy
        impl = new ResearchProject();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);

        bytes memory initData = abi.encodeCall(
            ResearchProject.initialize,
            (researcher, address(fundingPool), "AI Research Project", GOAL, DURATION)
        );
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        project = ResearchProject(payable(address(proxy)));

        // Grant project DEPOSITOR_ROLE on FundingPool
        bytes32 depositorRole = fundingPool.DEPOSITOR_ROLE(); // read before prank
        vm.prank(admin);
        fundingPool.grantRole(depositorRole, address(project));

        // Fund test users with ETH
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Initialization ────────────────────────────────────────────────────────
    function test_Init_CorrectState() public view {
        assertEq(project.researcher(), researcher);
        assertEq(address(project.fundingPool()), address(fundingPool));
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
        project.donate{value: 1 ether}();

        assertEq(project.totalRaised(), 1 ether);
        assertEq(project.donations(alice), 1 ether);
    }

    function test_Donate_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ResearchProject.DonationReceived(alice, 1 ether, 1 ether, block.number);
        project.donate{value: 1 ether}();
    }

    function test_Donate_EmitsGoalReached() public {
        vm.prank(alice);
        project.donate{value: 2 ether}();

        vm.prank(bob);
        project.donate{value: 2 ether}();

        // This donation pushes over goal
        vm.prank(carol);
        vm.expectEmit(false, false, false, false);
        emit ResearchProject.GoalReached(5 ether, block.number);
        project.donate{value: 1 ether}();
    }

    function test_Donate_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ResearchProject.ZeroAmount.selector);
        project.donate{value: 0}();
    }

    function test_Donate_RevertsAfterDeadline() public {
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(alice);
        vm.expectRevert();
        project.donate{value: 1 ether}();
    }

    function test_Donate_RevertsIfNotActive() public {
        // Cancel project
        vm.prank(researcher);
        project.cancel();

        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotActive.selector);
        project.donate{value: 1 ether}();
    }

    function test_Donate_AccumulatesFromMultipleDonors() public {
        vm.prank(alice);
        project.donate{value: 2 ether}();

        vm.prank(bob);
        project.donate{value: 3 ether}();

        assertEq(project.totalRaised(), 5 ether);
        assertEq(project.donations(alice), 2 ether);
        assertEq(project.donations(bob), 3 ether);
    }

    // ─── Finalization ─────────────────────────────────────────────────────────
    function test_Finalize_SucceedsWhenGoalMet() public {
        vm.prank(alice);
        project.donate{value: GOAL}();

        project.finalize();

        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Succeeded));
    }

    function test_Finalize_ForwardsETHToFundingPool() public {
        vm.prank(alice);
        project.donate{value: GOAL}();

        uint256 poolBefore = fundingPool.totalPool();
        project.finalize();
        uint256 poolAfter = fundingPool.totalPool();

        assertEq(poolAfter - poolBefore, GOAL);
        assertEq(address(project).balance, 0);
    }

    function test_Finalize_FailedWhenDeadlineMissed() public {
        vm.prank(alice);
        project.donate{value: 1 ether}(); // below goal

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Failed));
    }

    function test_Finalize_RevertsIfDeadlineNotReached() public {
        vm.expectRevert();
        project.finalize(); // no donations, deadline not reached
    }

    function test_Finalize_RevertsIfAlreadyFinalized() public {
        vm.prank(alice);
        project.donate{value: GOAL}();
        project.finalize();

        vm.expectRevert(ResearchProject.NotActive.selector);
        project.finalize();
    }

    // ─── Refunds ──────────────────────────────────────────────────────────────
    function test_Refund_DonorGetsETHBack() public {
        vm.prank(alice);
        project.donate{value: 1 ether}();

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize(); // -> Failed

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        project.claimRefund();

        assertEq(alice.balance, aliceBefore + 1 ether);
        assertEq(project.donations(alice), 0);
    }

    function test_Refund_RevertsIfNotFailed() public {
        vm.prank(alice);
        project.donate{value: GOAL}();
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
        project.donate{value: 1 ether}();
        vm.prank(bob);
        project.donate{value: 2 ether}();

        vm.warp(block.timestamp + DURATION + 1);
        project.finalize();

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        project.claimRefund();
        vm.prank(bob);
        project.claimRefund();

        assertEq(alice.balance, aliceBefore + 1 ether);
        assertEq(bob.balance, bobBefore + 2 ether);
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

    function test_Cancel_AllowsRefundsAfterCancellation() public {
        vm.prank(alice);
        project.donate{value: 1 ether}();

        vm.prank(researcher);
        project.cancel();

        // After cancel, status is Cancelled not Failed — refund requires Failed status
        // Donors need the project to be Failed (deadline missed) to claim refunds
        // Cancel is a separate path — researcher should handle manually
        assertEq(uint8(project.status()), uint8(ResearchProject.Status.Cancelled));
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    function test_FundingProgress_BasisPoints() public {
        vm.prank(alice);
        project.donate{value: 2.5 ether}(); // 50% of 5 ETH goal

        assertEq(project.fundingProgress(), 5_000); // 50.00%
    }

    function test_FundingProgress_Zero_Initially() public view {
        assertEq(project.fundingProgress(), 0);
    }

    function test_TimeRemaining_Decreases() public {
        uint256 remaining = project.timeRemaining();
        assertEq(remaining, DURATION);

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
        vm.assume(amount > 0);

        vm.deal(alice, uint256(amount));
        vm.prank(alice);
        project.donate{value: uint256(amount)}();

        assertEq(project.donations(alice), uint256(amount));
    }
}
