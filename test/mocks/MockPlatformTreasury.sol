// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPlatformTreasury} from "../../src/interfaces/IPlatformTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockPlatformTreasury
/// @notice Minimal mock for testing AgentVault fee flows.
contract MockPlatformTreasury is IPlatformTreasury {
    mapping(FeeKind => uint256) private _feeRates;
    uint256 public override totalFeesCollected;
    mapping(uint256 => uint256) private _feesPerAgent;

    function setFeeRate(FeeKind kind, uint256 newBps) external override {
        _feeRates[kind] = newBps;
    }

    function feeRate(FeeKind kind) external view override returns (uint256) {
        return _feeRates[kind];
    }

    function collectFee(uint256 agentId, FeeKind kind, uint256 amount) external override {
        totalFeesCollected += amount;
        _feesPerAgent[agentId] += amount;
        emit FeeCollected(agentId, kind, amount);
    }

    function withdraw(address, uint256) external pure override {
        revert("not implemented");
    }

    function feesCollectedFor(uint256 agentId) external view override returns (uint256) {
        return _feesPerAgent[agentId];
    }
}
