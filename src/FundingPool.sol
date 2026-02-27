// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FundingPool
 * @notice Aggregates DKT token donations and simulated yield from stakers,
 *         then allocates funds to individual ResearchProject contracts.
 *
 * @dev COMPLEXITY LEVEL 3 — state-heavy aggregation operation.
 *      All amounts are in DKT (18 decimals).
 *      Immutable by design — holds real DKT balances.
 *
 *      Two funding streams:
 *        1. Direct donations  → deposited by ResearchProject on each donate() call
 *        2. Yield allocations → deposited by YieldDistributor on claimYield()
 *
 *      Pull pattern: projects withdraw their allocation; FundingPool never pushes.
 */
contract FundingPool is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // ─── Errors ───────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientPool(uint256 requested, uint256 available);
    error InsufficientAllocation(uint256 requested, uint256 available);
    error TransferFailed();

    // ─── Events ───────────────────────────────────────────────────────────────
    event DonationReceived(
        address indexed project,
        address indexed donor,
        uint256 amount,
        uint256 newPoolTotal,
        uint256 blockNumber
    );
    event YieldReceived(
        address indexed source,
        uint256 amount,
        uint256 newPoolTotal,
        uint256 blockNumber
    );
    event YieldRoutedToProject(
        address indexed project,
        address indexed staker,
        uint256 amount,
        uint256 blockNumber
    );
    event AllocationMade(
        address indexed project,
        uint256 amount,
        uint256 remainingPool,
        uint256 blockNumber
    );
    event AllocationWithdrawn(
        address indexed project,
        uint256 amount,
        uint256 blockNumber
    );

    // ─── State ────────────────────────────────────────────────────────────────
    IERC20 public immutable dkt;

    uint256 public totalPool;
    uint256 public totalDonationsReceived;
    uint256 public totalYieldReceived;
    uint256 public totalYieldRoutedToProjects;

    mapping(address => uint256) public projectAllocations;

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address admin, address _dkt) {
        if (admin == address(0)) revert ZeroAddress();
        if (_dkt == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ALLOCATOR_ROLE, admin);
        dkt = IERC20(_dkt);
    }

    // ─── Funding streams ──────────────────────────────────────────────────────

    /**
     * @notice Record a direct DKT donation. Called by ResearchProject after transferring DKT here.
     * @dev    Caller (ResearchProject) must have approved FundingPool for `amount` DKT,
     *         then this function pulls the tokens in.
     */
    function receiveDonation(address project, address donor, uint256 amount)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (amount == 0) revert ZeroAmount();

        dkt.safeTransferFrom(msg.sender, address(this), amount);
        totalPool += amount;
        totalDonationsReceived += amount;

        emit DonationReceived(project, donor, amount, totalPool, block.number);
    }

    /**
     * @notice Record simulated DKT yield received from the YieldDistributor.
     */
    function receiveYield(address source, uint256 amount)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (amount == 0) revert ZeroAmount();

        dkt.safeTransferFrom(msg.sender, address(this), amount);
        totalPool += amount;
        totalYieldReceived += amount;

        emit YieldReceived(source, amount, totalPool, block.number);
    }

    /**
     * @notice Accept DKT yield routed from YieldDistributor directly to a specific project.
     * @dev    Credits immediately to the project's allocation — no admin step required.
     */
    function receiveYieldForProject(address project, address staker, uint256 amount)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        if (project == address(0)) revert ZeroAddress();

        dkt.safeTransferFrom(msg.sender, address(this), amount);
        projectAllocations[project] += amount;
        totalYieldRoutedToProjects += amount;

        emit YieldRoutedToProject(project, staker, amount, block.number);
    }

    // ─── Allocation ───────────────────────────────────────────────────────────

    function allocateToProject(address project, uint256 amount)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        if (project == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalPool) revert InsufficientPool(amount, totalPool);

        totalPool -= amount;
        projectAllocations[project] += amount;

        emit AllocationMade(project, amount, totalPool, block.number);
    }

    /**
     * @notice Withdraw a project's allocated DKT.
     * @dev    Pull pattern — msg.sender is the project contract.
     */
    function withdrawAllocation(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 allocation = projectAllocations[msg.sender];
        if (amount > allocation) revert InsufficientAllocation(amount, allocation);

        projectAllocations[msg.sender] = allocation - amount;

        emit AllocationWithdrawn(msg.sender, amount, block.number);

        dkt.safeTransfer(msg.sender, amount);
    }

    // ─── View ─────────────────────────────────────────────────────────────────
    function totalDonations() external view returns (uint256) { return totalDonationsReceived; }
    function totalYieldDistributed() external view returns (uint256) { return totalYieldReceived + totalYieldRoutedToProjects; }
    function projectBalance(address project) external view returns (uint256) { return projectAllocations[project]; }

    function poolMetrics()
        external
        view
        returns (uint256 pool, uint256 donations, uint256 yield, uint256 balance)
    {
        return (totalPool, totalDonationsReceived, totalYieldReceived + totalYieldRoutedToProjects, dkt.balanceOf(address(this)));
    }
}
