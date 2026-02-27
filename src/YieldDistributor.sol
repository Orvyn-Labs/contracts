// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IYieldDistributor.sol";

interface IFundingPoolYield {
    function receiveYieldForProject(address project, address staker) external payable;
}

/**
 * @title YieldDistributor
 * @notice Simulates yield for staked DKT tokens and distributes it according to
 *         each staker's configured yield-split:
 *           - A configurable percentage (donateBps) is forwarded to a chosen
 *             ResearchProject via FundingPool.receiveYieldForProject()
 *           - The remainder is sent to the staker's wallet
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
 *      claimYield() auto-split:
 *        toProject = totalYield * donateBps / 10_000   → forwarded to FundingPool
 *        toStaker  = totalYield - toProject             → sent to msg.sender
 *
 * Upgradeability: UUPS — allows swapping the yield algorithm between versions.
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
    uint256 public constant MAX_YIELD_RATE_WAD = 1e18;
    uint256 public constant MIN_EPOCH_DURATION = 1 hours;

    // ─── Storage (ERC-7201 namespaced) ────────────────────────────────────────
    /// @custom:storage-location erc7201:skripsi.YieldDistributor
    struct YieldDistributorStorage {
        uint256 rewardIndex;
        uint256 lastUpdateTime;
        uint256 yieldRateWAD;
        uint256 totalStaked;
        uint256 yieldPool;
        uint256 currentEpoch;
        uint256 lastEpochTime;
        mapping(address => uint256) userStakedBalance;
        mapping(address => uint256) userIndexSnapshot;
        mapping(uint256 => EpochInfo) epochData;
        address stakingVault;
        address fundingPool;
        // Per-user yield-split config, set at stake time, locked until fully unstaked
        mapping(address => YieldSplit) userYieldSplit;
    }

    function _storage() private pure returns (YieldDistributorStorage storage $) {
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
    function initialize(address admin, uint256 initialRateWAD) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (initialRateWAD > MAX_YIELD_RATE_WAD) revert RateExceedsMax(initialRateWAD, MAX_YIELD_RATE_WAD);

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EPOCH_ADMIN_ROLE, admin);
        _grantRole(YIELD_ADMIN_ROLE, admin);

        YieldDistributorStorage storage $ = _storage();
        $.rewardIndex = WAD;
        $.lastUpdateTime = block.timestamp;
        $.yieldRateWAD = initialRateWAD;
        $.lastEpochTime = block.timestamp;
        $.currentEpoch = 0;
    }

    // ─── Internal: Index update ───────────────────────────────────────────────
    function _accrueIndex() internal {
        YieldDistributorStorage storage $ = _storage();
        uint256 elapsed = block.timestamp - $.lastUpdateTime;
        if (elapsed == 0 || $.totalStaked == 0) {
            $.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 delta = ($.yieldRateWAD * elapsed) / 365 days;
        $.rewardIndex += delta;
        $.lastUpdateTime = block.timestamp;

        emit RewardIndexUpdated($.rewardIndex, block.timestamp);
    }

    // ─── Internal: Pending yield (view-safe) ─────────────────────────────────
    function _computePendingYield(address user) internal view returns (uint256) {
        YieldDistributorStorage storage $ = _storage();
        uint256 balance = $.userStakedBalance[user];
        if (balance == 0) return 0;

        uint256 elapsed = block.timestamp - $.lastUpdateTime;
        uint256 projectedIndex = $.rewardIndex;
        if (elapsed > 0 && $.totalStaked > 0) {
            projectedIndex += ($.yieldRateWAD * elapsed) / 365 days;
        }

        uint256 indexDelta = projectedIndex - $.userIndexSnapshot[user];
        return (balance * indexDelta) / WAD;
    }

    // ─── StakingVault callbacks ───────────────────────────────────────────────

    /**
     * @notice Called by StakingVault when a user stakes DKT.
     * @param user          The staker
     * @param amount        DKT amount staked
     * @param targetProject ResearchProject to receive donated yield (address(0) allowed if donateBps==0)
     * @param donateBps     Basis points (0–10_000) of yield to route to the project
     */
    function notifyStake(address user, uint256 amount, address targetProject, uint16 donateBps)
        external
        override
    {
        YieldDistributorStorage storage $ = _storage();
        if (msg.sender != $.stakingVault) revert NotStakingVault();
        if (amount == 0) revert ZeroAmount();
        if (donateBps > 10_000) revert InvalidBps(donateBps);
        if (donateBps > 0 && targetProject == address(0)) revert ProjectRequired();

        _accrueIndex();

        $.userIndexSnapshot[user] = $.rewardIndex;
        $.userStakedBalance[user] += amount;
        $.totalStaked += amount;

        // Lock the split config (only update if this is their first/re-stake from zero)
        if ($.userStakedBalance[user] == amount) {
            // Fresh stake (was zero before) — set new split
            $.userYieldSplit[user] = YieldSplit({ targetProject: targetProject, donateBps: donateBps });
        }
        // If already staked (adding to existing position), split config remains unchanged
    }

    /**
     * @notice Called by StakingVault when a user unstakes DKT.
     * @dev    Clears split config when balance reaches zero.
     */
    function notifyUnstake(address user, uint256 amount) external override {
        YieldDistributorStorage storage $ = _storage();
        if (msg.sender != $.stakingVault) revert NotStakingVault();
        if (amount == 0) revert ZeroAmount();

        _accrueIndex();

        $.userIndexSnapshot[user] = $.rewardIndex;
        $.userStakedBalance[user] -= amount;
        $.totalStaked -= amount;

        // Clear split config when fully unstaked
        if ($.userStakedBalance[user] == 0) {
            delete $.userYieldSplit[user];
        }
    }

    // ─── User: Claim yield ────────────────────────────────────────────────────
    /**
     * @notice Claim all pending yield with automatic split:
     *         - (donateBps / 10_000) fraction → forwarded to chosen ResearchProject via FundingPool
     *         - remainder → sent to caller's wallet
     *
     * @dev If donateBps == 0 or targetProject == address(0), 100% goes to the staker.
     *      If fundingPool is not set, the project share falls back to the staker.
     * @return claimed Total yield claimed (staker portion + project portion)
     */
    function claimYield() external override nonReentrant returns (uint256 claimed) {
        YieldDistributorStorage storage $ = _storage();

        _accrueIndex();

        claimed = _computePendingYield(msg.sender);
        if (claimed == 0) revert NothingToClaim();
        if (claimed > $.yieldPool) revert InsufficientYieldPool(claimed, $.yieldPool);

        // EFFECTS — snapshot before any transfers
        $.userIndexSnapshot[msg.sender] = $.rewardIndex;
        $.yieldPool -= claimed;

        // Calculate split
        YieldSplit memory split = $.userYieldSplit[msg.sender];
        uint256 toProject = 0;
        uint256 toStaker = claimed;

        if (split.donateBps > 0 && split.targetProject != address(0) && $.fundingPool != address(0)) {
            toProject = (claimed * split.donateBps) / 10_000;
            toStaker = claimed - toProject;
        }

        emit YieldClaimed(
            msg.sender,
            claimed,
            toStaker,
            toProject,
            split.targetProject,
            $.currentEpoch,
            block.number
        );

        // INTERACTIONS — transfers last (CEI)
        if (toStaker > 0) {
            (bool ok,) = msg.sender.call{value: toStaker}("");
            require(ok, "Staker ETH transfer failed");
        }

        if (toProject > 0) {
            // Forward to FundingPool.receiveYieldForProject()
            IFundingPoolYield($.fundingPool).receiveYieldForProject{value: toProject}(
                split.targetProject,
                msg.sender
            );
        }
    }

    // ─── Admin: Epoch management ─────────────────────────────────────────────
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
    function setYieldRate(uint256 newRateWAD) external override onlyRole(YIELD_ADMIN_ROLE) {
        if (newRateWAD > MAX_YIELD_RATE_WAD) revert RateExceedsMax(newRateWAD, MAX_YIELD_RATE_WAD);

        _accrueIndex();

        YieldDistributorStorage storage $ = _storage();
        uint256 old = $.yieldRateWAD;
        $.yieldRateWAD = newRateWAD;

        emit YieldRateUpdated(old, newRateWAD);
    }

    function setStakingVault(address vault) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        YieldDistributorStorage storage $ = _storage();
        $.stakingVault = vault;
        emit StakingVaultSet(vault);
    }

    /**
     * @notice Set the FundingPool address for routing project yield donations.
     * @dev    FundingPool must grant DEPOSITOR_ROLE to this contract.
     */
    function setFundingPool(address fundingPool) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fundingPool == address(0)) revert ZeroAddress();
        YieldDistributorStorage storage $ = _storage();
        $.fundingPool = fundingPool;
        emit FundingPoolSet(fundingPool);
    }

    function fundYieldPool() external payable override {
        if (msg.value == 0) revert ZeroAmount();
        YieldDistributorStorage storage $ = _storage();
        $.yieldPool += msg.value;
        emit YieldPoolFunded(msg.sender, msg.value);
    }

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

    function yieldSplit(address user) external view override returns (YieldSplit memory) {
        return _storage().userYieldSplit[user];
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

    function getFundingPool() external view returns (address) {
        return _storage().fundingPool;
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

    receive() external payable {
        YieldDistributorStorage storage $ = _storage();
        $.yieldPool += msg.value;
        emit YieldPoolFunded(msg.sender, msg.value);
    }
}
