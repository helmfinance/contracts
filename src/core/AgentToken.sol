// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";

/// @title AgentToken
/// @notice ERC-20 share token for a single agent vault. Mint/burn restricted to vault.
/// @dev Deployed once as an implementation; per-agent instances are EIP-1167 clones
///      created by HelmRegistry. The implementation's constructor calls
///      `_disableInitializers()` so it cannot itself be initialized.
///      `vault` and `agentId` are regular storage (not immutable) because clones do
///      not execute constructor code; they are set inside {initialize}.
contract AgentToken is ERC20Upgradeable, IAgentToken {
    /// @notice The agent vault that controls minting and burning.
    address public override vault;

    /// @notice The agent ID this token belongs to.
    uint256 public override agentId;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @notice Locks the implementation contract so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IAgentToken
    function initialize(
        string memory name_,
        string memory symbol_,
        address vault_,
        uint256 agentId_
    ) external override initializer {
        __ERC20_init(name_, symbol_);
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
