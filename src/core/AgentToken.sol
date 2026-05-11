// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";

/// @title AgentToken
/// @notice ERC-20 share token for a single agent vault. Mint/burn restricted to vault.
contract AgentToken is ERC20, IAgentToken {
    /// @notice The agent vault that controls minting and burning.
    address public immutable override vault;

    /// @notice The agent ID this token belongs to.
    uint256 public immutable override agentId;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @param name_ Token name (e.g. "Agent 1 Shares").
    /// @param symbol_ Token symbol (e.g. "AGT-1").
    /// @param vault_ Address of the AgentVault that may mint/burn.
    /// @param agentId_ The agent identifier.
    constructor(
        string memory name_,
        string memory symbol_,
        address vault_,
        uint256 agentId_
    ) ERC20(name_, symbol_) {
        vault = vault_;
        agentId = agentId_;
    }

    /// @inheritdoc IAgentToken
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit MintedByVault(to, amount);
    }

    /// @inheritdoc IAgentToken
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
        emit BurnedByVault(from, amount);
    }
}
