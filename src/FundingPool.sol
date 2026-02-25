// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FundingPool
 * @notice Aggregates direct ETH donations and simulated yield from stakers,
 *         then allocates funds to individual ResearchProject contracts.
 *
 * @dev COMPLEXITY LEVEL 3 — state-heavy aggregation operation.
 *      Immutable by design — holds real ETH balances so upgradeability would
 *      introduce a rug vector. All parameter changes go through governance.
 *
 *      Two funding streams:
 *        1. Direct donations  → deposited by ResearchProject on each donate() call
 *        2. Yield allocations → deposited by YieldDistributor on claimYield()
 *
 *      Pull pattern: projects withdraw their allocation; FundingPool never pushes.
 *
 * Gas profile targets:
 *   receiveDonation()   ~35,000 gas  (2 SSTOREs + event)
 *   receiveYield()      ~35,000 gas  (2 SSTOREs + event)
 *   allocateToProject() ~40,000 gas  (3 SSTOREs + event) — admin only
 *   withdrawAllocation()~35,000 gas  (1 SSTORE + ETH transfer)
 */
contract FundingPool is AccessControl, ReentrancyGuard {
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
    /// @notice Total ETH in the pool available for allocation
    uint256 public totalPool;

    /// @notice Total cumulative donations received (analytics metric)
    uint256 public totalDonationsReceived;

    /// @notice Total cumulative yield received (analytics metric)
    uint256 public totalYieldReceived;

    /// @notice Per-project pending allocation (not yet withdrawn)
    mapping(address => uint256) public projectAllocations;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /**
     * @param admin Address that receives DEFAULT_ADMIN_ROLE and ALLOCATOR_ROLE.
     *              In production, use a multisig or governance contract.
     */
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ALLOCATOR_ROLE, admin);
    }

    // ─── Funding streams ──────────────────────────────────────────────────────
    /**
     * @notice Record a direct donation to the pool.
     * @dev    Called by ResearchProject when a user donates ETH.
     *         The ETH is sent with this call (msg.value).
     * @param  project  The ResearchProject that received the donation
     * @param  donor    Original donor address (for event indexing)
     */
    function receiveDonation(address project, address donor)
        external
        payable
        onlyRole(DEPOSITOR_ROLE)
    {
        if (msg.value == 0) revert ZeroAmount();

        totalPool += msg.value;
        totalDonationsReceived += msg.value;

        emit DonationReceived(project, donor, msg.value, totalPool, block.number);
    }

    /**
     * @notice Record simulated yield received from the YieldDistributor.
     * @dev    Called when yield is routed to fund research projects.
     *         The ETH is sent with this call (msg.value).
     * @param  source Address of the YieldDistributor or yield claimer
     */
    function receiveYield(address source) external payable onlyRole(DEPOSITOR_ROLE) {
        if (msg.value == 0) revert ZeroAmount();

        totalPool += msg.value;
        totalYieldReceived += msg.value;

        emit YieldReceived(source, msg.value, totalPool, block.number);
    }

    // ─── Allocation ───────────────────────────────────────────────────────────
    /**
     * @notice Allocate a portion of the pool to a specific research project.
     * @dev    Called by admin/governance after reviewing project milestones.
     *         Does NOT transfer ETH — marks an amount as withdrawable by the project.
     * @param  project  ResearchProject contract address
     * @param  amount   ETH amount to allocate
     */
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
     * @notice Withdraw a project's allocated funds.
     * @dev    Pull pattern — the project (or its researcher) calls this.
     *         Uses CEI: clear allocation before transfer.
     * @param  amount Amount of ETH to withdraw (must be <= allocation)
     */
    function withdrawAllocation(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 allocation = projectAllocations[msg.sender];
        if (amount > allocation) revert InsufficientAllocation(amount, allocation);

        // EFFECT
        projectAllocations[msg.sender] = allocation - amount;

        emit AllocationWithdrawn(msg.sender, amount, block.number);

        // INTERACTION
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── View ─────────────────────────────────────────────────────────────────
    /**
     * @notice Returns all top-level pool metrics in a single call.
     * @dev    Reduces RPC round-trips for the analytics dashboard.
     */
    function poolMetrics()
        external
        view
        returns (
            uint256 pool,
            uint256 donations,
            uint256 yield,
            uint256 balance
        )
    {
        return (totalPool, totalDonationsReceived, totalYieldReceived, address(this).balance);
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────
    /// @dev Allows plain ETH transfers (e.g. from test scripts) to top up the pool
    receive() external payable {
        totalPool += msg.value;
    }
}
