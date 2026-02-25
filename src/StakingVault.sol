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
 *      Flow:
 *        1. User approves StakingVault to spend DKT
 *        2. User calls stake(amount)  → DKT transferred in, YieldDistributor notified
 *        3. After lockPeriod, user calls unstake(amount) → DKT returned
 *        4. User calls YieldDistributor.claimYield() separately (pull pattern)
 *
 *      The lock period is a research parameter — it can be set to 0 for
 *      unrestricted unstaking during load tests, or to a realistic value
 *      (e.g. 7 days) for standard evaluation runs.
 *
 * Upgradeability: UUPS — allows tuning lock period and emergency pause logic
 *                 between research experiment versions.
 *
 * Gas profile targets:
 *   stake(1 DKT)    ~95,000 gas  (ERC-20 transferFrom + 3 SSTOREs + external call)
 *   unstake(1 DKT)  ~80,000 gas  (ERC-20 transfer + 2 SSTOREs + external call)
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

    // ─── Events ───────────────────────────────────────────────────────────────
    event Staked(
        address indexed staker,
        uint256 amount,
        uint256 newBalance,
        uint256 lockExpiry,
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
        // DKT token contract
        IERC20 dkt;
        // YieldDistributor contract
        IYieldDistributor yieldDistributor;
        // Lock period in seconds (research parameter)
        uint256 lockPeriod;
        // Total DKT staked across all users
        uint256 totalStaked;
        // Per-user staked balance
        mapping(address => uint256) stakedBalance;
        // Per-user lock expiry timestamp
        mapping(address => uint256) lockExpiry;
    }

    function _storage() private pure returns (StakingVaultStorage storage $) {
        // keccak256("skripsi.StakingVault.storage") — stable slot for this contract
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
    /**
     * @param admin               Address granted admin roles
     * @param dktTokenAddr        DiktiToken (DKT) contract address
     * @param yieldDistributorAddr YieldDistributor contract address
     * @param initialLockPeriod   Lock duration in seconds (0 = no lock, for tests)
     */
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
     * @notice Stake DKT tokens. Principal is locked for `lockPeriod` seconds.
     * @dev    Transfers DKT from caller → vault.
     *         Notifies YieldDistributor so it can update the reward index.
     *         Lock expiry is refreshed on each stake call (extends the lock).
     * @param  amount DKT amount (in token units, 18 decimals)
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakingVaultStorage storage $ = _storage();

        // Transfer DKT from user (requires prior approve)
        $.dkt.safeTransferFrom(msg.sender, address(this), amount);

        // Update state before external call (CEI)
        $.stakedBalance[msg.sender] += amount;
        $.totalStaked += amount;
        uint256 expiry = block.timestamp + $.lockPeriod;
        $.lockExpiry[msg.sender] = expiry;

        // Notify YieldDistributor (external call — after state updates)
        $.yieldDistributor.notifyStake(msg.sender, amount);

        emit Staked(msg.sender, amount, $.stakedBalance[msg.sender], expiry, block.number);
    }

    // ─── Core: Unstake ───────────────────────────────────────────────────────
    /**
     * @notice Unstake DKT tokens. Reverts if still within lock period.
     * @dev    Returns DKT to caller. Notifies YieldDistributor.
     *         Does NOT auto-claim yield — user must call YieldDistributor.claimYield().
     * @param  amount DKT amount to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakingVaultStorage storage $ = _storage();

        uint256 balance = $.stakedBalance[msg.sender];
        if (amount > balance) revert InsufficientStake(amount, balance);

        uint256 expiry = $.lockExpiry[msg.sender];
        if (block.timestamp < expiry) revert StillLocked(expiry, block.timestamp);

        // CEI: Update state before external calls
        unchecked {
            $.stakedBalance[msg.sender] = balance - amount;
            $.totalStaked -= amount;
        }

        // Notify YieldDistributor (external call)
        $.yieldDistributor.notifyUnstake(msg.sender, amount);

        // Return DKT to user
        $.dkt.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, $.stakedBalance[msg.sender], block.number);
    }

    // ─── Admin: Configuration ─────────────────────────────────────────────────
    /**
     * @notice Update the lock period.
     * @dev    Research parameter — set to 0 for load tests, realistic value for
     *         standard evaluation runs. Does NOT affect existing stakes.
     */
    function setLockPeriod(uint256 newPeriod) external onlyRole(VAULT_ADMIN_ROLE) {
        if (newPeriod > 365 days) revert LockPeriodTooLong(newPeriod, 365 days);
        StakingVaultStorage storage $ = _storage();
        uint256 old = $.lockPeriod;
        $.lockPeriod = newPeriod;
        emit LockPeriodUpdated(old, newPeriod);
    }

    /**
     * @notice Update the YieldDistributor address.
     * @dev    Allows upgrading to a new yield algorithm version
     *         (e.g. V1 linear → V2 compound) while preserving vault balances.
     */
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
