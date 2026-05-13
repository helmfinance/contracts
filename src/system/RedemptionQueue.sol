// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRedemptionQueue} from "../interfaces/IRedemptionQueue.sol";
import {IAgentVault} from "../interfaces/IAgentVault.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";
import {IFounderVault} from "../interfaces/IFounderVault.sol";
import {IHelmRegistry} from "../interfaces/IHelmRegistry.sol";
import {ITimeProvider} from "../interfaces/ITimeProvider.sol";

/// @title RedemptionQueue
/// @notice Singleton redemption queue with lockup tiers (0/30/60/90 days).
///         Custodies AGT shares during lockup, then calls AgentVault.fulfillRedemption
///         to burn shares and receive USDC on behalf of the holder.
contract RedemptionQueue is IRedemptionQueue, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── constants ──────────────────────────────────────────────────

    /// @dev Days per lockup tier: Instant=0, ThirtyDay=30, SixtyDay=60, NinetyDay=90.
    uint64[4] internal TIER_DAYS = [0, 30, 60, 90];

    // ─── state ──────────────────────────────────────────────────────

    address public immutable admin;
    IHelmRegistry public immutable registry;
    ITimeProvider public immutable timeProvider;

    /// @dev agentId → tier → allowed
    mapping(uint256 => mapping(LockupTier => bool)) public tierAllowed;

    /// @dev agentId → vault address (cached on first request)
    mapping(uint256 => address) public vaultOf;

    /// @dev agentId → agentToken address (cached)
    mapping(uint256 => address) public tokenOf;

    /// @dev agentId → FounderVault address (cached). Used to read junior-tranche
    ///      subordination state when checking auto-windDown after a claim.
    mapping(uint256 => address) public founderVaultOf;

    mapping(uint256 => Request) internal _requests;
    uint256 internal _nextRequestId;

    /// @dev user → list of request IDs (append-only)
    mapping(address => uint256[]) internal _userRequests;

    /// @dev agentId → total shares currently locked in pending requests
    mapping(uint256 => uint256) internal _pendingSharesFor;

    // ─── constructor ────────────────────────────────────────────────

    /// @param admin_ Address that can configure allowed tiers.
    /// @param registry_ HelmRegistry address for agent lookups.
    /// @param timeProvider_ Singleton TimeProvider for demo fast-forward.
    constructor(address admin_, address registry_, address timeProvider_) {
        admin = admin_;
        registry = IHelmRegistry(registry_);
        timeProvider = ITimeProvider(timeProvider_);
        _nextRequestId = 1;
    }

    function _now() internal view returns (uint256) {
        return timeProvider.currentTime();
    }

    // ─── admin: tier configuration ──────────────────────────────────

    /// @notice Set which lockup tiers are allowed for an agent.
    /// @param agentId The agent identifier.
    /// @param tiers Boolean array [Instant, ThirtyDay, SixtyDay, NinetyDay].
    function setAllowedTiers(uint256 agentId, bool[4] calldata tiers) external {
        require(msg.sender == admin, "only admin");
        tierAllowed[agentId][LockupTier.Instant] = tiers[0];
        tierAllowed[agentId][LockupTier.ThirtyDay] = tiers[1];
        tierAllowed[agentId][LockupTier.SixtyDay] = tiers[2];
        tierAllowed[agentId][LockupTier.NinetyDay] = tiers[3];
    }

    // ─── IRedemptionQueue ───────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    function requestRedeem(uint256 agentId, uint256 shares, LockupTier tier)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (!tierAllowed[agentId][tier]) revert TierNotAllowedByMandate(tier);

        // Cache vault/token addresses
        _ensureCached(agentId);

        // Pull AGT shares from user into this contract
        IERC20(tokenOf[agentId]).safeTransferFrom(msg.sender, address(this), shares);

        requestId = _nextRequestId++;
        uint64 unlockAt = uint64(_now()) + TIER_DAYS[uint8(tier)] * 1 days;

        _requests[requestId] = Request({
            agentId: agentId,
            holder: msg.sender,
            shares: shares,
            tier: tier,
            unlockAt: unlockAt,
            claimed: false,
            cancelled: false
        });

        _userRequests[msg.sender].push(requestId);
        _pendingSharesFor[agentId] += shares;

        emit RedeemRequested(requestId, agentId, msg.sender, shares, tier, unlockAt);
    }

    /// @inheritdoc IRedemptionQueue
    function claim(uint256 requestId)
        external
        override
        nonReentrant
        returns (uint256 usdcOut)
    {
        Request storage r = _requests[requestId];
        if (r.holder == address(0)) revert NotRequestOwner();
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        if (_now() < r.unlockAt) revert StillLocked(r.unlockAt);

        r.claimed = true;
        _pendingSharesFor[r.agentId] -= r.shares;

        address vault_ = vaultOf[r.agentId];

        // Approve vault to burn our shares
        IERC20(tokenOf[r.agentId]).forceApprove(vault_, r.shares);

        // Vault burns shares from this contract, sends USDC to this contract
        usdcOut = IAgentVault(vault_).fulfillRedemption(address(this), r.shares);

        // Forward USDC to the original holder
        address usdcAddr = IAgentVault(vault_).asset();
        IERC20(usdcAddr).safeTransfer(r.holder, usdcOut);

        emit RedeemClaimed(requestId, usdcOut);

        // Burning user shares can push the founder's effective stake above the
        // subordination threshold. If so, auto-trigger wind-down.
        _checkSubordinationAndTrigger(r.agentId);
    }

    /// @inheritdoc IRedemptionQueue
    function cancel(uint256 requestId) external override nonReentrant {
        Request storage r = _requests[requestId];
        if (r.holder != msg.sender) revert NotRequestOwner();
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();

        // Must cancel at least 1 day before unlock
        if (r.unlockAt > 0 && _now() >= r.unlockAt - 1 days) {
            revert CancelWindowClosed();
        }

        r.cancelled = true;
        _pendingSharesFor[r.agentId] -= r.shares;

        // Return shares to holder
        IERC20(tokenOf[r.agentId]).safeTransfer(r.holder, r.shares);

        emit RedeemCancelled(requestId);
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IRedemptionQueue
    function requestOf(uint256 requestId) external view override returns (Request memory) {
        return _requests[requestId];
    }

    /// @inheritdoc IRedemptionQueue
    function pendingRequestsOf(address holder) external view override returns (uint256[] memory) {
        uint256[] storage all = _userRequests[holder];
        // Count pending
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            Request storage r = _requests[all[i]];
            if (!r.claimed && !r.cancelled) count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            Request storage r = _requests[all[i]];
            if (!r.claimed && !r.cancelled) {
                result[j++] = all[i];
            }
        }
        return result;
    }

    /// @inheritdoc IRedemptionQueue
    function pendingForAgent(uint256 agentId) external view override returns (uint256) {
        return _pendingSharesFor[agentId];
    }

    // ─── internal ───────────────────────────────────────────────────

    function _ensureCached(uint256 agentId) internal {
        if (vaultOf[agentId] == address(0)) {
            IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
            vaultOf[agentId] = d.vault;
            tokenOf[agentId] = d.token;
            founderVaultOf[agentId] = d.founderVault;
        }
    }

    /// @dev Called by {claim} after shares are burned. If the founder's
    ///      effective share of remaining supply now meets or exceeds the
    ///      FounderVault's subordination threshold, auto-trigger wind-down
    ///      on the agent's vault.
    function _checkSubordinationAndTrigger(uint256 agentId) internal {
        address vault_ = vaultOf[agentId];
        address fv_    = founderVaultOf[agentId];
        if (fv_ == address(0)) return;
        if (IAgentVault(vault_).phase() == IAgentVault.Phase.WindDown) return;

        uint256 supply = IERC20(tokenOf[agentId]).totalSupply();
        if (supply == 0) return;

        uint256 founderHeld = IFounderVault(fv_).totalSharesHeld();
        uint256 founderBps = (founderHeld * 10_000) / supply;
        uint16  threshold  = IFounderVault(fv_).subordinationThresholdBps();
        if (founderBps >= threshold) {
            IAgentVault(vault_).triggerWindDown("subordination_breach_via_redemption");
        }
    }
}
