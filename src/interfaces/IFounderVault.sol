// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFounderVault
/// @notice Holds the founder's allocation of AgentToken (junior tranche) under
///         subordination rules. Two roles:
///           1. Lockup: shares cannot be withdrawn for `LOCKUP_DURATION` (default 6 months).
///           2. Carry receiver: receives 10% of every dividend distribution as USDC.
///         On wind-down, founder is paid AFTER senior holders are made whole.
/// @dev Excessive founder withdrawals signal lost confidence; crossing a threshold
///      automatically triggers AgentVault.triggerWindDown.
interface IFounderVault {
    event SharesDeposited(address indexed founder, uint256 amount);
    event SharesWithdrawn(address indexed founder, uint256 amount);
    event CarryReceived(uint256 amount);
    event CarryClaimed(address indexed founder, uint256 amount);
    event SubordinationTriggered(uint256 withdrawnRatioBps);

    error LockupActive(uint64 unlockAt);
    error OnlyVault();
    error OnlyDistributor();
    error OnlyFounder();
    error NothingToClaim();

    function agentId() external view returns (uint256);
    function vault() external view returns (address);
    function founder() external view returns (address);
    function lockupEndsAt() external view returns (uint64);
    function totalSharesHeld() external view returns (uint256);
    function carryBalance() external view returns (uint256);
    function subordinationThresholdBps() external view returns (uint16);
    function isSubordinationActive() external view returns (bool);

    /// @notice Initialize an EIP-1167 clone of this founder vault. Replaces the constructor.
    /// @param agentId_ The agent identifier.
    /// @param agentToken_ The AGT share token address.
    /// @param vault_ The linked AgentVault address.
    /// @param founder_ The founder address.
    /// @param usdc_ USDC token address.
    /// @param distributor_ DividendDistributor address (may call receiveCarry).
    /// @param lockupDays_ Founder lockup duration in days (minimum 90).
    /// @param subordinationThresholdBps_ Max cumulative withdrawal ratio before wind-down.
    /// @param carryBps_ Must be exactly 1000 (10%).
    /// @param founderShareBps_ Must be in [500, 3000].
    function initialize(
        uint256 agentId_,
        address agentToken_,
        address vault_,
        address founder_,
        address usdc_,
        address distributor_,
        uint64 lockupDays_,
        uint16 subordinationThresholdBps_,
        uint16 carryBps_,
        uint16 founderShareBps_
    ) external;

    /// @notice Receive founder's initial share allocation. Restricted to AgentVault on first mint.
    function depositFounderShares(uint256 amount) external;

    /// @notice Founder withdraws unlocked shares (only after `lockupEndsAt`). Cumulative
    ///         withdrawals over the subordination threshold trigger wind-down.
    function withdraw(uint256 amount) external;

    /// @notice Receive 10% dev carry as USDC. Called by DividendDistributor.
    function receiveCarry(uint256 amount) external;

    /// @notice Founder claims accumulated USDC carry.
    function claimCarry() external returns (uint256 amount);
}
