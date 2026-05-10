// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYieldHarvester
/// @notice Pulls *cash yield* from positions (mETH staking rewards, USDY interest, Init
///         lending interest, Pendle PT yield) and deposits the USDC into the agent's
///         vault yield pool.
/// @dev    Capital gains (e.g. sNVDA appreciation) are NOT harvested — they remain in NAV
///         and accrue to share price. Triggered monthly by the BE cron.
interface IYieldHarvester {
    event YieldHarvested(uint256 indexed agentId, address indexed source, uint256 amount);
    event SourceRegistered(uint256 indexed agentId, address indexed source, bytes config);
    event SourceRemoved(uint256 indexed agentId, address indexed source);

    error OnlyExecutor();
    error OnlyVault();
    error UnknownSource(address source);

    /// @notice Run harvest across all registered sources for an agent. Called by BE cron.
    /// @return totalUSDC Sum of all USDC harvested into the vault yield pool this call.
    function harvest(uint256 agentId) external returns (uint256 totalUSDC);

    /// @notice Register a yield source for an agent. Called by vault on rebalance into
    ///         a yield-bearing position.
    function registerSource(uint256 agentId, address source, bytes calldata config) external;

    /// @notice Unregister a source (vault rebalanced out of it entirely).
    function removeSource(uint256 agentId, address source) external;

    function lastHarvestAt(uint256 agentId) external view returns (uint64);
    function sourcesOf(uint256 agentId) external view returns (address[] memory);
}
