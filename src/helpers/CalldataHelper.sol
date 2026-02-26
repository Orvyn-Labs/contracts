// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CalldataHelper
 * @notice Remix utility — encodes initialize() calldata for use when deploying
 *         ERC1967Proxy. Deploy this contract, call the relevant function,
 *         copy the `bytes` output, then paste it into the ERC1967Proxy
 *         constructor `_data` field.
 *
 * DELETE or exclude this file before production deployment.
 */
contract CalldataHelper {
    // ── YieldDistributor ─────────────────────────────────────────────────────
    /**
     * @param admin          Your Remix account address
     * @param initialRateWAD 10% APY = 100000000000000000 (0.1e18)
     */
    function encodeYieldDistributorInit(address admin, uint256 initialRateWAD)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "initialize(address,uint256)",
            admin,
            initialRateWAD
        );
    }

    // ── StakingVault ──────────────────────────────────────────────────────────
    /**
     * @param admin               Your Remix account address
     * @param dktTokenAddr        DiktiToken deployed address
     * @param yieldDistributorAddr YieldDistributor PROXY address
     * @param initialLockPeriod   0 for Remix testing (no lock)
     */
    function encodeStakingVaultInit(
        address admin,
        address dktTokenAddr,
        address yieldDistributorAddr,
        uint256 initialLockPeriod
    ) external pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            admin,
            dktTokenAddr,
            yieldDistributorAddr,
            initialLockPeriod
        );
    }

    // ── Convenience: pre-filled for common Remix test values ─────────────────
    /**
     * @notice Quick encode for YieldDistributor with 10% APY.
     *         Replace `admin` with your actual address.
     */
    function encodeYieldDistributorInit10pct(address admin)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "initialize(address,uint256)",
            admin,
            100000000000000000  // 0.1e18 = 10% APY
        );
    }

    /**
     * @notice Quick encode for StakingVault with no lock period.
     */
    function encodeStakingVaultInitNoLock(
        address admin,
        address dktTokenAddr,
        address yieldDistributorProxyAddr
    ) external pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            admin,
            dktTokenAddr,
            yieldDistributorProxyAddr,
            0   // no lock period for testing
        );
    }
}
