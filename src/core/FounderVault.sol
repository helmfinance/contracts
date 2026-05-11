// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IFounderVault} from "../interfaces/IFounderVault.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";
import {IAgentVault} from "../interfaces/IAgentVault.sol";

/// @title FounderVault
/// @notice Holds the founder's AGT shares under lockup and subordination rules.
///         Receives 10% dev carry from DividendDistributor as USDC.
/// @dev Deployed once as an implementation; per-agent instances are EIP-1167 clones
///      created by HelmRegistry. State previously held in `immutable` slots is now
///      regular storage so it can be set inside {initialize}.
contract FounderVault is IFounderVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant REQUIRED_CARRY_BPS = 1_000; // 10%, protocol-locked

    error NotFounder();
    error SubordinationBreached();
    error NoCarryToClaim();
    error InvalidCarryBps();
    error InvalidFounderShareBps();
    error InvalidLockupDays();

    /// @notice Agent identifier.
    uint256 public override agentId;

    /// @notice The linked AgentVault.
    address public override vault;

    /// @notice The founder address.
    address public override founder;

    /// @notice The AGT share token.
    IAgentToken public agentToken;

    /// @notice USDC token for carry payouts.
    IERC20 public usdc;

    /// @notice Address allowed to call receiveCarry (DividendDistributor).
    address public distributor;

    /// @notice Timestamp after which founder may withdraw shares.
    uint64 public override lockupEndsAt;

    /// @notice Subordination threshold in basis points.
    uint16 public override subordinationThresholdBps;

    /// @notice Founder share percentage in basis points.
    uint16 public founderShareBps;

    /// @notice Total shares ever deposited by the founder.
    uint256 public totalDeposited;

    /// @notice Total shares ever withdrawn by the founder.
    uint256 public totalWithdrawn;

    /// @notice Current shares held in this vault.
    uint256 public override totalSharesHeld;

    /// @notice Accumulated USDC carry available for claim.
    uint256 public override carryBalance;

    /// @notice Whether the lockup end has been set (first deposit).
    bool internal _lockupSet;

    /// @notice Lockup duration in days (from mandate).
    uint64 public lockupDays;

    /// @notice Locks the implementation contract so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFounderVault
    function initialize(
        uint256 agentId_,
        address agentToken_,
        address vault_,
        address founder_,
        address usdc_,
        address distributor_,
        uint64 lockupDays_,
        uint16 subordinationThresholdBps_,
        uint16 carryBps_,
        uint16 founderShareBps_
    ) external override initializer {
        if (carryBps_ != REQUIRED_CARRY_BPS) revert InvalidCarryBps();
        if (founderShareBps_ < 500 || founderShareBps_ > 3000) revert InvalidFounderShareBps();
        if (lockupDays_ < 90) revert InvalidLockupDays();

        agentId = agentId_;
        agentToken = IAgentToken(agentToken_);
        vault = vault_;
        founder = founder_;
        usdc = IERC20(usdc_);
        distributor = distributor_;
        lockupDays = lockupDays_;
        subordinationThresholdBps = subordinationThresholdBps_;
        founderShareBps = founderShareBps_;
    }

    modifier onlyFounder() {
        if (msg.sender != founder) revert OnlyFounder();
        _;
    }

    // ---------------------------------------------------------------
    // IFounderVault
    // ---------------------------------------------------------------

    /// @inheritdoc IFounderVault
    function depositFounderShares(uint256 amount) external override {
        IERC20(address(agentToken)).safeTransferFrom(msg.sender, address(this), amount);

        if (!_lockupSet) {
            lockupEndsAt = uint64(block.timestamp) + lockupDays * 1 days;
            _lockupSet = true;
        }

        totalDeposited += amount;
        totalSharesHeld += amount;

        emit SharesDeposited(msg.sender, amount);
    }

    /// @inheritdoc IFounderVault
    function withdraw(uint256 amount) external override onlyFounder nonReentrant {
        if (block.timestamp < lockupEndsAt) revert LockupActive(lockupEndsAt);
        if (amount > totalSharesHeld) revert OnlyFounder(); // reuse; no shares

        // Check subordination: cumulative withdrawn ratio must stay within threshold
        uint256 newTotalWithdrawn = totalWithdrawn + amount;
        if (totalDeposited > 0) {
            uint256 withdrawnBps = (newTotalWithdrawn * BPS_DENOM) / totalDeposited;
            if (withdrawnBps > subordinationThresholdBps) revert SubordinationBreached();
        }

        totalWithdrawn = newTotalWithdrawn;
        totalSharesHeld -= amount;

        IERC20(address(agentToken)).safeTransfer(founder, amount);

        emit SharesWithdrawn(founder, amount);
    }

    /// @inheritdoc IFounderVault
    function receiveCarry(uint256 amount) external override {
        if (msg.sender != distributor) revert OnlyDistributor();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        carryBalance += amount;
        emit CarryReceived(amount);
    }

    /// @inheritdoc IFounderVault
    function claimCarry() external override onlyFounder nonReentrant returns (uint256 amount) {
        amount = carryBalance;
        if (amount == 0) revert NothingToClaim();
        carryBalance = 0;
        usdc.safeTransfer(founder, amount);
        emit CarryClaimed(founder, amount);
    }

    /// @notice Whether subordination threshold has been reached or exceeded.
    function isSubordinationActive() external view override returns (bool) {
        if (totalDeposited == 0) return false;
        return (totalWithdrawn * BPS_DENOM) / totalDeposited >= subordinationThresholdBps;
    }

    /// @notice Cumulative withdrawal ratio in basis points.
    function cumulativeWithdrawnBps() external view returns (uint256) {
        if (totalDeposited == 0) return 0;
        return (totalWithdrawn * BPS_DENOM) / totalDeposited;
    }

    // ---------------------------------------------------------------
    // Wind-down trigger
    // ---------------------------------------------------------------

    /// @notice Founder triggers wind-down on the linked AgentVault.
    /// @param reason Human-readable reason for the wind-down.
    function triggerWindDown(string calldata reason) external onlyFounder {
        IAgentVault(vault).triggerWindDown(reason);
    }
}
