// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAgentVault
/// @notice ERC-4626 vault holding USDC + positions for a single agent. The hub of all
///         value flow: mint/redeem (gated by phase), rebalance (executor-only), yield
///         deposit (harvester-only), wind-down (subordination-aware).
/// @dev `asset()` is USDC. `redeem()` from IERC4626 reverts — redemptions go through
///      RedemptionQueue.fulfillRedemption which calls back into this vault.
interface IAgentVault is IERC4626 {
    enum Phase {
        Incubation,    // 30-day window, founder-only deposits
        PublicLaunch,  // open to outside capital
        WindDown,      // selling positions to USDC, no new deposits
        Settled        // fully wound down, claim-only
    }

    enum AssetKind { Synthetic, METHAdapter, USDYAdapter }

    struct AssetEntry {
        address asset;
        AssetKind kind;
    }

    struct WeightConstraint {
        address asset;
        uint16  minBps;
        uint16  maxBps;
    }

    struct Position {
        address asset;     // SyntheticAsset, mETH, USDY adapter, etc.
        uint256 amount;
    }

    /// @notice Parameters for {initialize}. Mirrors what the legacy constructor took.
    struct InitParams {
        uint256 agentId;
        bytes32 mandateHash;
        string  mandateURI;
        address agentToken;
        address founderVault;
        address registry;
        address redemptionQueue;
        address treasury;
        address yieldHarvester;
        address pythAdapter;
        address usdc;
        address executor;
        Phase   initialPhase;
        AssetEntry[] assets;
        WeightConstraint[] weightConstraints;
        uint64  seniorWindowDuration; // 0 → default
        address timeProvider;          // singleton TimeProvider
    }

    event Rebalanced(bytes32 indexed strategyHash, uint256 navAfter, uint256 timestamp);
    event YieldDeposited(uint256 amount, uint256 newYieldPool);
    event RedemptionFulfilled(address indexed holder, uint256 sharesBurned, uint256 usdcOut);
    event PhaseChanged(Phase from, Phase to);
    event WindDownTriggered(address indexed by, string reason);
    event WindDownProgressed(uint256 remainingPositionsCount);
    event Settled(uint256 seniorPaid, uint256 juniorPaid);

    error WrongPhase();
    error OnlyExecutor();
    error OnlyHarvester();
    error OnlyRedemptionQueue();
    error OnlyRegistry();
    error InsufficientCash();

    function agentId() external view returns (uint256);
    function phase() external view returns (Phase);
    function executor() external view returns (address);    // BE-controlled signer

    // -- NAV & accounting --

    /// @notice Total assets in the vault, priced in USDC. Sum of cash + Σ(position × price).
    function totalNAV() external view returns (uint256);

    /// @notice Cash USDC available for redemptions without selling positions.
    function cashUSDC() external view returns (uint256);

    /// @notice Pending dividend pool not yet distributed.
    function yieldPool() external view returns (uint256);

    // -- Initialization --

    /// @notice Initialize an EIP-1167 clone of this vault. Replaces the constructor.
    function initialize(InitParams memory p) external;

    // -- Mutations --

    /// @notice Trigger rebalance using strategy weights from the agent runtime (BE).
    /// @param targets Desired position composition after this rebalance.
    /// @param strategyProof Reserved for future on-chain strategy commitment.
    function executeRebalance(Position[] calldata targets, bytes calldata strategyProof) external;

    /// @notice Receive cash yield from YieldHarvester. Only the harvester may call.
    function depositYield(uint256 amount) external;

    /// @notice Pull-based redemption. Burns shares and pays USDC. Only the queue may call.
    function fulfillRedemption(address holder, uint256 shares) external returns (uint256 usdcOut);

    // -- Lifecycle --

    /// @notice Move into PublicLaunch. Only the registry may call (after vetting passes).
    function enterPublicLaunch() external;

    /// @notice Move into WindDown. Callable by FounderVault on subordination signal,
    ///         the registry on slash, or the founder manually.
    function triggerWindDown(string calldata reason) external;

    /// @notice Sell next position to USDC during wind-down. Iterative — call until 0 returned.
    /// @return remainingPositions Count of positions still open after this call.
    function progressWindDown() external returns (uint256 remainingPositions);

    /// @notice Final settlement: pay senior (outside holders) pro-rata first, then junior
    ///         (founder via FounderVault). Only callable when wind-down is complete.
    function settle() external;
}
