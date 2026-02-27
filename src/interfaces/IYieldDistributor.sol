// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IYieldDistributor
 * @notice Interface consumed by StakingVault to notify the distributor of
 *         stake/unstake events and by users to claim yield with a split.
 *
 * Yield-split mechanic:
 *   When a user stakes, they specify:
 *     - targetProject: the ResearchProject address to receive the donated share
 *     - donateBps:     basis points (0–10_000) of yield to route to that project
 *                      e.g. 7000 = 70% to project, 30% to staker wallet
 *   Both values are locked until the user fully unstakes.
 *   claimYield() auto-splits according to the stored ratio.
 */
interface IYieldDistributor {
    // ─── Structs ──────────────────────────────────────────────────────────────
    struct EpochInfo {
        uint256 totalYield;     // Total simulated yield generated this epoch
        uint256 totalStaked;    // Total DKT staked at epoch snapshot
        uint256 yieldRateWAD;   // Yield rate used (WAD = 1e18 = 100%)
        uint256 blockNumber;    // Block when epoch was recorded
        uint256 timestamp;      // Timestamp when epoch was recorded
    }

    /// @notice Per-user yield-split configuration, set at stake time and locked.
    struct YieldSplit {
        address targetProject; // ResearchProject to receive donated yield share
        uint16  donateBps;     // Basis points donated to project (0–10_000)
    }

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotStakingVault();
    error EpochTooEarly(uint256 nextAllowed, uint256 current);
    error NothingToClaim();
    error ZeroAddress();
    error ZeroAmount();
    error RateExceedsMax(uint256 rate, uint256 max);
    error InsufficientYieldPool(uint256 requested, uint256 available);
    error InvalidBps(uint16 bps);
    error ProjectRequired();

    // ─── Events ───────────────────────────────────────────────────────────────
    event RewardIndexUpdated(uint256 newIndex, uint256 timestamp);
    event EpochAdvanced(
        uint256 indexed epoch,
        uint256 totalYield,
        uint256 totalStaked,
        uint256 yieldRateWAD,
        uint256 blockNumber
    );
    event YieldClaimed(
        address indexed user,
        uint256 totalClaimed,
        uint256 toStaker,
        uint256 toProject,
        address indexed targetProject,
        uint256 epoch,
        uint256 blockNumber
    );
    event YieldPoolFunded(address indexed funder, uint256 amount);
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);
    event StakingVaultSet(address indexed vault);
    event FundingPoolSet(address indexed fundingPool);

    // ─── Mutating ─────────────────────────────────────────────────────────────

    /**
     * @notice Called by StakingVault when a user stakes DKT.
     * @param user          The staker address
     * @param amount        DKT amount staked
     * @param targetProject ResearchProject address to receive donated yield (address(0) = no donation)
     * @param donateBps     Basis points of yield to route to project (0 = all to staker)
     */
    function notifyStake(address user, uint256 amount, address targetProject, uint16 donateBps) external;

    function notifyUnstake(address user, uint256 amount) external;
    function claimYield() external returns (uint256 claimed);
    function fundYieldPool(uint256 amount) external;

    // ─── Admin ────────────────────────────────────────────────────────────────
    function advanceEpoch() external;
    function setYieldRate(uint256 newRateWAD) external;
    function setStakingVault(address vault) external;
    function setFundingPool(address fundingPool) external;
    function withdrawUnclaimedYield(address to, uint256 amount) external;

    // ─── Views ────────────────────────────────────────────────────────────────
    function pendingYield(address user) external view returns (uint256);
    function yieldSplit(address user) external view returns (YieldSplit memory);
    function currentEpoch() external view returns (uint256);
    function rewardIndex() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function yieldPool() external view returns (uint256);
    function epochInfo(uint256 epoch) external view returns (EpochInfo memory);
}
