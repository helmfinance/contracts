// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPlatformTreasury
/// @notice Collects platform fees (mint / redeem / rebalance) from all agent vaults.
///         Singleton owned by Helm. Fees are accrued in USDC.
interface IPlatformTreasury {
    enum FeeKind {
        Mint,       // skim on user deposit
        Redeem,     // skim on user redemption claim
        Rebalance   // skim per executed rebalance
    }

    event FeeCollected(uint256 indexed agentId, FeeKind kind, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event FeeRateUpdated(FeeKind kind, uint256 oldBps, uint256 newBps);

    error OnlyAdmin();
    error OnlyRegisteredVault();
    error FeeRateTooHigh(uint256 maxBps);

    /// @notice Skim a fee from a registered agent vault. Only called by AgentVault.
    function collectFee(uint256 agentId, FeeKind kind, uint256 amount) external;

    /// @notice Admin withdraws accumulated fees.
    function withdraw(address to, uint256 amount) external;

    /// @notice Update fee rate (basis points). Bounded by `maxFeeBps`.
    function setFeeRate(FeeKind kind, uint256 newBps) external;

    function feeRate(FeeKind kind) external view returns (uint256 bps);
    function totalFeesCollected() external view returns (uint256);
    function feesCollectedFor(uint256 agentId) external view returns (uint256);
}
