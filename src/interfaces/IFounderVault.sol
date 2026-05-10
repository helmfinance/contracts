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
    function isSubordinationActive() external view returns (bool);

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
