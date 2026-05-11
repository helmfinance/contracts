// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldHarvester} from "../interfaces/IYieldHarvester.sol";
import {IAgentVault} from "../interfaces/IAgentVault.sol";
import {IHelmRegistry} from "../interfaces/IHelmRegistry.sol";
import {IMantleMETHAdapter} from "../interfaces/IMantleMETHAdapter.sol";
import {IOndoUSDYAdapter} from "../interfaces/IOndoUSDYAdapter.sol";

/// @title YieldHarvester
/// @notice Pulls cash yield from yield-bearing adapters (mETH, USDY) across agent
///         vaults and deposits the harvested USDC into the vault's yield pool.
contract YieldHarvester is IYieldHarvester, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable executor;
    IHelmRegistry public immutable registry;
    IERC20 public immutable usdc;

    /// @dev agentId → list of yield sources
    mapping(uint256 => address[]) internal _sources;
    /// @dev agentId → source → index+1 (0 = not registered)
    mapping(uint256 => mapping(address => uint256)) internal _sourceIndex;
    /// @dev agentId → last harvest timestamp
    mapping(uint256 => uint64) internal _lastHarvest;

    /// @param executor_ BE cron signer (also allowed to register/remove sources).
    /// @param registry_ HelmRegistry for agent lookups.
    /// @param usdc_ USDC token address.
    constructor(address executor_, address registry_, address usdc_) {
        executor = executor_;
        registry = IHelmRegistry(registry_);
        usdc = IERC20(usdc_);
    }

    // ─── IYieldHarvester ────────────────────────────────────────────

    /// @inheritdoc IYieldHarvester
    function harvest(uint256 agentId)
        external
        override
        nonReentrant
        returns (uint256 totalUSDC)
    {
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        address vault_ = d.vault;
        address[] storage srcs = _sources[agentId];

        for (uint256 i = 0; i < srcs.length; i++) {
            uint256 harvested = _harvestSource(srcs[i], vault_);
            if (harvested > 0) {
                totalUSDC += harvested;
                emit YieldHarvested(agentId, srcs[i], harvested);
            }
        }

        if (totalUSDC > 0) {
            usdc.forceApprove(vault_, totalUSDC);
            IAgentVault(vault_).depositYield(totalUSDC);
        }

        _lastHarvest[agentId] = uint64(block.timestamp);
    }

    /// @inheritdoc IYieldHarvester
    function registerSource(uint256 agentId, address source, bytes calldata config) external override {
        if (msg.sender != executor) revert OnlyExecutor();
        if (_sourceIndex[agentId][source] != 0) return; // already registered
        _sources[agentId].push(source);
        _sourceIndex[agentId][source] = _sources[agentId].length; // 1-indexed
        emit SourceRegistered(agentId, source, config);
    }

    /// @inheritdoc IYieldHarvester
    function removeSource(uint256 agentId, address source) external override {
        if (msg.sender != executor) revert OnlyExecutor();
        uint256 idx1 = _sourceIndex[agentId][source];
        if (idx1 == 0) revert UnknownSource(source);
        uint256 lastIdx = _sources[agentId].length - 1;
        uint256 idx = idx1 - 1;
        if (idx != lastIdx) {
            address last = _sources[agentId][lastIdx];
            _sources[agentId][idx] = last;
            _sourceIndex[agentId][last] = idx1;
        }
        _sources[agentId].pop();
        delete _sourceIndex[agentId][source];
        emit SourceRemoved(agentId, source);
    }

    /// @inheritdoc IYieldHarvester
    function lastHarvestAt(uint256 agentId) external view override returns (uint64) {
        return _lastHarvest[agentId];
    }

    /// @inheritdoc IYieldHarvester
    function sourcesOf(uint256 agentId) external view override returns (address[] memory) {
        return _sources[agentId];
    }

    // ─── internal ───────────────────────────────────────────────────

    /// @dev Call harvestYield on an adapter. Adapters send USDC to this contract.
    function _harvestSource(address source, address vault_) internal returns (uint256) {
        // Try IMantleMETHAdapter first, then IOndoUSDYAdapter.
        // Both have the same harvestYield(address) → uint256 signature.
        // We use a low-level call to handle either.
        (bool ok, bytes memory ret) = source.call(
            abi.encodeWithSignature("harvestYield(address)", vault_)
        );
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}
