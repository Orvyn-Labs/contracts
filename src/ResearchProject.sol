// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./FundingPool.sol";

/**
 * @title ResearchProject
 * @notice Milestone-based research crowdfunding contract.
 *
 *   Flow:
 *     1. Researcher creates project with N sequential milestones (each has a goal + deadline).
 *     2. Donors contribute DKT to the ACTIVE milestone. Donations are tracked per donor.
 *     3. When a milestone's deadline passes:
 *        - Researcher submits proof (off-chain IPFS hash stored on-chain).
 *        - Donors vote to approve or reject the milestone.
     *        - If majority approves  → milestone Approved: all DKT transferred DIRECTLY to
     *                                  researcher wallet immediately. Next milestone becomes active.
 *        - If majority rejects  → milestone Rejected: all donors can claimRefund for that milestone.
 *     4. If deadline passes with NO donations → milestone auto-fails (no vote needed).
 *     5. Funds go directly to researcher on approval — no separate withdraw step required.
 *
 * @dev COMPLEXITY LEVEL 1-2 (donate/vote) + COMPLEXITY LEVEL 3 (milestone finalization).
 *      All amounts are in DKT (18 decimals).
 *      Upgradeability: Beacon Proxy.
 */
contract ResearchProject is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Enums ────────────────────────────────────────────────────────────────
    enum ProjectStatus { Active, Completed, Cancelled }

    enum MilestoneStatus {
        Pending,   // accepting donations, deadline not yet passed
        Voting,    // deadline passed, awaiting donor vote on researcher proof
        Approved,  // majority voted yes → funds released to researcher
        Rejected,  // majority voted no  → donors can claim refund
        Skipped    // no donations were made, milestone auto-skipped
    }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Milestone {
        string  title;
        uint256 goal;       // DKT target for this milestone (informational — partial OK)
        uint256 deadline;   // Unix timestamp
        uint256 raised;     // total DKT donated to this milestone
        uint256 votesYes;
        uint256 votesNo;
        string  proofUri;   // IPFS/URI submitted by researcher as completion proof
        MilestoneStatus status;
    }

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotResearcher();
    error NotActive();
    error ZeroAmount();
    error ZeroAddress();
    error NothingToRefund();
    error AlreadyVoted();
    error VotingNotOpen();
    error DeadlineNotReached();
    error DeadlineAlreadyPassed();
    error ProofAlreadySubmitted();
    error NoProofSubmitted();
    error MilestoneNotRejected();
    error InvalidMilestone();
    error AllMilestonesComplete();
    error ProjectNotActive();

    // ─── Events ───────────────────────────────────────────────────────────────
    event DonationReceived(address indexed donor, uint256 milestoneIndex, uint256 amount, uint256 milestoneRaised, uint256 blockNumber);
    event ProofSubmitted(uint256 indexed milestoneIndex, string proofUri, uint256 blockNumber);
    event MilestoneVoted(address indexed donor, uint256 indexed milestoneIndex, bool approved, uint256 blockNumber);
    event MilestoneFinalized(uint256 indexed milestoneIndex, MilestoneStatus result, uint256 raised, uint256 blockNumber);
    event FundsWithdrawn(address indexed researcher, uint256 milestoneIndex, uint256 amount, uint256 blockNumber);
    event RefundClaimed(address indexed donor, uint256 indexed milestoneIndex, uint256 amount, uint256 blockNumber);
    event ProjectCancelled(uint256 blockNumber);
    event MilestoneActivated(uint256 indexed milestoneIndex, uint256 blockNumber);

    // ─── State ────────────────────────────────────────────────────────────────
    address public researcher;
    FundingPool public fundingPool;
    IERC20 public dkt;
    bytes32 public projectId;
    string public title;
    ProjectStatus public projectStatus;

    Milestone[] public milestones;
    uint256 public currentMilestoneIndex;

    // donations[milestoneIndex][donor] = amount
    mapping(uint256 => mapping(address => uint256)) public donations;
    // voted[milestoneIndex][donor] = true if already voted
    mapping(uint256 => mapping(address => bool)) public voted;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ─── Initializer ─────────────────────────────────────────────────────────
    /**
     * @param _researcher  Researcher wallet address
     * @param _fundingPool FundingPool contract
     * @param _dkt         DKT token address
     * @param _title       Project title
     * @param _milestoneTitle   Array of milestone titles
     * @param _milestoneGoal    Array of milestone DKT goals (informational — partial OK)
     * @param _milestoneDuration Array of milestone durations in seconds
     */
    function initialize(
        address _researcher,
        address _fundingPool,
        address _dkt,
        string calldata _title,
        string[] calldata _milestoneTitle,
        uint256[] calldata _milestoneGoal,
        uint256[] calldata _milestoneDuration
    ) external initializer {
        if (_researcher == address(0)) revert ZeroAddress();
        if (_fundingPool == address(0)) revert ZeroAddress();
        if (_dkt == address(0)) revert ZeroAddress();
        require(_milestoneTitle.length > 0, "Need at least one milestone");
        require(
            _milestoneTitle.length == _milestoneGoal.length &&
            _milestoneGoal.length == _milestoneDuration.length,
            "Milestone array length mismatch"
        );

        researcher  = _researcher;
        fundingPool = FundingPool(payable(_fundingPool));
        dkt         = IERC20(_dkt);
        title       = _title;
        projectStatus = ProjectStatus.Active;
        projectId   = keccak256(abi.encodePacked(_researcher, _title, block.timestamp));

        // Build milestone array — only the first one is Pending (active), rest start Pending too
        // but donations are only accepted for currentMilestoneIndex
        uint256 runningDeadline = block.timestamp;
        for (uint256 i = 0; i < _milestoneTitle.length; i++) {
            require(_milestoneDuration[i] >= 1 hours, "Duration too short");
            runningDeadline += _milestoneDuration[i];
            milestones.push(Milestone({
                title:    _milestoneTitle[i],
                goal:     _milestoneGoal[i],
                deadline: runningDeadline,
                raised:   0,
                votesYes: 0,
                votesNo:  0,
                proofUri: "",
                status:   MilestoneStatus.Pending
            }));
        }

        currentMilestoneIndex = 0;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyResearcher() {
        if (msg.sender != researcher) revert NotResearcher();
        _;
    }
    modifier onlyProjectActive() {
        if (projectStatus != ProjectStatus.Active) revert ProjectNotActive();
        _;
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    function getMilestone(uint256 idx) external view returns (Milestone memory) {
        if (idx >= milestones.length) revert InvalidMilestone();
        return milestones[idx];
    }

    function currentMilestone() external view returns (Milestone memory) {
        return milestones[currentMilestoneIndex];
    }

    function totalRaised() external view returns (uint256 total) {
        for (uint256 i = 0; i < milestones.length; i++) {
            total += milestones[i].raised;
        }
    }

    // Returns basis points (0-10000) progress toward this milestone's goal
    function milestoneProgress(uint256 idx) external view returns (uint256 bps) {
        if (idx >= milestones.length) revert InvalidMilestone();
        uint256 goal = milestones[idx].goal;
        if (goal == 0) return 10_000;
        return (milestones[idx].raised * 10_000) / goal;
    }

    function myDonation(uint256 milestoneIdx, address donor) external view returns (uint256) {
        return donations[milestoneIdx][donor];
    }

    // ─── Core: Donate ─────────────────────────────────────────────────────────
    /**
     * @notice Donate DKT to the current active milestone.
     * @dev    Caller must approve this contract for `amount` DKT first.
     *         Donations are accepted regardless of whether the goal has been met —
     *         any amount is valid. The researcher may withdraw whatever is raised
     *         if donors approve the milestone.
     */
    function donate(uint256 amount) external onlyProjectActive nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Milestone storage ms = milestones[currentMilestoneIndex];
        if (ms.status != MilestoneStatus.Pending) revert NotActive();
        if (block.timestamp > ms.deadline) revert DeadlineAlreadyPassed();

        dkt.safeTransferFrom(msg.sender, address(this), amount);
        donations[currentMilestoneIndex][msg.sender] += amount;
        ms.raised += amount;

        emit DonationReceived(msg.sender, currentMilestoneIndex, amount, ms.raised, block.number);
    }

    // ─── Core: Submit Proof ───────────────────────────────────────────────────
    /**
     * @notice Researcher submits an IPFS URI as proof of milestone completion.
     *         This moves the milestone into Voting state, enabling donor votes.
     * @dev    Can only be called after the milestone deadline has passed.
     */
    function submitProof(string calldata proofUri) external onlyResearcher onlyProjectActive {
        Milestone storage ms = milestones[currentMilestoneIndex];
        if (ms.status != MilestoneStatus.Pending) revert NotActive();
        if (block.timestamp <= ms.deadline) revert DeadlineNotReached();
        if (ms.raised == 0) revert ZeroAmount(); // no donations — use skipMilestone
        if (bytes(ms.proofUri).length > 0) revert ProofAlreadySubmitted();

        ms.proofUri = proofUri;
        ms.status   = MilestoneStatus.Voting;

        emit ProofSubmitted(currentMilestoneIndex, proofUri, block.number);
    }

    // ─── Core: Vote ───────────────────────────────────────────────────────────
    /**
     * @notice Donor votes to approve or reject the researcher's milestone proof.
     * @dev    Only donors who contributed to this milestone may vote.
     *         Vote weight is proportional to donation amount.
     *         Once a majority is reached (>50% of raised), the milestone auto-finalizes.
     */
    function vote(bool approve) external onlyProjectActive nonReentrant {
        uint256 idx = currentMilestoneIndex;
        Milestone storage ms = milestones[idx];
        if (ms.status != MilestoneStatus.Voting) revert VotingNotOpen();

        uint256 donorAmount = donations[idx][msg.sender];
        if (donorAmount == 0) revert NothingToRefund(); // not a donor
        if (voted[idx][msg.sender]) revert AlreadyVoted();

        voted[idx][msg.sender] = true;

        if (approve) {
            ms.votesYes += donorAmount;
        } else {
            ms.votesNo += donorAmount;
        }

        emit MilestoneVoted(msg.sender, idx, approve, block.number);

        // Auto-finalize if majority reached
        uint256 half = ms.raised / 2;
        if (ms.votesYes > half) {
            _approveMilestone(idx);
        } else if (ms.votesNo > half) {
            _rejectMilestone(idx);
        }
    }

    // ─── Core: Force Finalize (after vote period) ─────────────────────────────
    /**
     * @notice Anyone can call this to finalize a milestone after enough time has
     *         passed without a clear majority. Whichever side has more votes wins.
     *         If tied, defaults to Rejected (donor protection).
     */
    function finalizeMilestone() external onlyProjectActive nonReentrant {
        uint256 idx = currentMilestoneIndex;
        Milestone storage ms = milestones[idx];
        if (ms.status != MilestoneStatus.Voting) revert VotingNotOpen();

        if (ms.votesYes > ms.votesNo) {
            _approveMilestone(idx);
        } else {
            _rejectMilestone(idx);
        }
    }

    /**
     * @notice Skip a milestone that had zero donations (no one funded it).
     *         Automatically advances to the next milestone.
     */
    function skipMilestone() external onlyProjectActive {
        uint256 idx = currentMilestoneIndex;
        Milestone storage ms = milestones[idx];
        if (ms.status != MilestoneStatus.Pending) revert NotActive();
        if (block.timestamp <= ms.deadline) revert DeadlineNotReached();
        if (ms.raised > 0) revert ZeroAmount(); // has donations — use submitProof

        ms.status = MilestoneStatus.Skipped;
        emit MilestoneFinalized(idx, MilestoneStatus.Skipped, 0, block.number);

        _advanceToNextMilestone();
    }

    // ─── Internal: Milestone resolution ──────────────────────────────────────
    function _approveMilestone(uint256 idx) internal {
        Milestone storage ms = milestones[idx];
        ms.status = MilestoneStatus.Approved;

        // Transfer raised DKT directly to researcher wallet immediately.
        // No FundingPool routing — researcher receives funds as soon as milestone is approved.
        uint256 toTransfer = ms.raised;
        if (toTransfer > 0) {
            dkt.safeTransfer(researcher, toTransfer);
        }

        emit MilestoneFinalized(idx, MilestoneStatus.Approved, ms.raised, block.number);
        _advanceToNextMilestone();
    }

    function _rejectMilestone(uint256 idx) internal {
        milestones[idx].status = MilestoneStatus.Rejected;
        emit MilestoneFinalized(idx, MilestoneStatus.Rejected, milestones[idx].raised, block.number);
        // DKT stays in contract for individual donor refunds
        // Project stays Active — next milestone does NOT advance (project is stalled)
        // Researcher must cancel or wait
    }

    function _advanceToNextMilestone() internal {
        uint256 next = currentMilestoneIndex + 1;
        if (next >= milestones.length) {
            // All milestones done → project completed
            projectStatus = ProjectStatus.Completed;
        } else {
            currentMilestoneIndex = next;
            emit MilestoneActivated(next, block.number);
        }
    }

    // ─── Core: Refund (donors) ────────────────────────────────────────────────
    /**
     * @notice Donor claims a refund for a rejected milestone.
     * @param  milestoneIdx  Which rejected milestone to refund from
     */
    function claimRefund(uint256 milestoneIdx) external nonReentrant {
        if (milestoneIdx >= milestones.length) revert InvalidMilestone();
        if (milestones[milestoneIdx].status != MilestoneStatus.Rejected) revert MilestoneNotRejected();

        uint256 amount = donations[milestoneIdx][msg.sender];
        if (amount == 0) revert NothingToRefund();

        donations[milestoneIdx][msg.sender] = 0;

        emit RefundClaimed(msg.sender, milestoneIdx, amount, block.number);

        dkt.safeTransfer(msg.sender, amount);
    }

    // ─── Core: Cancel (researcher) ────────────────────────────────────────────
    /**
     * @notice Researcher cancels the project. All pending milestone donations become refundable.
     *         Previously approved milestone funds were already sent directly to the researcher.
     */
    function cancel() external onlyResearcher onlyProjectActive {
        projectStatus = ProjectStatus.Cancelled;

        // Mark the current milestone as Rejected so donors can claim refund
        uint256 idx = currentMilestoneIndex;
        Milestone storage ms = milestones[idx];
        if (ms.status == MilestoneStatus.Pending || ms.status == MilestoneStatus.Voting) {
            ms.status = MilestoneStatus.Rejected;
            emit MilestoneFinalized(idx, MilestoneStatus.Rejected, ms.raised, block.number);
        }

        emit ProjectCancelled(block.number);
    }
}
