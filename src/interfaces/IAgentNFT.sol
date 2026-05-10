// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentNFT
/// @notice ERC-8004 identity NFT for a Helm AI agent. Each agent has exactly one NFT;
///         token ID == agentId throughout the system. Stores the mandate hash, decision
///         log merkle root, reputation score, and links to the agent's vault + founder.
/// @dev Mint is restricted to HelmRegistry. Reputation/decision-log updates are restricted
///      to the registry or a designated reporter (yield harvester, slasher).
interface IAgentNFT {
    struct AgentMetadata {
        address founder;
        address vault;
        bytes32 mandateHash;        // keccak256(canonical JSON mandate)
        string  mandateURI;         // ipfs://... or arweave://...
        bytes32 decisionLogRoot;    // updated periodically by indexer
        int256  reputation;
        uint64  createdAt;
    }

    event AgentMinted(uint256 indexed agentId, address indexed founder, address vault, bytes32 mandateHash);
    event MandateUpdated(uint256 indexed agentId, bytes32 newMandateHash, string newURI);
    event DecisionLogUpdated(uint256 indexed agentId, bytes32 newRoot);
    event ReputationAdjusted(uint256 indexed agentId, int256 delta, int256 newScore);

    error OnlyRegistry();
    error OnlyReporter();
    error AgentNotFound(uint256 agentId);
    error MandateLockedAfterIncubation();

    /// @notice Mint a new agent identity NFT. Restricted to HelmRegistry.
    /// @return agentId The newly minted token ID.
    function mint(
        address founder,
        address vault,
        bytes32 mandateHash,
        string calldata mandateURI
    ) external returns (uint256 agentId);

    /// @notice Replace mandate. Allowed only during the Incubation phase.
    function updateMandate(uint256 agentId, bytes32 newHash, string calldata newURI) external;

    /// @notice Append latest decision-log merkle root. Called by the registry-approved reporter.
    function updateDecisionLog(uint256 agentId, bytes32 newRoot) external;

    /// @notice Adjust reputation. Positive on successful payouts, negative on slashes.
    function adjustReputation(uint256 agentId, int256 delta) external;

    function metadataOf(uint256 agentId) external view returns (AgentMetadata memory);
    function reputationOf(uint256 agentId) external view returns (int256);
    function vaultOf(uint256 agentId) external view returns (address);
}
