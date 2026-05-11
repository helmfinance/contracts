// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentVault} from "./IAgentVault.sol";

/// @title IHelmRegistry
/// @notice Factory + lifecycle gate. On `registerAgent`, deploys the four core contracts
///         (NFT, Token, Vault, FounderVault) and runs the vetting state machine:
///         Incubation → PublicLaunch → (optionally WindDown / Slashed) → Settled.
/// @dev Singleton. Only deployer can advance phases or slash.
interface IHelmRegistry {
    enum Phase {
        Incubation,    // 30-day vetting window, founder-only deposits allowed
        PublicLaunch,  // open to outside capital
        WindDown,      // selling positions to USDC
        Slashed,       // failed vetting / reputation slash
        Settled        // fully wound down, claims open
    }

    struct AgentDeployment {
        uint256 agentId;
        address nft;
        address token;
        address vault;
        address founderVault;
        address founder;
        Phase   phase;
        uint64  incubationStart;
        uint64  publicLaunchAt;
    }

    event AgentRegistered(uint256 indexed agentId, address indexed founder, AgentDeployment deployment);
    event PhaseAdvanced(uint256 indexed agentId, Phase from, Phase to);
    event AgentSlashed(uint256 indexed agentId, string reason);

    error OnlyAdmin();
    error InvalidPhaseTransition(Phase from, Phase to);
    error IncubationStillActive(uint64 endsAt);
    error MandateInvalid();
    error InsufficientSeed();

    /// @notice Create a new agent. Deploys the 4 core contracts, mints NFT, seeds founder
    ///         allocation, and whitelists the mandate's tradeable assets on the vault.
    ///         Caller becomes the founder.
    /// @param mandateHash keccak256 of canonical JSON mandate (BE Claude parser produces it)
    /// @param mandateURI off-chain URI (IPFS preferred)
    /// @param seedUSDC initial founder seed (transferred from caller via permit / approve)
    /// @param assets List of tradeable assets the agent's vault may hold. Empty
    ///        list means the vault is cash-only (no rebalancing into positions).
    /// @param weightConstraints Per-asset min/max NAV weight bounds (basis points). Each
    ///        entry's `asset` must also appear in `assets`.
    function registerAgent(
        bytes32 mandateHash,
        string calldata mandateURI,
        uint256 seedUSDC,
        IAgentVault.AssetEntry[] calldata assets,
        IAgentVault.WeightConstraint[] calldata weightConstraints
    ) external returns (uint256 agentId);

    /// @notice Advance from Incubation → PublicLaunch after the 30-day vetting passes.
    ///         Admin-only for v1; on-chain rule check in later versions.
    function advanceToPublic(uint256 agentId) external;

    /// @notice Force into Slashed (reputation slash, failed manual review).
    function slash(uint256 agentId, string calldata reason) external;

    function deploymentOf(uint256 agentId) external view returns (AgentDeployment memory);
    function phaseOf(uint256 agentId) external view returns (Phase);
    function agentCount() external view returns (uint256);
}
