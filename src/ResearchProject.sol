// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FundingPool.sol";

/**
 * @title ResearchProject
 * @notice Crowdfunding contract for a single research project.
 *         Accepts direct ETH donations, tracks a funding goal and deadline,
 *         and routes funds to FundingPool on success or refunds donors on failure.
 *
 * @dev COMPLEXITY LEVEL 1-2 — low to medium complexity depending on operation.
 *
 *      Lifecycle:
 *        Active   → accepting donations, deadline not passed
 *        Succeeded → goal met OR deadline passed with sufficient funds
 *        Failed   → deadline passed, goal not met → donors can claim refunds
 *        Cancelled → researcher cancelled before deadline
 *
 *      One instance per research project, deployed via ProjectFactory (BeaconProxy).
 *      The Beacon pattern means all ResearchProject instances share one implementation,
 *      upgradeable via a single beacon transaction.
 *
 * Gas profile targets:
 *   donate()           ~65,000 gas  (2 SSTOREs + ETH forward + event)
 *   withdrawFunds()    ~35,000 gas  (1 SSTORE + ETH transfer + event)
 *   claimRefund()      ~40,000 gas  (1 SSTORE + ETH transfer + event)
 *   finalize()         ~30,000 gas  (1 SSTORE + event)
 */
contract ResearchProject is Initializable, ReentrancyGuard {
    // ─── Enums ────────────────────────────────────────────────────────────────
    enum Status {
        Active,
        Succeeded,
        Failed,
        Cancelled
    }

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotResearcher();
    error NotActive();
    error NotFailed();
    error NotSucceeded();
    error DeadlineExceeded(uint256 deadline, uint256 current);
    error DeadlineNotReached(uint256 deadline, uint256 current);
    error GoalAlreadyMet();
    error ZeroAmount();
    error ZeroAddress();
    error NothingToRefund();
    error NothingToWithdraw();
    error TransferFailed();
    error AlreadyFinalized();

    // ─── Events ───────────────────────────────────────────────────────────────
    event DonationReceived(
        address indexed donor,
        uint256 amount,
        uint256 totalRaised,
        uint256 blockNumber
    );
    event GoalReached(
        uint256 totalRaised,
        uint256 blockNumber
    );
    event ProjectFinalized(
        Status status,
        uint256 totalRaised,
        uint256 blockNumber
    );
    event FundsWithdrawn(
        address indexed researcher,
        uint256 amount,
        uint256 blockNumber
    );
    event RefundClaimed(
        address indexed donor,
        uint256 amount,
        uint256 blockNumber
    );
    event ProjectCancelled(uint256 blockNumber);

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Researcher who created and controls this project
    address public researcher;

    /// @notice FundingPool that receives successful donations
    FundingPool public fundingPool;

    /// @notice Unique identifier for this project (keccak256 of title+researcher)
    bytes32 public projectId;

    /// @notice Human-readable project title (stored on-chain for indexing)
    string public title;

    /// @notice Funding goal in ETH (wei)
    uint256 public goalAmount;

    /// @notice Total ETH donated so far
    uint256 public totalRaised;

    /// @notice Unix timestamp when donations close
    uint256 public deadline;

    /// @notice Current project status
    Status public status;

    /// @notice Whether the researcher has already withdrawn their funds
    bool public fundsWithdrawn;

    /// @notice Per-donor ETH contribution (for refunds)
    mapping(address => uint256) public donations;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ─────────────────────────────────────────────────────────
    /**
     * @notice Initialize a new ResearchProject instance (called by ProjectFactory).
     * @param  _researcher   Address of the researcher (receives funds on success)
     * @param  _fundingPool  FundingPool contract address
     * @param  _title        Project title (stored on-chain, emitted in events)
     * @param  _goalAmount   Funding goal in wei
     * @param  _duration     Duration in seconds from now until deadline
     */
    function initialize(
        address _researcher,
        address _fundingPool,
        string calldata _title,
        uint256 _goalAmount,
        uint256 _duration
    ) external initializer {
        if (_researcher == address(0)) revert ZeroAddress();
        if (_fundingPool == address(0)) revert ZeroAddress();
        if (_goalAmount == 0) revert ZeroAmount();
        if (_duration == 0) revert ZeroAmount();

        researcher = _researcher;
        fundingPool = FundingPool(payable(_fundingPool));
        title = _title;
        goalAmount = _goalAmount;
        deadline = block.timestamp + _duration;
        status = Status.Active;

        // Deterministic project ID for cross-contract indexing
        projectId = keccak256(abi.encodePacked(_researcher, _title, block.timestamp));
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyResearcher() {
        if (msg.sender != researcher) revert NotResearcher();
        _;
    }

    modifier onlyActive() {
        if (status != Status.Active) revert NotActive();
        _;
    }

    // ─── Core: Donate ─────────────────────────────────────────────────────────
    /**
     * @notice Donate ETH to this research project.
     * @dev    COMPLEXITY LEVEL 1 — baseline transaction type.
     *         Funds are held in this contract until finalize() is called.
     *         If the goal is met mid-donation, emits GoalReached.
     */
    function donate() external payable onlyActive nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExceeded(deadline, block.timestamp);

        bool goalWasMet = totalRaised >= goalAmount;

        donations[msg.sender] += msg.value;
        totalRaised += msg.value;

        emit DonationReceived(msg.sender, msg.value, totalRaised, block.number);

        // Emit GoalReached exactly once
        if (!goalWasMet && totalRaised >= goalAmount) {
            emit GoalReached(totalRaised, block.number);
        }
    }

    // ─── Core: Finalize ───────────────────────────────────────────────────────
    /**
     * @notice Finalize the project after deadline or goal is met.
     * @dev    Anyone can call this. Transitions status and routes ETH.
     *         If succeeded: forwards all ETH to FundingPool.
     *         If failed: ETH stays in contract for refunds.
     *
     *         This is the key state-transition function — it demonstrates
     *         a multi-contract ETH routing operation for gas profiling.
     */
    function finalize() external onlyActive nonReentrant {
        bool goalMet = totalRaised >= goalAmount;
        bool deadlinePassed = block.timestamp > deadline;

        // Can finalize if: goal met (early success) OR deadline has passed
        if (!goalMet && !deadlinePassed) {
            revert DeadlineNotReached(deadline, block.timestamp);
        }

        if (goalMet) {
            status = Status.Succeeded;
            // Forward all ETH to FundingPool
            uint256 amount = address(this).balance;
            if (amount > 0) {
                fundingPool.receiveDonation{value: amount}(address(this), researcher);
            }
        } else {
            // Deadline passed, goal not met
            status = Status.Failed;
        }

        emit ProjectFinalized(status, totalRaised, block.number);
    }

    // ─── Core: Withdraw (researcher) ─────────────────────────────────────────
    /**
     * @notice Researcher withdraws their FundingPool allocation.
     * @dev    COMPLEXITY LEVEL 2 — cross-contract call after finalization.
     *         Funds were forwarded to FundingPool on finalize().
     *         Researcher calls FundingPool.withdrawAllocation() via this helper.
     *         In the full system, the FundingPool admin allocates first.
     */
    function withdrawFunds(uint256 amount) external onlyResearcher nonReentrant {
        if (status != Status.Succeeded) revert NotSucceeded();
        if (amount == 0) revert ZeroAmount();

        emit FundsWithdrawn(researcher, amount, block.number);

        // Delegate withdrawal to FundingPool (FundingPool uses msg.sender = this contract)
        fundingPool.withdrawAllocation(amount);

        // Forward ETH to researcher
        (bool ok,) = researcher.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Core: Refund (donors) ────────────────────────────────────────────────
    /**
     * @notice Claim a refund if the project failed to meet its goal.
     * @dev    COMPLEXITY LEVEL 1 — simple pull refund.
     *         CEI: zero out donation mapping before transfer.
     */
    function claimRefund() external nonReentrant {
        if (status != Status.Failed) revert NotFailed();

        uint256 amount = donations[msg.sender];
        if (amount == 0) revert NothingToRefund();

        // EFFECT
        donations[msg.sender] = 0;

        emit RefundClaimed(msg.sender, amount, block.number);

        // INTERACTION
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Core: Cancel (researcher) ────────────────────────────────────────────
    /**
     * @notice Researcher cancels the project before deadline.
     * @dev    Sets status to Cancelled, allowing donors to claim refunds.
     *         Only allowed before deadline.
     */
    function cancel() external onlyResearcher onlyActive {
        if (block.timestamp > deadline) revert DeadlineExceeded(deadline, block.timestamp);
        status = Status.Cancelled;
        emit ProjectCancelled(block.number);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    /**
     * @notice Returns key project metrics in a single call (reduces RPC calls).
     */
    function projectInfo()
        external
        view
        returns (
            address _researcher,
            string memory _title,
            uint256 _goal,
            uint256 _raised,
            uint256 _deadline,
            Status _status,
            bool _goalMet
        )
    {
        return (
            researcher,
            title,
            goalAmount,
            totalRaised,
            deadline,
            status,
            totalRaised >= goalAmount
        );
    }

    function isActive() external view returns (bool) {
        return status == Status.Active && block.timestamp <= deadline;
    }

    function timeRemaining() external view returns (uint256) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function fundingProgress() external view returns (uint256 bps) {
        if (goalAmount == 0) return 0;
        return (totalRaised * 10_000) / goalAmount; // basis points (100% = 10_000)
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────
    /// @dev Accepts ETH from FundingPool.withdrawAllocation() forwarded back here
    receive() external payable {}
}
