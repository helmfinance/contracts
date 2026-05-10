// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDividendDistributor
/// @notice Monthly distribution of vault yield pool: 90% to AGT holders, 10% to FounderVault
///         as dev carry. Snapshot of holder balances is taken at distribution time.
///         Holders claim individually (gas-efficient — vault pays only on claim).
/// @dev    Singleton. Triggered by BE monthly cron.
interface IDividendDistributor {
    event Distributed(
        uint256 indexed agentId,
        uint256 indexed epoch,
        uint256 totalAmount,
        uint256 holdersShare,   // 90%
        uint256 carryShare,     // 10%
        bytes32 snapshotRoot    // optional merkle root of holder balances at snapshot
    );
    event Claimed(uint256 indexed agentId, address indexed holder, uint256 indexed epoch, uint256 amount);

    error OnlyExecutor();
    error EmptyYieldPool();
    error AlreadyClaimed(uint256 agentId, uint256 epoch, address holder);
    error EpochNotFinalized(uint256 agentId, uint256 epoch);

    /// @notice Pull 90/10 from vault yield pool, snapshot holders, mark epoch claimable.
    ///         The 10% carry is sent immediately to FounderVault.receiveCarry.
    /// @return epoch The epoch number assigned to this distribution.
    function distribute(uint256 agentId) external returns (uint256 epoch);

    /// @notice Holder claims pro-rata USDC for one or more past epochs.
    function claim(uint256 agentId, uint256[] calldata epochs) external returns (uint256 totalUSDC);

    function epochOf(uint256 agentId) external view returns (uint256);
    function pendingClaimOf(uint256 agentId, address holder) external view returns (uint256);
    function epochSnapshot(uint256 agentId, uint256 epoch)
        external
        view
        returns (uint256 totalAmount, uint256 holdersShare, uint256 totalSharesAtSnapshot, uint64 timestamp);
}
