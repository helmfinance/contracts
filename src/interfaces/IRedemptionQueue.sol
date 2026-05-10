// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRedemptionQueue
/// @notice User redemption flow with 0/30/60/90 day lockup options. The agent's mandate
///         declares which tiers are allowed. Longer lockup signals stronger trust in the
///         agent's runway and improves the agent's reputation premium.
/// @dev Singleton. Custodies AGT during lockup. After unlock, calls
///      AgentVault.fulfillRedemption to burn shares and pay USDC.
interface IRedemptionQueue {
    enum LockupTier {
        Instant,    // 0d, often disabled by mandate
        ThirtyDay,
        SixtyDay,
        NinetyDay
    }

    struct Request {
        uint256    agentId;
        address    holder;
        uint256    shares;
        LockupTier tier;
        uint64     unlockAt;
        bool       claimed;
        bool       cancelled;
    }

    event RedeemRequested(
        uint256 indexed requestId,
        uint256 indexed agentId,
        address indexed holder,
        uint256 shares,
        LockupTier tier,
        uint64 unlockAt
    );
    event RedeemClaimed(uint256 indexed requestId, uint256 usdcOut);
    event RedeemCancelled(uint256 indexed requestId);

    error TierNotAllowedByMandate(LockupTier tier);
    error StillLocked(uint64 unlockAt);
    error AlreadyClaimed();
    error AlreadyCancelled();
    error CancelWindowClosed();
    error NotRequestOwner();

    /// @notice Lock shares and enter the queue. Tier must be allowed by the agent's mandate.
    function requestRedeem(uint256 agentId, uint256 shares, LockupTier tier)
        external
        returns (uint256 requestId);

    /// @notice After `unlockAt`, claim USDC. Vault burns shares and pays out.
    function claim(uint256 requestId) external returns (uint256 usdcOut);

    /// @notice Cancel a pending request. Allowed up to 1 day before `unlockAt`.
    function cancel(uint256 requestId) external;

    function requestOf(uint256 requestId) external view returns (Request memory);
    function pendingRequestsOf(address holder) external view returns (uint256[] memory);
    function pendingForAgent(uint256 agentId) external view returns (uint256 totalShares);
}
