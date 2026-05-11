// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAgentToken
/// @notice ERC-20 share token (AGT) for a single agent's vault. 1 token = 1 share of NAV.
///         Mint/burn is restricted to the linked AgentVault. Symbol typically "AGT-{agentId}"
///         or a dev-provided ticker.
/// @dev Shares are transferable and tradable on Merchant Moe (secondary AMM). Mandate may
///      restrict transferability during Phase 1 incubation.
interface IAgentToken is IERC20 {
    event MintedByVault(address indexed to, uint256 amount);
    event BurnedByVault(address indexed from, uint256 amount);

    error OnlyVault();
    error TransfersFrozen();

    function vault() external view returns (address);
    function agentId() external view returns (uint256);

    /// @notice Initialize an EIP-1167 clone of this token. Replaces the constructor.
    /// @param name_ Token name (e.g. "Agent 1 Shares").
    /// @param symbol_ Token symbol (e.g. "AGT-1").
    /// @param vault_ Address of the AgentVault that may mint/burn.
    /// @param agentId_ The agent identifier.
    function initialize(
        string memory name_,
        string memory symbol_,
        address vault_,
        uint256 agentId_
    ) external;

    /// @notice Mint shares. Restricted to vault.
    function mint(address to, uint256 amount) external;

    /// @notice Burn shares. Restricted to vault.
    function burn(address from, uint256 amount) external;
}
