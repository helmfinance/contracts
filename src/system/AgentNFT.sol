// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title AgentNFT
/// @notice Singleton ERC-721 representing each Helm agent's permanent on-chain
///         identity and reputation, compatible with the ERC-8004 spec.
///         tokenId == agentId from HelmRegistry. Transferring the NFT
///         transfers the reputation with it.
/// @dev Only HelmRegistry may mint; HelmRegistry *or* admin may slash and
///      update tokenURI. The contract is intentionally a singleton (not
///      cloneable) because the reputation surface is system-wide.
contract AgentNFT is ERC721 {
    /// @notice Reputation upper bound and the initial score for every mint.
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Reputation score in basis points (0-10000).
    mapping(uint256 => uint256) public reputationScore;

    /// @notice Number of times each agent has been slashed.
    mapping(uint256 => uint256) public slashCount;

    /// @notice Timestamp of the most recent slash; 0 if never slashed.
    mapping(uint256 => uint256) public lastSlashAt;

    /// @dev Per-agent IPFS / off-chain metadata URI.
    mapping(uint256 => string) internal _tokenURIs;

    /// @notice The HelmRegistry contract.
    address public immutable registry;

    /// @notice Admin / owner (transferable via {transferAdmin}).
    address public admin;

    /// @notice Reputation below this threshold signals a wind-down condition.
    ///         Other system components (the registry, BE indexer) react to the
    ///         `SlashTriggeredWindDown` event rather than reading this state.
    uint256 public windDownThreshold = 5_000;

    error NotRegistry();
    error NotAdmin();
    error NotRegistryOrAdmin();
    error AgentNotFound();
    error InvalidSlashAmount();
    error AlreadyMinted();

    event AgentNFTMinted(uint256 indexed agentId, address indexed founder, uint256 initialReputation);
    event ReputationSlashed(
        uint256 indexed agentId,
        uint256 beforeScore,
        uint256 afterScore,
        uint256 amountBps,
        string  reason
    );
    event SlashTriggeredWindDown(uint256 indexed agentId, uint256 finalScore);
    event TokenURISet(uint256 indexed agentId, string newURI);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }
    modifier onlyRegistryOrAdmin() {
        if (msg.sender != registry && msg.sender != admin) revert NotRegistryOrAdmin();
        _;
    }

    /// @param registry_ HelmRegistry contract; only it may mint NFTs.
    /// @param admin_ Initial admin (typically the deployer).
    constructor(address registry_, address admin_)
        ERC721("Helm Agent Identity", "HELM-AGENT")
    {
        registry = registry_;
        admin = admin_;
    }

    // ─── mutating ───────────────────────────────────────────────────

    /// @notice Mint the identity NFT for a freshly-registered agent.
    /// @param agentId The agent ID assigned by HelmRegistry.
    /// @param founder Recipient of the NFT (the agent's founder).
    function mint(uint256 agentId, address founder) external onlyRegistry {
        if (_ownerOf(agentId) != address(0)) revert AlreadyMinted();
        _safeMint(founder, agentId);
        reputationScore[agentId] = MAX_BPS;
        emit AgentNFTMinted(agentId, founder, MAX_BPS);
    }

    /// @notice Reduce an agent's reputation. Saturates at 0.
    /// @param agentId The agent whose NFT is being slashed.
    /// @param amountBps Basis points to deduct (1-10000).
    /// @param reason Short tag — e.g. "mandate_breach", "wind_down".
    function slash(uint256 agentId, uint256 amountBps, string calldata reason)
        external
        onlyRegistryOrAdmin
    {
        if (amountBps == 0 || amountBps > MAX_BPS) revert InvalidSlashAmount();
        if (_ownerOf(agentId) == address(0)) revert AgentNotFound();

        uint256 beforeScore = reputationScore[agentId];
        uint256 afterScore = beforeScore > amountBps ? beforeScore - amountBps : 0;

        reputationScore[agentId] = afterScore;
        slashCount[agentId] += 1;
        lastSlashAt[agentId] = block.timestamp;

        emit ReputationSlashed(agentId, beforeScore, afterScore, amountBps, reason);
        if (afterScore < windDownThreshold && beforeScore >= windDownThreshold) {
            emit SlashTriggeredWindDown(agentId, afterScore);
        }
    }

    /// @notice Update the off-chain metadata URI for an agent.
    function setTokenURI(uint256 agentId, string calldata newURI)
        external
        onlyRegistryOrAdmin
    {
        if (_ownerOf(agentId) == address(0)) revert AgentNotFound();
        _tokenURIs[agentId] = newURI;
        emit TokenURISet(agentId, newURI);
    }

    /// @notice Transfer admin authority to a new address.
    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc ERC721
    function tokenURI(uint256 agentId) public view override returns (string memory) {
        if (_ownerOf(agentId) == address(0)) revert AgentNotFound();
        return _tokenURIs[agentId];
    }

    /// @notice Reputation score of an agent in basis points.
    function reputationOf(uint256 agentId) external view returns (uint256) {
        return reputationScore[agentId];
    }

    /// @notice True iff the agent's reputation is at or above the wind-down threshold.
    function isHealthy(uint256 agentId) external view returns (bool) {
        return reputationScore[agentId] >= windDownThreshold;
    }

    /// @notice Aggregate slash metadata for an agent.
    function slashInfoOf(uint256 agentId) external view returns (uint256 count, uint256 lastAt) {
        return (slashCount[agentId], lastSlashAt[agentId]);
    }
}
