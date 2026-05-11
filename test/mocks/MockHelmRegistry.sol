// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHelmRegistry} from "../../src/interfaces/IHelmRegistry.sol";

/// @title MockHelmRegistry
/// @notice Minimal mock that returns pre-set deployment info.
contract MockHelmRegistry {
    mapping(uint256 => IHelmRegistry.AgentDeployment) private _deployments;

    function setDeployment(uint256 agentId, IHelmRegistry.AgentDeployment memory d) external {
        _deployments[agentId] = d;
    }

    function deploymentOf(uint256 agentId) external view returns (IHelmRegistry.AgentDeployment memory) {
        return _deployments[agentId];
    }
}
