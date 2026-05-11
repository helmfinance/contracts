// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDividendDistributor} from "../interfaces/IDividendDistributor.sol";
import {IHelmRegistry} from "../interfaces/IHelmRegistry.sol";
import {IFounderVault} from "../interfaces/IFounderVault.sol";

/// @title DividendDistributor
/// @notice Receives USDC yield, splits 90% to AGT holders / 10% to founder carry.
///         Holders claim pro-rata based on their current AGT balance at claim time.
/// @dev    // TODO(human): For production, snapshot AGT balances per epoch (e.g. via
///         ERC20Votes checkpointing) so that transfers between distribute() and claim()
///         cannot game the distribution. Current MVP uses live balanceOf — acceptable for
///         hackathon but exploitable if holders front-run distributions with buys.
contract DividendDistributor is IDividendDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant CARRY_BPS = 1_000; // 10%
    uint256 internal constant BPS_DENOM = 10_000;

    error NotHarvester();
    error AgentNotFound();
    error EpochNotFound();

    struct EpochData {
        uint256 totalAmount;
        uint256 holdersShare;
        uint256 carryShare;
        uint256 totalSharesAtSnapshot;
        uint64  distributedAt;
        uint256 totalClaimed;
    }

    address public immutable harvester;
    IHelmRegistry public immutable registry;
    IERC20 public immutable usdc;

    /// @dev agentId → current epoch counter (0 = no distributions yet)
    mapping(uint256 => uint256) internal _epochCounter;
    /// @dev agentId → epoch → data
    mapping(uint256 => mapping(uint256 => EpochData)) internal _epochs;
    /// @dev agentId → epoch → holder → claimed
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) internal _claimed;
    /// @dev agentId → USDC amount staged for next distribution
    mapping(uint256 => uint256) internal _stagedYield;

    /// @param harvester_ YieldHarvester address (only caller of distribute/stageYield).
    /// @param registry_ HelmRegistry for agent lookups.
    /// @param usdc_ USDC token address.
    constructor(address harvester_, address registry_, address usdc_) {
        harvester = harvester_;
        registry = IHelmRegistry(registry_);
        usdc = IERC20(usdc_);
    }

    // ─── staging ────────────────────────────────────────────────────

    /// @notice Stage USDC for the next distribution. Called by YieldHarvester
    ///         before calling distribute().
    /// @param agentId The agent to stage yield for.
    /// @param amount USDC amount (pulled from caller).
    function stageYield(uint256 agentId, uint256 amount) external {
        if (msg.sender != harvester) revert NotHarvester();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _stagedYield[agentId] += amount;
    }

    // ─── IDividendDistributor ───────────────────────────────────────

    /// @inheritdoc IDividendDistributor
    function distribute(uint256 agentId) external override nonReentrant returns (uint256 epoch) {
        if (msg.sender != harvester) revert NotHarvester();

        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        if (d.vault == address(0)) revert AgentNotFound();

        uint256 yieldAmount = _stagedYield[agentId];
        if (yieldAmount == 0) revert EmptyYieldPool();
        delete _stagedYield[agentId];

        epoch = ++_epochCounter[agentId];

        uint256 carry = yieldAmount * CARRY_BPS / BPS_DENOM;
        uint256 holdersAmt = yieldAmount - carry;
        uint256 totalShares = IERC20(d.token).totalSupply();

        _epochs[agentId][epoch] = EpochData({
            totalAmount: yieldAmount,
            holdersShare: holdersAmt,
            carryShare: carry,
            totalSharesAtSnapshot: totalShares,
            distributedAt: uint64(block.timestamp),
            totalClaimed: 0
        });

        // Send carry to FounderVault
        if (carry > 0) {
            usdc.forceApprove(d.founderVault, carry);
            IFounderVault(d.founderVault).receiveCarry(carry);
        }

        emit Distributed(agentId, epoch, yieldAmount, holdersAmt, carry, bytes32(0));
    }

    /// @inheritdoc IDividendDistributor
    function claim(uint256 agentId, uint256[] calldata epochs)
        external
        override
        nonReentrant
        returns (uint256 totalUSDC)
    {
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        uint256 userBal = IERC20(d.token).balanceOf(msg.sender);

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 ep = epochs[i];
            EpochData storage e = _epochs[agentId][ep];
            if (e.distributedAt == 0) revert EpochNotFinalized(agentId, ep);
            if (_claimed[agentId][ep][msg.sender]) revert AlreadyClaimed(agentId, ep, msg.sender);

            // TODO(human): Use snapshotted balance instead of live balanceOf for production.
            uint256 share = e.totalSharesAtSnapshot == 0
                ? 0
                : (e.holdersShare * userBal) / e.totalSharesAtSnapshot;

            _claimed[agentId][ep][msg.sender] = true;
            e.totalClaimed += share;
            totalUSDC += share;

            emit Claimed(agentId, msg.sender, ep, share);
        }

        if (totalUSDC > 0) {
            usdc.safeTransfer(msg.sender, totalUSDC);
        }
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IDividendDistributor
    function epochOf(uint256 agentId) external view override returns (uint256) {
        return _epochCounter[agentId];
    }

    /// @inheritdoc IDividendDistributor
    function pendingClaimOf(uint256 agentId, address holder) external view override returns (uint256 total) {
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        uint256 userBal = IERC20(d.token).balanceOf(holder);
        uint256 maxEpoch = _epochCounter[agentId];

        for (uint256 ep = 1; ep <= maxEpoch; ep++) {
            if (_claimed[agentId][ep][holder]) continue;
            EpochData storage e = _epochs[agentId][ep];
            if (e.totalSharesAtSnapshot == 0) continue;
            total += (e.holdersShare * userBal) / e.totalSharesAtSnapshot;
        }
    }

    /// @inheritdoc IDividendDistributor
    function epochSnapshot(uint256 agentId, uint256 epoch)
        external
        view
        override
        returns (uint256 totalAmount, uint256 holdersShare, uint256 totalSharesAtSnapshot, uint64 timestamp)
    {
        EpochData storage e = _epochs[agentId][epoch];
        return (e.totalAmount, e.holdersShare, e.totalSharesAtSnapshot, e.distributedAt);
    }
}
