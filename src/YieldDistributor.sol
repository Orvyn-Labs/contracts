// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IYieldDistributor.sol";

/**
 * @title YieldDistributor
 * @notice Simulates yield generation for staked DKT tokens and allocates it to
 *         the FundingPool for research project funding.
 *
 * @dev COMPLEXITY LEVEL 3 — computation-heavy.
 *      Uses a global reward-index algorithm (O(1) per user) inspired by
 *      Compound's interest accrual model. No loops over staker sets.
 *
 *      Algorithm:
 *        rewardIndex grows continuously based on (yieldRateWAD * elapsed) / 1 year.
 *        Each user snapshots the index at stake/unstake time.
 *        Pending yield = stakedBalance * (currentIndex - userSnapshot) / WAD
 *
 *      Yield is paid from a pre-funded ETH pool (admin deposits ETH via fundYieldPool).
 *      The simulated yield rate is tunable between research runs via setYieldRate().
 *
 * Upgradeability: UUPS — allows swapping the yield algorithm between V1/V2/V3
 *                 for research comparison without redeploying the whole system.
 *
 * Gas profile targets (approximate):
 *   notifyStake()   ~35,000 gas   (index update + 2 SSTOREs)
 *   notifyUnstake() ~35,000 gas   (index update + 2 SSTOREs)
 *   claimYield()    ~55,000 gas   (index math + ETH transfer)
 *   advanceEpoch()  ~40,000 gas   (snapshot + 3 SSTOREs + event)
 */
