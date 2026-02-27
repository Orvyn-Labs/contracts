// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./FundingPool.sol";

/**
 * @title ResearchProject
 * @notice Crowdfunding contract for a single research project.
 *         Accepts DKT token donations, tracks a funding goal and deadline,
 *         and routes funds to FundingPool on success or refunds donors on failure.
 *
 * @dev COMPLEXITY LEVEL 1-2 — low to medium complexity depending on operation.
 *
 *      All amounts are in DKT (18 decimals).
 *      Donors must approve this contract to spend their DKT before calling donate().
 *
 * Upgradeability: Beacon Proxy — all instances upgraded via ProjectFactory.upgradeBeacon().
 */
contract ResearchProject is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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
    event GoalReached(uint256 totalRaised, uint256 blockNumber);
    event ProjectFinalized(Status status, uint256 totalRaised, uint256 blockNumber);
    event FundsWithdrawn(address indexed researcher, uint256 amount, uint256 blockNumber);
    event RefundClaimed(address indexed donor, uint256 amount, uint256 blockNumber);
    event ProjectCancelled(uint256 blockNumber);

    // ─── State ────────────────────────────────────────────────────────────────
    address public researcher;
    FundingPool public fundingPool;
    IERC20 public dkt;
    bytes32 public projectId;
    string public title;
    uint256 public goalAmount;
    uint256 public totalRaised;
    uint256 public deadline;
    Status public status;
    mapping(address => uint256) public donations;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ─────────────────────────────────────────────────────────
    function initialize(
        address _researcher,
        address _fundingPool,
        address _dkt,
        string calldata _title,
        uint256 _goalAmount,
        uint256 _duration
    ) external initializer {
        if (_researcher == address(0)) revert ZeroAddress();
        if (_fundingPool == address(0)) revert ZeroAddress();
        if (_dkt == address(0)) revert ZeroAddress();
        if (_goalAmount == 0) revert ZeroAmount();
        if (_duration == 0) revert ZeroAmount();

        researcher = _researcher;
        fundingPool = FundingPool(payable(_fundingPool));
        dkt = IERC20(_dkt);
        title = _title;
        goalAmount = _goalAmount;
        deadline = block.timestamp + _duration;
        status = Status.Active;
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
     * @notice Donate DKT tokens to this research project.
     * @dev    Caller must have approved this contract to spend `amount` DKT.
     * @param  amount DKT amount to donate (18 decimals)
     */
    function donate(uint256 amount) external onlyActive nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExceeded(deadline, block.timestamp);

        bool goalWasMet = totalRaised >= goalAmount;

        dkt.safeTransferFrom(msg.sender, address(this), amount);
        donations[msg.sender] += amount;
        totalRaised += amount;

        emit DonationReceived(msg.sender, amount, totalRaised, block.number);

        if (!goalWasMet && totalRaised >= goalAmount) {
            emit GoalReached(totalRaised, block.number);
        }
    }

    // ─── Core: Finalize ───────────────────────────────────────────────────────
    /**
     * @notice Finalize the project after deadline or goal is met.
     *         If succeeded: forwards all DKT to FundingPool.
     *         If failed: DKT stays in contract for refunds.
     */
    function finalize() external onlyActive nonReentrant {
        bool goalMet = totalRaised >= goalAmount;
        bool deadlinePassed = block.timestamp > deadline;

        if (!goalMet && !deadlinePassed) {
            revert DeadlineNotReached(deadline, block.timestamp);
        }

        if (goalMet) {
            status = Status.Succeeded;
            uint256 amount = dkt.balanceOf(address(this));
            if (amount > 0) {
                dkt.forceApprove(address(fundingPool), amount);
                fundingPool.receiveDonation(address(this), researcher, amount);
            }
        } else {
            status = Status.Failed;
        }

        emit ProjectFinalized(status, totalRaised, block.number);
    }

    // ─── Core: Withdraw (researcher) ─────────────────────────────────────────
    /**
     * @notice Researcher withdraws their FundingPool allocation in DKT.
     */
    function withdrawFunds(uint256 amount) external onlyResearcher nonReentrant {
        if (status != Status.Succeeded) revert NotSucceeded();
        if (amount == 0) revert ZeroAmount();

        emit FundsWithdrawn(researcher, amount, block.number);

        // FundingPool.withdrawAllocation() transfers DKT back to this contract
        fundingPool.withdrawAllocation(amount);

        // Forward DKT to researcher
        dkt.safeTransfer(researcher, amount);
    }

    // ─── Core: Refund (donors) ────────────────────────────────────────────────
    /**
     * @notice Claim a DKT refund if the project failed to meet its goal.
     */
    function claimRefund() external nonReentrant {
        if (status != Status.Failed) revert NotFailed();

        uint256 amount = donations[msg.sender];
        if (amount == 0) revert NothingToRefund();

        donations[msg.sender] = 0;

        emit RefundClaimed(msg.sender, amount, block.number);

        dkt.safeTransfer(msg.sender, amount);
    }

    // ─── Core: Cancel (researcher) ────────────────────────────────────────────
    function cancel() external onlyResearcher onlyActive {
        if (block.timestamp > deadline) revert DeadlineExceeded(deadline, block.timestamp);
        status = Status.Cancelled;
        emit ProjectCancelled(block.number);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
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
        return (researcher, title, goalAmount, totalRaised, deadline, status, totalRaised >= goalAmount);
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
        return (totalRaised * 10_000) / goalAmount;
    }
}
