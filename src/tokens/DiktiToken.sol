// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title DiktiToken (DKT)
 * @notice Platform utility token for the research crowdfunding dApp.
 *         Used for staking to generate simulated yield that funds research projects.
 *
 * @dev Complexity Level 1 — baseline ERC-20 transaction.
 *      Minting is permissioned via MINTER_ROLE so the test environment
 *      can distribute tokens to research participants without a faucet UI.
 *
 * Gas profile target:
 *   mint()      ~51,000 gas  (zero→nonzero SSTORE)
 *   transfer()  ~29,000 gas  (nonzero→nonzero SSTORE x2)
 *   approve()   ~24,000 gas  (nonzero→nonzero SSTORE)
 */
contract DiktiToken is ERC20, ERC20Permit, AccessControl {
    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ─── Supply cap ───────────────────────────────────────────────────────────
    /// @notice Hard cap: 1 billion DKT (18 decimals)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    // ─── Errors ───────────────────────────────────────────────────────────────
    error ExceedsMaxSupply(uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroAmount();

    // ─── Events ───────────────────────────────────────────────────────────────
    /// @notice Emitted on every mint for off-chain indexing
    event TokensMinted(address indexed to, uint256 amount, uint256 newTotalSupply);

    // ─── Constructor ──────────────────────────────────────────────────────────
    /**
     * @param admin  Address that receives DEFAULT_ADMIN_ROLE and MINTER_ROLE.
     *               In production this should be a multisig; in tests use deployer.
     */
    constructor(address admin) ERC20("Dikti Token", "DKT") ERC20Permit("Dikti Token") {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    // ─── Minting ─────────────────────────────────────────────────────────────
    /**
     * @notice Mint DKT to a recipient.
     * @dev    Only callable by addresses with MINTER_ROLE.
     *         Used by test scripts and the StakingVault admin to distribute tokens.
     * @param  to     Recipient address
     * @param  amount Amount in token units (18 decimals)
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available = MAX_SUPPLY - totalSupply();
        if (amount > available) revert ExceedsMaxSupply(amount, available);

        _mint(to, amount);
        emit TokensMinted(to, amount, totalSupply());
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    /// @notice Remaining mintable supply
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
}