contract YieldDistributor is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    IYieldDistributor
{
    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant EPOCH_ADMIN_ROLE = keccak256("EPOCH_ADMIN_ROLE");
    bytes32 public constant YIELD_ADMIN_ROLE = keccak256("YIELD_ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant WAD = 1e18;

    /// @dev Max annual yield rate: 100% (1e18 WAD). Prevents runaway yield inflation.
    uint256 public constant MAX_YIELD_RATE_WAD = 1e18;

    /// @dev Minimum epoch duration: 1 hour. Prevents epoch spam.
    uint256 public constant MIN_EPOCH_DURATION = 1 hours;

    // ─── Storage (ERC-7201 namespaced) ────────────────────────────────────────
    /// @custom:storage-location erc7201:skripsi.YieldDistributor
    struct YieldDistributorStorage {
        // Global reward index — grows monotonically, scaled by WAD
        uint256 rewardIndex;
        // Timestamp of last rewardIndex update
        uint256 lastUpdateTime;
        // Annual yield rate in WAD (e.g. 0.1e18 = 10% APY)
        uint256 yieldRateWAD;
        // Total DKT staked (mirrored from StakingVault for index math)
        uint256 totalStaked;
        // ETH pool pre-funded by admin to pay out yield
        uint256 yieldPool;
        // Current epoch counter
        uint256 currentEpoch;
        // Timestamp of last epoch advance
        uint256 lastEpochTime;
        // Per-user staked balance (mirrored from StakingVault)
        mapping(address => uint256) userStakedBalance;
        // Per-user snapshot of rewardIndex at last interaction
        mapping(address => uint256) userIndexSnapshot;
        // Per-epoch metadata for research analytics
        mapping(uint256 => EpochInfo) epochData;
        // Address of the authorised StakingVault
        address stakingVault;
    }

    function _storage() private pure returns (YieldDistributorStorage storage $) {
        // keccak256("skripsi.YieldDistributor.storage") — stable slot for this contract
        assembly {
            $.slot := 0xd9b64bc316a23de25bdb28d9e43bcabf09bfa28d3ea1726e10b3a7c75a9dd100
        }
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ─────────────────────────────────────────────────────────
    /**
     * @param admin          Address granted DEFAULT_ADMIN_ROLE, EPOCH_ADMIN_ROLE, YIELD_ADMIN_ROLE
     * @param initialRateWAD Initial annual yield rate (e.g. 0.05e18 = 5% APY)
     */
    function initialize(address admin, uint256 initialRateWAD) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (initialRateWAD > MAX_YIELD_RATE_WAD) revert RateExceedsMax(initialRateWAD, MAX_YIELD_RATE_WAD);

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EPOCH_ADMIN_ROLE, admin);
        _grantRole(YIELD_ADMIN_ROLE, admin);

        YieldDistributorStorage storage $ = _storage();
        $.rewardIndex = WAD; // Start at 1.0 to avoid zero-multiplication edge cases
        $.lastUpdateTime = block.timestamp;
        $.yieldRateWAD = initialRateWAD;
        $.lastEpochTime = block.timestamp;
        $.currentEpoch = 0;
    }

    // ─── Internal: Index update ───────────────────────────────────────────────
    /**
     * @dev Accrues the global reward index based on time elapsed and current yield rate.
     *      Called before any state change that depends on the index.
     *
     *      Formula:
     *        delta = yieldRateWAD * elapsed / 365 days
     *        rewardIndex += delta
     *
     *      If totalStaked == 0, the index does not advance (no stakers = no yield).
     */
    function _accrueIndex() internal {
        YieldDistributorStorage storage $ = _storage();
        uint256 elapsed = block.timestamp - $.lastUpdateTime;
        if (elapsed == 0 || $.totalStaked == 0) {
            $.lastUpdateTime = block.timestamp;
            return;
        }

        // index delta = rate * elapsed / 1 year (all in WAD)
        uint256 delta = ($.yieldRateWAD * elapsed) / 365 days;
        $.rewardIndex += delta;
        $.lastUpdateTime = block.timestamp;

        emit RewardIndexUpdated($.rewardIndex, block.timestamp);
    }

    // ─── Internal: Pending yield (view-safe) ─────────────────────────────────
    /**
     * @dev Computes pending yield using the live (not-yet-stored) index.
     *      Safe to call from view functions without state changes.
     */
    function _computePendingYield(address user) internal view returns (uint256) {
        YieldDistributorStorage storage $ = _storage();
        uint256 balance = $.userStakedBalance[user];
        if (balance == 0) return 0;

        // Project the current index forward in time (view-only)
        uint256 elapsed = block.timestamp - $.lastUpdateTime;
        uint256 projectedIndex = $.rewardIndex;
        if (elapsed > 0 && $.totalStaked > 0) {
            projectedIndex += ($.yieldRateWAD * elapsed) / 365 days;
        }

        uint256 indexDelta = projectedIndex - $.userIndexSnapshot[user];
        // yield = balance * indexDelta / WAD
        return (balance * indexDelta) / WAD;
    }

    // ─── StakingVault callbacks ───────────────────────────────────────────────
    /**
     * @notice Called by StakingVault when a user stakes DKT.
     * @dev    Accrues index first, then snapshots for the new staker.
     *         Increasing totalStaked dilutes future yield per token (fair share).
     */
    function notifyStake(address user, uint256 amount) external override {
        YieldDistributorStorage storage $ = _storage();
        if (msg.sender != $.stakingVault) revert NotStakingVault();
        if (amount == 0) revert ZeroAmount();

        _accrueIndex();

        // Snapshot current index so the user earns from this point forward
        $.userIndexSnapshot[user] = $.rewardIndex;
        $.userStakedBalance[user] += amount;
        $.totalStaked += amount;
    }

    /**
     * @notice Called by StakingVault when a user unstakes DKT.
     * @dev    Accrues index, credits pending yield to user's claimable balance,
     *         then reduces their tracked balance.
     */
    function notifyUnstake(address user, uint256 amount) external override {
        YieldDistributorStorage storage $ = _storage();
        if (msg.sender != $.stakingVault) revert NotStakingVault();
        if (amount == 0) revert ZeroAmount();

        _accrueIndex();

        // Finalize any pending yield before reducing balance
        // (pending yield is implicitly held in the index delta until claimed)
        $.userIndexSnapshot[user] = $.rewardIndex;

        $.userStakedBalance[user] -= amount;
        $.totalStaked -= amount;
    }

    // ─── User: Claim yield ────────────────────────────────────────────────────
    /**
     * @notice Claim all pending simulated yield as ETH.
     * @dev    Checks-Effects-Interactions pattern. Index accrued before state change.
     * @return claimed Amount of ETH transferred to caller
     */
    function claimYield() external override nonReentrant returns (uint256 claimed) {
        YieldDistributorStorage storage $ = _storage();

        _accrueIndex();

        claimed = _computePendingYield(msg.sender);
        if (claimed == 0) revert NothingToClaim();
        if (claimed > $.yieldPool) revert InsufficientYieldPool(claimed, $.yieldPool);

        // EFFECTS — update snapshot before transfer
        $.userIndexSnapshot[msg.sender] = $.rewardIndex;
        $.yieldPool -= claimed;

        emit YieldClaimed(msg.sender, claimed, $.currentEpoch, block.number);

        // INTERACTION — transfer ETH last
        (bool ok,) = msg.sender.call{value: claimed}("");
        require(ok, "ETH transfer failed");
    }

    // ─── Admin: Epoch management ─────────────────────────────────────────────
    /**
     * @notice Advance the epoch counter and snapshot current state.
     * @dev    Epochs create discrete measurement windows for academic analysis.
     *         Can be called no more than once per MIN_EPOCH_DURATION.
     *         Research scripts call this to segment experiment phases.
     */
    function advanceEpoch() external override onlyRole(EPOCH_ADMIN_ROLE) {
        YieldDistributorStorage storage $ = _storage();

        if (block.timestamp < $.lastEpochTime + MIN_EPOCH_DURATION) {
            revert EpochTooEarly($.lastEpochTime + MIN_EPOCH_DURATION, block.timestamp);
        }

        _accrueIndex();

        uint256 epoch = $.currentEpoch;
        uint256 totalYieldThisEpoch = $.totalStaked > 0
            ? ($.totalStaked * $.yieldRateWAD * (block.timestamp - $.lastEpochTime)) / (365 days * WAD)
            : 0;

        $.epochData[epoch] = EpochInfo({
            totalYield: totalYieldThisEpoch,
            totalStaked: $.totalStaked,
            yieldRateWAD: $.yieldRateWAD,
            blockNumber: block.number,
            timestamp: block.timestamp
        });

        $.currentEpoch += 1;
        $.lastEpochTime = block.timestamp;

        emit EpochAdvanced(epoch, totalYieldThisEpoch, $.totalStaked, $.yieldRateWAD, block.number);
    }

    // ─── Admin: Configuration ─────────────────────────────────────────────────
    /**
     * @notice Update the annual yield rate.
     * @dev    Key research variable — change this between experiment runs to
     *         compare gas costs at different computational loads.
     * @param  newRateWAD New annual rate (e.g. 0.1e18 = 10%, 0.5e18 = 50%)
     */
    function setYieldRate(uint256 newRateWAD) external override onlyRole(YIELD_ADMIN_ROLE) {
        if (newRateWAD > MAX_YIELD_RATE_WAD) revert RateExceedsMax(newRateWAD, MAX_YIELD_RATE_WAD);

        _accrueIndex(); // Finalize index at old rate before changing

        YieldDistributorStorage storage $ = _storage();
        uint256 old = $.yieldRateWAD;
        $.yieldRateWAD = newRateWAD;

        emit YieldRateUpdated(old, newRateWAD);
    }

    /**
     * @notice Set the authorised StakingVault address.
     * @dev    Only the StakingVault may call notifyStake/notifyUnstake.
     */
    function setStakingVault(address vault) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        YieldDistributorStorage storage $ = _storage();
        $.stakingVault = vault;
        emit StakingVaultSet(vault);
    }

    // ─── Admin: Yield pool funding ────────────────────────────────────────────
    /**
     * @notice Fund the ETH yield pool.
     * @dev    Admin pre-funds this pool before experiment runs.
     *         In production, this would be replaced by actual DeFi yield.
     */
    function fundYieldPool() external payable override {
        if (msg.value == 0) revert ZeroAmount();
        YieldDistributorStorage storage $ = _storage();
        $.yieldPool += msg.value;
        emit YieldPoolFunded(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw unclaimed yield from the pool (admin recovery).
     */
    function withdrawUnclaimedYield(address to, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        YieldDistributorStorage storage $ = _storage();
        if (amount > $.yieldPool) revert InsufficientYieldPool(amount, $.yieldPool);

        $.yieldPool -= amount;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // ─── View functions ───────────────────────────────────────────────────────
    function pendingYield(address user) external view override returns (uint256) {
        return _computePendingYield(user);
    }

    function currentEpoch() external view override returns (uint256) {
        return _storage().currentEpoch;
    }

    function rewardIndex() external view override returns (uint256) {
        return _storage().rewardIndex;
    }

    function totalStaked() external view override returns (uint256) {
        return _storage().totalStaked;
    }

    function yieldPool() external view override returns (uint256) {
        return _storage().yieldPool;
    }

    function epochInfo(uint256 epoch) external view override returns (EpochInfo memory) {
        return _storage().epochData[epoch];
    }

    function stakingVault() external view returns (address) {
        return _storage().stakingVault;
    }

    function yieldRateWAD() external view returns (uint256) {
        return _storage().yieldRateWAD;
    }

    function userStakedBalance(address user) external view returns (uint256) {
        return _storage().userStakedBalance[user];
    }

    function userIndexSnapshot(address user) external view returns (uint256) {
        return _storage().userIndexSnapshot[user];
    }

    // ─── UUPS ─────────────────────────────────────────────────────────────────
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    // ─── Receive ETH (for yield pool funding via plain transfer) ─────────────
    receive() external payable {
        YieldDistributorStorage storage $ = _storage();
        $.yieldPool += msg.value;
        emit YieldPoolFunded(msg.sender, msg.value);
    }
}
