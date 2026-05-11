// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IHelmRegistry} from "../interfaces/IHelmRegistry.sol";
import {IAgentVault} from "../interfaces/IAgentVault.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";
import {IFounderVault} from "../interfaces/IFounderVault.sol";

/// @title HelmRegistry
/// @notice Singleton factory that deploys agent trios (AgentToken, AgentVault,
///         FounderVault) and tracks each agent's lifecycle phase.
/// @dev Uses EIP-1167 minimal proxy clones of pre-deployed implementations so the
///      registry's runtime bytecode stays well under the 24,576-byte EIP-170 cap.
contract HelmRegistry is IHelmRegistry {
    using SafeERC20 for IERC20;

    uint256 internal constant MIN_SEED_USDC = 1_000e6; // 1000 USDC
    uint64  internal constant INCUBATION_PERIOD = 30 days;

    error AgentNotFound(uint256 agentId);
    error AlreadyAdvanced();
    error IncubationNotComplete(uint64 endsAt);
    error NotVault(uint256 agentId);
    error MandateAlreadyUsed(bytes32 mandateHash);

    // ─── system-wide singletons (set at deploy) ────────────────────

    address public immutable admin;
    address public immutable usdc;
    address public immutable redemptionQueue;
    address public immutable treasury;
    address public immutable yieldHarvester;
    address public immutable pythAdapter;
    address public immutable executor;
    address public immutable distributor;

    // ─── clone implementations (set at deploy) ─────────────────────

    address public immutable agentTokenImpl;
    address public immutable agentVaultImpl;
    address public immutable founderVaultImpl;

    // ─── default mandate params ────────────────────────────────────

    uint64  public defaultLockupDays;
    uint16  public defaultSubordinationBps;
    uint16  public defaultFounderShareBps;

    // ─── agent storage ─────────────────────────────────────────────

    struct AgentRecord {
        address founder;
        address vault;
        address token;
        address founderVault;
        Phase   phase;
        uint64  incubationStart;
        bytes32 mandateHash;
        string  mandateURI;
    }

    /// @dev Transient struct for deploying the trio, avoids stack-too-deep.
    struct DeployResult {
        address token;
        address vault;
        address founderVault;
    }

    mapping(uint256 => AgentRecord) internal _agents;
    mapping(bytes32 => bool) internal _usedMandates;
    uint256 internal _nextAgentId;

    // ─── events ────────────────────────────────────────────────────

    event AgentWindDown(uint256 indexed agentId);
    event AgentSettled(uint256 indexed agentId);

    // ─── constructor ───────────────────────────────────────────────

    struct RegistryParams {
        address admin;
        address usdc;
        address redemptionQueue;
        address treasury;
        address yieldHarvester;
        address pythAdapter;
        address executor;
        address distributor;
        address agentTokenImpl;
        address agentVaultImpl;
        address founderVaultImpl;
        uint64  defaultLockupDays;
        uint16  defaultSubordinationBps;
        uint16  defaultFounderShareBps;
    }

    constructor(RegistryParams memory p) {
        admin = p.admin;
        usdc = p.usdc;
        redemptionQueue = p.redemptionQueue;
        treasury = p.treasury;
        yieldHarvester = p.yieldHarvester;
        pythAdapter = p.pythAdapter;
        executor = p.executor;
        distributor = p.distributor;
        agentTokenImpl = p.agentTokenImpl;
        agentVaultImpl = p.agentVaultImpl;
        founderVaultImpl = p.founderVaultImpl;
        defaultLockupDays = p.defaultLockupDays;
        defaultSubordinationBps = p.defaultSubordinationBps;
        defaultFounderShareBps = p.defaultFounderShareBps;
        _nextAgentId = 1;
    }

    // ─── IHelmRegistry ─────────────────────────────────────────────

    /// @inheritdoc IHelmRegistry
    function registerAgent(
        bytes32 mandateHash,
        string calldata mandateURI,
        uint256 seedUSDC
    ) external override returns (uint256 agentId) {
        if (mandateHash == bytes32(0)) revert MandateInvalid();
        if (bytes(mandateURI).length == 0) revert MandateInvalid();
        if (_usedMandates[mandateHash]) revert MandateAlreadyUsed(mandateHash);
        if (seedUSDC < MIN_SEED_USDC) revert InsufficientSeed();

        _usedMandates[mandateHash] = true;
        agentId = _nextAgentId++;

        DeployResult memory dr = _deployTrio(agentId, msg.sender, mandateHash, mandateURI);

        // Pull seed USDC from founder → deposit into vault
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), seedUSDC);
        IERC20(usdc).forceApprove(dr.vault, seedUSDC);
        IAgentVault(dr.vault).deposit(seedUSDC, dr.founderVault);

        // Record
        _agents[agentId] = AgentRecord({
            founder: msg.sender,
            vault: dr.vault,
            token: dr.token,
            founderVault: dr.founderVault,
            phase: Phase.Incubation,
            incubationStart: uint64(block.timestamp),
            mandateHash: mandateHash,
            mandateURI: mandateURI
        });

        emit AgentRegistered(agentId, msg.sender, AgentDeployment({
            agentId: agentId,
            nft: address(0),
            token: dr.token,
            vault: dr.vault,
            founderVault: dr.founderVault,
            founder: msg.sender,
            phase: Phase.Incubation,
            incubationStart: uint64(block.timestamp),
            publicLaunchAt: 0
        }));
    }

    /// @inheritdoc IHelmRegistry
    function advanceToPublic(uint256 agentId) external override {
        AgentRecord storage a = _agent(agentId);
        if (a.phase != Phase.Incubation) revert AlreadyAdvanced();
        uint64 endsAt = a.incubationStart + INCUBATION_PERIOD;
        if (block.timestamp < endsAt) revert IncubationNotComplete(endsAt);

        a.phase = Phase.PublicLaunch;
        IAgentVault(a.vault).enterPublicLaunch();

        emit PhaseAdvanced(agentId, Phase.Incubation, Phase.PublicLaunch);
    }

    /// @inheritdoc IHelmRegistry
    function slash(uint256 agentId, string calldata reason) external override {
        if (msg.sender != admin) revert OnlyAdmin();
        AgentRecord storage a = _agent(agentId);
        a.phase = Phase.Slashed;
        emit AgentSlashed(agentId, reason);
    }

    /// @notice Called by AgentVault when it enters WindDown.
    /// @param agentId The agent being wound down.
    function markWindDown(uint256 agentId) external {
        AgentRecord storage a = _agent(agentId);
        if (msg.sender != a.vault) revert NotVault(agentId);
        a.phase = Phase.WindDown;
        emit AgentWindDown(agentId);
    }

    /// @notice Called by AgentVault when settlement completes.
    /// @param agentId The agent being settled.
    function markSettled(uint256 agentId) external {
        AgentRecord storage a = _agent(agentId);
        if (msg.sender != a.vault) revert NotVault(agentId);
        a.phase = Phase.Settled;
        emit AgentSettled(agentId);
    }

    // ─── IHelmRegistry views ───────────────────────────────────────

    function deploymentOf(uint256 agentId) external view override returns (AgentDeployment memory) {
        AgentRecord storage a = _agent(agentId);
        return AgentDeployment({
            agentId: agentId,
            nft: address(0),
            token: a.token,
            vault: a.vault,
            founderVault: a.founderVault,
            founder: a.founder,
            phase: a.phase,
            incubationStart: a.incubationStart,
            publicLaunchAt: 0
        });
    }

    function phaseOf(uint256 agentId) external view override returns (Phase) {
        return _agent(agentId).phase;
    }

    function agentCount() external view override returns (uint256) {
        return _nextAgentId - 1;
    }

    // ─── internal: deploy trio ─────────────────────────────────────

    /// @dev Clones the three implementations, then wires them together with their
    ///      `initialize` calls. Each `Clones.clone` is a CREATE call, so the
    ///      addresses are deterministic from this contract's nonce — but we use
    ///      the actual return addresses rather than predicting, which keeps the
    ///      bytecode small and avoids the manual nonce bookkeeping the legacy
    ///      design needed for circular constructor wiring.
    function _deployTrio(
        uint256 agentId,
        address founderAddr,
        bytes32 mandateHash,
        string calldata mandateURI
    ) internal returns (DeployResult memory dr) {
        dr.token = Clones.clone(agentTokenImpl);
        dr.vault = Clones.clone(agentVaultImpl);
        dr.founderVault = Clones.clone(founderVaultImpl);

        // 1. AgentToken — mint authority is the vault.
        IAgentToken(dr.token).initialize(
            string.concat("Helm Agent ", _uint2str(agentId)),
            string.concat("AGT-", _uint2str(agentId)),
            dr.vault,
            agentId
        );

        // 2. AgentVault — references token and founder vault by address.
        _initVault(dr.vault, agentId, mandateHash, mandateURI, dr.token, dr.founderVault);

        // 3. FounderVault — references token and vault by address.
        IFounderVault(dr.founderVault).initialize(
            agentId, dr.token, dr.vault, founderAddr, usdc, distributor,
            defaultLockupDays, defaultSubordinationBps, 1000, defaultFounderShareBps
        );
    }

    function _initVault(
        address vault_,
        uint256 agentId_,
        bytes32 mandateHash_,
        string calldata mandateURI_,
        address token_,
        address founderVault_
    ) internal {
        IAgentVault.AssetEntry[] memory emptyAssets = new IAgentVault.AssetEntry[](0);
        IAgentVault.WeightConstraint[] memory emptyWc = new IAgentVault.WeightConstraint[](0);

        IAgentVault(vault_).initialize(
            IAgentVault.InitParams({
                agentId: agentId_,
                mandateHash: mandateHash_,
                mandateURI: mandateURI_,
                agentToken: token_,
                founderVault: founderVault_,
                registry: address(this),
                redemptionQueue: redemptionQueue,
                treasury: treasury,
                yieldHarvester: yieldHarvester,
                pythAdapter: pythAdapter,
                usdc: usdc,
                executor: executor,
                initialPhase: IAgentVault.Phase.Incubation,
                assets: emptyAssets,
                weightConstraints: emptyWc,
                seniorWindowDuration: 0
            })
        );
    }

    // ─── internal helpers ──────────────────────────────────────────

    function _agent(uint256 agentId) internal view returns (AgentRecord storage a) {
        a = _agents[agentId];
        if (a.vault == address(0)) revert AgentNotFound(agentId);
    }

    /// @dev Simple uint to decimal string.
    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
