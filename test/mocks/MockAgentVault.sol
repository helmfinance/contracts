// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockAgentVault
/// @notice Minimal mock to verify FounderVault → AgentVault.triggerWindDown calls.
contract MockAgentVault {
    bool public windDownTriggered;
    string public windDownReason;

    function triggerWindDown(string calldata reason) external {
        windDownTriggered = true;
        windDownReason = reason;
    }
}
