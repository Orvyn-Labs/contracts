// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IYieldDistributor
 * @notice Interface consumed by StakingVault to notify the distributor of
 *         stake/unstake events and by FundingPool to pull accumulated yield.
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

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotStakingVault();
    error EpochTooEarly(uint256 nextAllowed, uint256 current);
    error NothingToClaim();
    error ZeroAddress();
    error ZeroAmount();
    error RateExceedsMax(uint256 rate, uint256 max);
    error InsufficientYieldPool(uint256 requested, uint256 available);

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
        uint256 amount,
        uint256 epoch,
        uint256 blockNumber
    );
    event YieldPoolFunded(address indexed funder, uint256 amount);
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);
    event StakingVaultSet(address indexed vault);

    // ─── Mutating ─────────────────────────────────────────────────────────────
    function notifyStake(address user, uint256 amount) external;
    function notifyUnstake(address user, uint256 amount) external;
    function claimYield() external returns (uint256 claimed);
    function fundYieldPool() external payable;

    // ─── Admin ────────────────────────────────────────────────────────────────
    function advanceEpoch() external;
    function setYieldRate(uint256 newRateWAD) external;
    function setStakingVault(address vault) external;
    function withdrawUnclaimedYield(address to, uint256 amount) external;

    // ─── Views ────────────────────────────────────────────────────────────────
    function pendingYield(address user) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function rewardIndex() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function yieldPool() external view returns (uint256);
    function epochInfo(uint256 epoch) external view returns (EpochInfo memory);
}
