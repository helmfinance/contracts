// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHelmRegistry} from "../interfaces/IHelmRegistry.sol";
import {IAgentVault} from "../interfaces/IAgentVault.sol";
import {AgentToken} from "../core/AgentToken.sol";
import {AgentVault} from "../core/AgentVault.sol";
import {FounderVault} from "../core/FounderVault.sol";

/// @title HelmRegistry
/// @notice Singleton factory that deploys agent trios (AgentToken, AgentVault,
///         FounderVault) and tracks each agent's lifecycle phase.
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
    uint256 internal _deployNonce;

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
        defaultLockupDays = p.defaultLockupDays;
        defaultSubordinationBps = p.defaultSubordinationBps;
        defaultFounderShareBps = p.defaultFounderShareBps;
        _nextAgentId = 1;
        _deployNonce = 1; // contract nonce starts at 1
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
        AgentVault(dr.vault).deposit(seedUSDC, dr.founderVault);

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
        AgentVault(a.vault).enterPublicLaunch();

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

    function _deployTrio(
        uint256 agentId,
        address founderAddr,
        bytes32 mandateHash,
        string calldata mandateURI
    ) internal returns (DeployResult memory dr) {
        uint256 baseNonce = _deployNonce;
        address pToken = _predictAddress(baseNonce);
        address pVault = _predictAddress(baseNonce + 1);
        address pFV    = _predictAddress(baseNonce + 2);

        // 1. AgentToken
        AgentToken token = new AgentToken(
            string.concat("Helm Agent ", _uint2str(agentId)),
            string.concat("AGT-", _uint2str(agentId)),
            pVault,
            agentId
        );
        require(address(token) == pToken, "token addr");

        // 2. AgentVault
        AgentVault vault_ = _deployVault(agentId, mandateHash, mandateURI, pToken, pFV);
        require(address(vault_) == pVault, "vault addr");

        // 3. FounderVault
        FounderVault fv = new FounderVault(
            agentId, pToken, pVault, founderAddr, usdc, distributor,
            defaultLockupDays, defaultSubordinationBps, 1000, defaultFounderShareBps
        );
        require(address(fv) == pFV, "fv addr");

        _deployNonce = baseNonce + 3;

        dr.token = pToken;
        dr.vault = pVault;
        dr.founderVault = pFV;
    }

    function _deployVault(
        uint256 agentId_,
        bytes32 mandateHash_,
        string calldata mandateURI_,
        address token_,
        address founderVault_
    ) internal returns (AgentVault) {
        AgentVault.AssetEntry[] memory emptyAssets = new AgentVault.AssetEntry[](0);
        AgentVault.WeightConstraint[] memory emptyWc = new AgentVault.WeightConstraint[](0);

        return new AgentVault(
            AgentVault.InitParams({
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

    /// @dev Predict CREATE address for this contract at a given nonce.
    function _predictAddress(uint256 nonce_) internal view returns (address) {
        if (nonce_ <= 0x7f) {
            return address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), uint8(nonce_))
            ))));
        } else if (nonce_ <= 0xff) {
            return address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xd7), bytes1(0x94), address(this), bytes1(0x81), uint8(nonce_))
            ))));
        } else if (nonce_ <= 0xffff) {
            return address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xd8), bytes1(0x94), address(this), bytes1(0x82), uint16(nonce_))
            ))));
        } else {
            return address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xd9), bytes1(0x94), address(this), bytes1(0x83), uint24(nonce_))
            ))));
        }
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
