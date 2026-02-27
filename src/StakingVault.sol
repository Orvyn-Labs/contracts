// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IYieldDistributor.sol";

/**
 * @title StakingVault
 * @notice Accepts DKT (Dikti Token) deposits, enforces a lock period,
 *         and notifies YieldDistributor of stake/unstake events.
 *         Users do NOT lose principal — staking is purely for yield generation.
 *
 * @dev COMPLEXITY LEVEL 2 — medium complexity (ERC-20 transfer + multiple SSTOREs).
 *
 *      Yield-split mechanic (v2):
 *        When calling stake(), the user specifies:
 *          - targetProject : a ResearchProject address to receive donated yield
 *          - donateBps     : basis points (0–10_000) of yield to route to that project
 *        Example: donateBps=7000 → 70% goes to the project, 30% back to staker.
 *        donateBps=0  → 100% of yield returned to staker (no donation).
 *        donateBps=10_000 → 100% donated to project.
 *        The split is locked until the staker fully unstakes.
 *
 *      Flow:
 *        1. User approves StakingVault to spend DKT
 *        2. User calls stake(amount, targetProject, donateBps)
 *        3. After lockPeriod, user calls unstake(amount)
 *        4. User calls claimYield() — yield is automatically split
 *
 * Upgradeability: UUPS — allows tuning lock period between research runs.
 *
 * Gas profile targets:
 *   stake()    ~105,000 gas  (ERC-20 transferFrom + 4 SSTOREs + external call)
 *   unstake()  ~85,000  gas  (ERC-20 transfer + 3 SSTOREs + external call)
 */
contract StakingVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");

    // ─── Errors ───────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error StillLocked(uint256 unlockTime, uint256 currentTime);
    error InsufficientStake(uint256 requested, uint256 available);
    error LockPeriodTooLong(uint256 requested, uint256 max);
    error InvalidDonateBps(uint16 bps);
    error ProjectRequiredForDonation();

    // ─── Events ───────────────────────────────────────────────────────────────
    event Staked(
        address indexed staker,
        uint256 amount,
        uint256 newBalance,
        uint256 lockExpiry,
        address indexed targetProject,
        uint16  donateBps,
        uint256 blockNumber
    );
    event Unstaked(
        address indexed staker,
        uint256 amount,
        uint256 remainingBalance,
        uint256 blockNumber
    );
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event YieldDistributorUpdated(address indexed oldDist, address indexed newDist);

    // ─── Storage (ERC-7201 namespaced) ────────────────────────────────────────
    /// @custom:storage-location erc7201:skripsi.StakingVault
    struct StakingVaultStorage {
        IERC20 dkt;
        IYieldDistributor yieldDistributor;
        uint256 lockPeriod;
        uint256 totalStaked;
        mapping(address => uint256) stakedBalance;
        mapping(address => uint256) lockExpiry;
    }

    function _storage() private pure returns (StakingVaultStorage storage $) {
        assembly {
            $.slot := 0xa3f5c8b2e1d4f7a6b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f200
        }
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ─────────────────────────────────────────────────────────
    function initialize(
        address admin,
        address dktTokenAddr,
        address yieldDistributorAddr,
        uint256 initialLockPeriod
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (dktTokenAddr == address(0)) revert ZeroAddress();
        if (yieldDistributorAddr == address(0)) revert ZeroAddress();
        if (initialLockPeriod > 365 days) revert LockPeriodTooLong(initialLockPeriod, 365 days);

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VAULT_ADMIN_ROLE, admin);

        StakingVaultStorage storage $ = _storage();
        $.dkt = IERC20(dktTokenAddr);
        $.yieldDistributor = IYieldDistributor(yieldDistributorAddr);
        $.lockPeriod = initialLockPeriod;
    }

    // ─── Core: Stake ──────────────────────────────────────────────────────────
    /**
     * @notice Stake DKT tokens with a yield-split configuration.
     * @param  amount        DKT amount to stake (18 decimals)
     * @param  targetProject ResearchProject address to receive donated yield.
     *                       Pass address(0) if donateBps == 0 (no donation).
     * @param  donateBps     Basis points (0–10_000) of yield to donate to the project.
     *                       0     = 100% yield returned to staker
     *                       5000  = 50% to project, 50% to staker
     *                       10000 = 100% to project
     *
     * @dev If donateBps > 0, targetProject must be non-zero.
     *      The split is forwarded to YieldDistributor and locked until unstake.
     */
    function stake(uint256 amount, address targetProject, uint16 donateBps) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (donateBps > 10_000) revert InvalidDonateBps(donateBps);
        if (donateBps > 0 && targetProject == address(0)) revert ProjectRequiredForDonation();

        StakingVaultStorage storage $ = _storage();

        $.dkt.safeTransferFrom(msg.sender, address(this), amount);

        $.stakedBalance[msg.sender] += amount;
        $.totalStaked += amount;
        uint256 expiry = block.timestamp + $.lockPeriod;
        $.lockExpiry[msg.sender] = expiry;

        // Notify YieldDistributor with split config (external call — after state updates)
        $.yieldDistributor.notifyStake(msg.sender, amount, targetProject, donateBps);

        emit Staked(msg.sender, amount, $.stakedBalance[msg.sender], expiry, targetProject, donateBps, block.number);
    }

    // ─── Core: Unstake ───────────────────────────────────────────────────────
    /**
     * @notice Unstake DKT tokens. Reverts if still within lock period.
     * @dev    Does NOT auto-claim yield — user must call YieldDistributor.claimYield().
     *         Clears the yield-split config when balance reaches zero.
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakingVaultStorage storage $ = _storage();

        uint256 balance = $.stakedBalance[msg.sender];
        if (amount > balance) revert InsufficientStake(amount, balance);

        uint256 expiry = $.lockExpiry[msg.sender];
        if (block.timestamp < expiry) revert StillLocked(expiry, block.timestamp);

        unchecked {
            $.stakedBalance[msg.sender] = balance - amount;
            $.totalStaked -= amount;
        }

        $.yieldDistributor.notifyUnstake(msg.sender, amount);

        $.dkt.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, $.stakedBalance[msg.sender], block.number);
    }

    // ─── Admin: Configuration ─────────────────────────────────────────────────
    function setLockPeriod(uint256 newPeriod) external onlyRole(VAULT_ADMIN_ROLE) {
        if (newPeriod > 365 days) revert LockPeriodTooLong(newPeriod, 365 days);
        StakingVaultStorage storage $ = _storage();
        uint256 old = $.lockPeriod;
        $.lockPeriod = newPeriod;
        emit LockPeriodUpdated(old, newPeriod);
    }

    function setYieldDistributor(address newDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDistributor == address(0)) revert ZeroAddress();
        StakingVaultStorage storage $ = _storage();
        address old = address($.yieldDistributor);
        $.yieldDistributor = IYieldDistributor(newDistributor);
        emit YieldDistributorUpdated(old, newDistributor);
    }

    // ─── View functions ───────────────────────────────────────────────────────
    function stakedBalance(address user) external view returns (uint256) {
        return _storage().stakedBalance[user];
    }

    function lockExpiry(address user) external view returns (uint256) {
        return _storage().lockExpiry[user];
    }

    function totalStaked() external view returns (uint256) {
        return _storage().totalStaked;
    }

    function lockPeriod() external view returns (uint256) {
        return _storage().lockPeriod;
    }

    function dktToken() external view returns (address) {
        return address(_storage().dkt);
    }

    function yieldDistributor() external view returns (address) {
        return address(_storage().yieldDistributor);
    }

    // ─── UUPS ─────────────────────────────────────────────────────────────────
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
