// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/ResearchProject.sol";
import "../src/FundingPool.sol";
import "../src/tokens/DiktiToken.sol";

/**
 * @title ResearchProjectTest
 * @notice Full test suite for the milestone-based ResearchProject contract.
 *
 *   Covers:
 *     - Initialization
 *     - Donations (happy path, edge cases, reverts)
 *     - Proof submission
 *     - Voting with auto-finalization
 *     - Force-finalize
 *     - Milestone approval → direct DKT transfer to researcher
 *     - Milestone rejection → donor refunds
 *     - Skip milestone (zero-donation path)
 *     - Multi-milestone sequential flow
 *     - Cancel
 *     - Fuzz tests
 */
contract ResearchProjectTest is Test {
    DiktiToken public dkt;
    FundingPool public fundingPool;
    ResearchProject public project;

    address public admin      = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public alice      = makeAddr("alice");
    address public bob        = makeAddr("bob");
    address public carol      = makeAddr("carol");

    uint256 constant GOAL_1   = 1_000 ether;
    uint256 constant GOAL_2   = 2_000 ether;
    uint256 constant GOAL_3   = 3_000 ether;
    uint256 constant DUR_1    = 30 days;
    uint256 constant DUR_2    = 20 days;
    uint256 constant DUR_3    = 15 days;
    uint256 constant MINT     = 100_000 ether;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Deploy a fresh project with N milestones.
    function _deployProject(
        string[] memory titles,
        uint256[] memory goals,
        uint256[] memory durations
    ) internal returns (ResearchProject p) {
        ResearchProject impl = new ResearchProject();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);

        bytes memory initData = abi.encodeCall(
            ResearchProject.initialize,
            (researcher, address(fundingPool), address(dkt), "Test Project", titles, goals, durations)
        );
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        p = ResearchProject(address(proxy));
    }

    /// Approve project to spend `amount` DKT for `user`.
    function _approve(address user, ResearchProject p, uint256 amount) internal {
        vm.prank(user);
        dkt.approve(address(p), amount);
    }

    function setUp() public {
        // Infrastructure
        dkt         = new DiktiToken(admin);
        fundingPool = new FundingPool(admin, address(dkt));

        // Build 3-milestone project
        string[] memory titles = new string[](3);
        titles[0] = "Milestone A";
        titles[1] = "Milestone B";
        titles[2] = "Milestone C";

        uint256[] memory goals = new uint256[](3);
        goals[0] = GOAL_1;
        goals[1] = GOAL_2;
        goals[2] = GOAL_3;

        uint256[] memory durs = new uint256[](3);
        durs[0] = DUR_1;
        durs[1] = DUR_2;
        durs[2] = DUR_3;

        project = _deployProject(titles, goals, durs);

        // Mint DKT to donors
        vm.startPrank(admin);
        dkt.mint(alice, MINT);
        dkt.mint(bob,   MINT);
        dkt.mint(carol, MINT);
        dkt.mint(researcher, MINT);
        vm.stopPrank();

        // Pre-approve max
        _approve(alice,  project, type(uint256).max);
        _approve(bob,    project, type(uint256).max);
        _approve(carol,  project, type(uint256).max);
    }

    // ─── Initialization ───────────────────────────────────────────────────────

    function test_Init_CorrectState() public view {
        assertEq(project.researcher(), researcher);
        assertEq(address(project.fundingPool()), address(fundingPool));
        assertEq(address(project.dkt()), address(dkt));
        assertEq(project.title(), "Test Project");
        assertEq(project.milestoneCount(), 3);
        assertEq(project.currentMilestoneIndex(), 0);
        assertEq(project.totalRaised(), 0);
        assertEq(uint8(project.projectStatus()), uint8(ResearchProject.ProjectStatus.Active));
    }

    function test_Init_ProjectIdIsSet() public view {
        assertNotEq(project.projectId(), bytes32(0));
    }

    function test_Init_MilestoneDeadlinesCumulative() public view {
        uint256 base = block.timestamp;
        ResearchProject.Milestone memory m0 = project.getMilestone(0);
        ResearchProject.Milestone memory m1 = project.getMilestone(1);
        ResearchProject.Milestone memory m2 = project.getMilestone(2);

        assertEq(m0.deadline, base + DUR_1);
        assertEq(m1.deadline, base + DUR_1 + DUR_2);
        assertEq(m2.deadline, base + DUR_1 + DUR_2 + DUR_3);
    }

    function test_Init_FirstMilestoneIsPending() public view {
        ResearchProject.Milestone memory m0 = project.getMilestone(0);
        assertEq(uint8(m0.status), uint8(ResearchProject.MilestoneStatus.Pending));
        assertEq(m0.raised, 0);
    }

    // ─── Donations ────────────────────────────────────────────────────────────

    function test_Donate_AcceptsDonation() public {
        vm.prank(alice);
        project.donate(500 ether);

        assertEq(project.totalRaised(), 500 ether);
        assertEq(project.donations(0, alice), 500 ether);
        assertEq(dkt.balanceOf(address(project)), 500 ether);
    }

    function test_Donate_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ResearchProject.DonationReceived(alice, 0, 500 ether, 500 ether, block.number);
        project.donate(500 ether);
    }

    function test_Donate_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ResearchProject.ZeroAmount.selector);
        project.donate(0);
    }

    function test_Donate_RevertsAfterDeadline() public {
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(alice);
        vm.expectRevert(ResearchProject.DeadlineAlreadyPassed.selector);
        project.donate(500 ether);
    }

    function test_Donate_RevertsIfProjectCancelled() public {
        vm.prank(researcher);
        project.cancel();

        vm.prank(alice);
        vm.expectRevert(ResearchProject.ProjectNotActive.selector);
        project.donate(500 ether);
    }

    function test_Donate_RevertsIfMilestoneNotPending() public {
        // Donate, let deadline pass, submit proof → Voting state
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://proof");

        // Try to donate again — milestone is now Voting
        vm.prank(bob);
        vm.expectRevert(ResearchProject.NotActive.selector);
        project.donate(100 ether);
    }

    function test_Donate_AccumulatesFromMultipleDonors() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.prank(bob);
        project.donate(400 ether);

        assertEq(project.totalRaised(), 1000 ether);
        assertEq(project.donations(0, alice), 600 ether);
        assertEq(project.donations(0, bob),   400 ether);
    }

    // ─── Submit Proof ─────────────────────────────────────────────────────────

    function test_SubmitProof_MovesToVoting() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        ResearchProject.Milestone memory m = project.getMilestone(0);
        assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Voting));
        assertEq(m.proofUri, "ipfs://QmProof");
    }

    function test_SubmitProof_EmitsEvent() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);

        vm.prank(researcher);
        vm.expectEmit(true, false, false, true);
        emit ResearchProject.ProofSubmitted(0, "ipfs://QmProof", block.number);
        project.submitProof("ipfs://QmProof");
    }

    function test_SubmitProof_RevertsBeforeDeadline() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.prank(researcher);
        vm.expectRevert(ResearchProject.DeadlineNotReached.selector);
        project.submitProof("ipfs://QmProof");
    }

    function test_SubmitProof_RevertsIfNoDonations() public {
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        vm.expectRevert(ResearchProject.ZeroAmount.selector);
        project.submitProof("ipfs://QmProof");
    }

    function test_SubmitProof_RevertsIfNotResearcher() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);

        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotResearcher.selector);
        project.submitProof("ipfs://QmProof");
    }

    function test_SubmitProof_RevertsDoubleSubmit() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);

        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");
        // After first submitProof, milestone is Voting (not Pending) → NotActive on second call
        vm.prank(researcher);
        vm.expectRevert(ResearchProject.NotActive.selector);
        project.submitProof("ipfs://QmProof2");
    }

    // ─── Voting ───────────────────────────────────────────────────────────────

    /// Full happy-path: donate → proof → majority YES → auto-approve
    function test_Vote_AutoApprovesOnMajority() public {
        vm.prank(alice);
        project.donate(600 ether);   // 60% weight
        vm.prank(bob);
        project.donate(400 ether);   // 40% weight

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        // Alice votes YES → 600 / 1000 = 60% > 50% → auto-approve
        vm.prank(alice);
        project.vote(true);

        ResearchProject.Milestone memory m = project.getMilestone(0);
        assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Approved));
    }

    function test_Vote_AutoRejectsOnMajority() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.prank(bob);
        project.donate(400 ether);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://QmProof");

        // Alice votes NO → 600/1000 > 50% → auto-reject
        vm.prank(alice);
        project.vote(false);

        ResearchProject.Milestone memory m = project.getMilestone(0);
        assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Rejected));
    }

    function test_Vote_EmitsVoteEvent() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ResearchProject.MilestoneVoted(alice, 0, true, block.number);
        project.vote(true);
    }

    function test_Vote_RevertsIfNonDonor() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        vm.prank(carol); // carol didn't donate
        vm.expectRevert(ResearchProject.NothingToRefund.selector);
        project.vote(true);
    }

    function test_Vote_RevertsDoubleVote() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        vm.prank(alice);
        project.vote(true); // auto-approves — no double-vote possible after finalization
        // Try to vote again — milestone is now Approved, not Voting
        vm.prank(alice);
        vm.expectRevert(ResearchProject.VotingNotOpen.selector);
        project.vote(true);
    }

    function test_Vote_RevertsIfVotingNotOpen() public {
        vm.prank(alice);
        project.donate(500 ether);
        // Deadline not yet passed → not in Voting state
        vm.prank(alice);
        vm.expectRevert(ResearchProject.VotingNotOpen.selector);
        project.vote(true);
    }

    // ─── Force Finalize ───────────────────────────────────────────────────────

    function test_ForceFinalize_YesWins() public {
        vm.prank(alice);
        project.donate(400 ether); // 40%
        vm.prank(bob);
        project.donate(600 ether); // 60%

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        // Alice YES (400), Bob NO (600) but we want YES to win — swap weights
        // Reset: alice=600, bob=400 in donate but here alice=400, bob=600
        // Bob votes YES → 600 > 500 → auto-approve. Let's use force-finalize with tie.
        // Alice YES=400, Bob NO=600 → Bob has more → forced Rejected
        vm.prank(alice);
        project.vote(true);  // 400 YES, no majority yet

        // Bob hasn't voted — force finalize: votesYes=400, votesNo=0 → Yes wins
        project.finalizeMilestone();

        // Actually: after alice votes YES=400, no majority reached (400 <= 500).
        // Force finalize: 400 yes > 0 no → Approved
        ResearchProject.Milestone memory m = project.getMilestone(0);
        assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Approved));
    }

    function test_ForceFinalize_TieDefaultsRejected() public {
        vm.prank(alice);
        project.donate(500 ether);
        vm.prank(bob);
        project.donate(500 ether);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        // Alice YES=500, Bob NO=500 → tie → anyone force-finalizes → Rejected
        vm.prank(alice);
        project.vote(true);  // 500 yes, no auto (500 == half, not >)
        vm.prank(bob);
        project.vote(false); // 500 no, no auto (500 == half, not >)

        project.finalizeMilestone(); // tie → Rejected
        ResearchProject.Milestone memory m = project.getMilestone(0);
        assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Rejected));
    }

    function test_ForceFinalize_RevertsIfVotingNotOpen() public {
        vm.expectRevert(ResearchProject.VotingNotOpen.selector);
        project.finalizeMilestone();
    }

    // ─── Approval → Direct Transfer to Researcher ────────────────────────────

    function test_Approve_TransfersDktDirectlyToResearcher() public {
        uint256 donation = 800 ether;
        vm.prank(alice);
        project.donate(donation);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        uint256 researcherBefore = dkt.balanceOf(researcher);

        vm.prank(alice);
        project.vote(true); // 800/800 = 100% → auto-approve

        // DKT must be transferred directly to researcher — not to FundingPool
        assertEq(dkt.balanceOf(researcher), researcherBefore + donation);
        assertEq(dkt.balanceOf(address(project)), 0);
        assertEq(fundingPool.projectAllocations(address(project)), 0);
    }

    function test_Approve_ResearcherBalanceIncreasedOnApproval() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        uint256 balBefore = dkt.balanceOf(researcher);
        vm.prank(alice);
        project.vote(true); // auto-approve
        assertEq(dkt.balanceOf(researcher) - balBefore, 500 ether);
    }

    function test_Approve_EmitsMilestoneFinalizedEvent() public {
        uint256 donation = 500 ether;
        vm.prank(alice);
        project.donate(donation);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        vm.expectEmit(true, false, false, true);
        emit ResearchProject.MilestoneFinalized(0, ResearchProject.MilestoneStatus.Approved, donation, block.number);
        vm.prank(alice);
        project.vote(true);
    }

    // ─── Rejection → Refunds ─────────────────────────────────────────────────

    function test_Refund_DonorGetsBackAfterRejection() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.prank(bob);
        project.donate(400 ether);

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");

        // Alice NO → 600/1000 > 50% → auto-reject
        vm.prank(alice);
        project.vote(false);

        uint256 aliceBefore = dkt.balanceOf(alice);
        uint256 bobBefore   = dkt.balanceOf(bob);

        vm.prank(alice);
        project.claimRefund(0);
        vm.prank(bob);
        project.claimRefund(0);

        assertEq(dkt.balanceOf(alice), aliceBefore + 600 ether);
        assertEq(dkt.balanceOf(bob),   bobBefore   + 400 ether);
        assertEq(project.donations(0, alice), 0);
        assertEq(project.donations(0, bob),   0);
    }

    function test_Refund_EmitsEvent() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");
        vm.prank(alice);
        project.vote(false);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ResearchProject.RefundClaimed(alice, 0, 600 ether, block.number);
        project.claimRefund(0);
    }

    function test_Refund_RevertsIfNotRejected() public {
        vm.prank(alice);
        project.donate(500 ether);
        // Milestone still Pending
        vm.prank(alice);
        vm.expectRevert(ResearchProject.MilestoneNotRejected.selector);
        project.claimRefund(0);
    }

    function test_Refund_RevertsIfNothingToRefund() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");
        vm.prank(alice);
        project.vote(false); // auto-reject

        vm.prank(carol); // carol never donated
        vm.expectRevert(ResearchProject.NothingToRefund.selector);
        project.claimRefund(0);
    }

    function test_Refund_DoubleRefundReverts() public {
        vm.prank(alice);
        project.donate(600 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p");
        vm.prank(alice);
        project.vote(false);

        vm.prank(alice);
        project.claimRefund(0);

        vm.prank(alice);
        vm.expectRevert(ResearchProject.NothingToRefund.selector);
        project.claimRefund(0);
    }

    // ─── Skip Milestone ───────────────────────────────────────────────────────

    function test_SkipMilestone_AdvancesIfNoDonations() public {
        vm.warp(block.timestamp + DUR_1 + 1);
        project.skipMilestone();

        assertEq(project.currentMilestoneIndex(), 1);
        ResearchProject.Milestone memory m0 = project.getMilestone(0);
        assertEq(uint8(m0.status), uint8(ResearchProject.MilestoneStatus.Skipped));
    }

    function test_SkipMilestone_EmitsFinalized() public {
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.expectEmit(true, false, false, true);
        emit ResearchProject.MilestoneFinalized(0, ResearchProject.MilestoneStatus.Skipped, 0, block.number);
        project.skipMilestone();
    }

    function test_SkipMilestone_RevertsIfDeadlineNotReached() public {
        vm.expectRevert(ResearchProject.DeadlineNotReached.selector);
        project.skipMilestone();
    }

    function test_SkipMilestone_RevertsIfHasDonations() public {
        vm.prank(alice);
        project.donate(100 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.expectRevert(ResearchProject.ZeroAmount.selector);
        project.skipMilestone();
    }

    // ─── Multi-milestone Sequential Flow ─────────────────────────────────────

    function test_MultiMilestone_FullApprovalFlow() public {
        // === Milestone 0: Approve ===
        vm.prank(alice);
        project.donate(600 ether);
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p0");
        vm.prank(alice);
        project.vote(true); // auto-approve (100%)

        assertEq(project.currentMilestoneIndex(), 1);
        assertEq(uint8(project.projectStatus()), uint8(ResearchProject.ProjectStatus.Active));

        // === Milestone 1: Approve ===
        _approve(alice, project, type(uint256).max);
        vm.prank(alice);
        project.donate(1000 ether);
        vm.warp(block.timestamp + DUR_2 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p1");
        vm.prank(alice);
        project.vote(true); // auto-approve

        assertEq(project.currentMilestoneIndex(), 2);

        // === Milestone 2: Approve → Project Completed ===
        _approve(alice, project, type(uint256).max);
        vm.prank(alice);
        project.donate(1500 ether);
        vm.warp(block.timestamp + DUR_3 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p2");
        vm.prank(alice);
        project.vote(true); // auto-approve

        assertEq(uint8(project.projectStatus()), uint8(ResearchProject.ProjectStatus.Completed));
    }

    function test_MultiMilestone_TotalRaisedAccumulates() public {
        vm.prank(alice);
        project.donate(500 ether);

        // Approve milestone 0
        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://p0");
        vm.prank(alice);
        project.vote(true);

        // Donate to milestone 1
        _approve(alice, project, type(uint256).max);
        vm.prank(alice);
        project.donate(700 ether);

        // totalRaised = 500 + 700 = 1200
        // Note: after milestone 0 approved, DKT sent directly to researcher — but totalRaised sums milestones[i].raised
        assertEq(project.totalRaised(), 1200 ether);
    }

    // ─── Cancel ───────────────────────────────────────────────────────────────

    function test_Cancel_ResearcherCancels() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.prank(researcher);
        project.cancel();

        assertEq(uint8(project.projectStatus()), uint8(ResearchProject.ProjectStatus.Cancelled));
    }

    function test_Cancel_CurrentMilestoneBecomesRejected() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.prank(researcher);
        project.cancel();

        ResearchProject.Milestone memory m0 = project.getMilestone(0);
        assertEq(uint8(m0.status), uint8(ResearchProject.MilestoneStatus.Rejected));
    }

    function test_Cancel_DonorsCanRefundAfterCancel() public {
        vm.prank(alice);
        project.donate(500 ether);

        vm.prank(researcher);
        project.cancel();

        uint256 aliceBefore = dkt.balanceOf(alice);
        vm.prank(alice);
        project.claimRefund(0);

        assertEq(dkt.balanceOf(alice), aliceBefore + 500 ether);
    }

    function test_Cancel_RevertsIfNotResearcher() public {
        vm.prank(alice);
        vm.expectRevert(ResearchProject.NotResearcher.selector);
        project.cancel();
    }

    function test_Cancel_RevertsIfAlreadyCancelled() public {
        vm.prank(researcher);
        project.cancel();

        vm.prank(researcher);
        vm.expectRevert(ResearchProject.ProjectNotActive.selector);
        project.cancel();
    }

    // ─── MilestoneProgress ────────────────────────────────────────────────────

    function test_MilestoneProgress_BasisPoints() public {
        vm.prank(alice);
        project.donate(500 ether); // 50% of GOAL_1=1000
        assertEq(project.milestoneProgress(0), 5_000);
    }

    function test_MilestoneProgress_ZeroInitially() public view {
        assertEq(project.milestoneProgress(0), 0);
    }

    function test_MilestoneProgress_RevertsInvalidIndex() public {
        vm.expectRevert(ResearchProject.InvalidMilestone.selector);
        project.milestoneProgress(99);
    }

    // ─── GetMilestone boundary ────────────────────────────────────────────────

    function test_GetMilestone_RevertsOutOfBounds() public {
        vm.expectRevert(ResearchProject.InvalidMilestone.selector);
        project.getMilestone(3);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_Donate_AnyValidAmount(uint96 amount) public {
        vm.assume(amount > 0 && uint256(amount) <= MINT);
        vm.prank(alice);
        project.donate(uint256(amount));
        assertEq(project.donations(0, alice), uint256(amount));
    }

    function testFuzz_VoteWeight_ProportionalToContribution(uint96 a, uint96 b) public {
        vm.assume(a > 0 && b > 0);
        vm.assume(uint256(a) + uint256(b) <= MINT);

        vm.prank(alice);
        project.donate(uint256(a));
        vm.prank(bob);
        project.donate(uint256(b));

        vm.warp(block.timestamp + DUR_1 + 1);
        vm.prank(researcher);
        project.submitProof("ipfs://fuzz");

        // Both vote YES → should auto-finalize
        uint256 raised = uint256(a) + uint256(b);
        // After alice votes: yes = a, check if > raised/2
        vm.prank(alice);
        project.vote(true);

        ResearchProject.Milestone memory m = project.getMilestone(0);
        if (uint256(a) * 2 > raised) {
            // alice alone was majority
            assertEq(uint8(m.status), uint8(ResearchProject.MilestoneStatus.Approved));
        } else {
            // Still in voting (or bob pushed it over — bob hasn't voted yet)
            // Check still Voting unless a == b and tie is not yet resolved
            assertTrue(
                uint8(m.status) == uint8(ResearchProject.MilestoneStatus.Voting) ||
                uint8(m.status) == uint8(ResearchProject.MilestoneStatus.Approved)
            );
        }
    }
}
