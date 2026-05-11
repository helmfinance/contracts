// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/system/RedemptionQueue.sol";
import "../src/core/AgentVault.sol";
import "../src/core/AgentToken.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPlatformTreasury.sol";
import "./mocks/MockHelmRegistry.sol";

contract RedemptionQueueTest is Test {
    RedemptionQueue queue;
    AgentVault vault;
    AgentToken agentToken;
    MockERC20 usdc;
    MockPlatformTreasury treasury;
    MockHelmRegistry mockRegistry;

    uint256 constant AGENT_ID = 1;
    address admin = address(0xAD);
    address founderVault = address(0xF1);
    address yieldHarvester = address(0xCC);
    address executor = address(0xEE);
    address alice = address(0xA1);
    address bob = address(0xB0);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        treasury = new MockPlatformTreasury();
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint, 50);   // 0.5%
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Redeem, 50); // 0.5%

        mockRegistry = new MockHelmRegistry();

        // Predict addresses: queue first, then token, then vault
        uint64 nonce = vm.getNonce(address(this));
        // queue = nonce, token = nonce+1, vault = nonce+2
        address predictedQueue = vm.computeCreateAddress(address(this), nonce);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);

        queue = new RedemptionQueue(admin, address(mockRegistry));
        require(address(queue) == predictedQueue, "queue addr");

        agentToken = new AgentToken("Agent 1", "AGT-1", predictedVault, AGENT_ID);
        require(address(agentToken) == predictedToken, "token addr");

        AgentVault.AssetEntry[] memory emptyAssets = new AgentVault.AssetEntry[](0);
        AgentVault.WeightConstraint[] memory emptyWc = new AgentVault.WeightConstraint[](0);

        vault = new AgentVault(AgentVault.InitParams({
            agentId: AGENT_ID,
            mandateHash: keccak256("mandate"),
            mandateURI: "ipfs://m",
            agentToken: address(agentToken),
            founderVault: founderVault,
            registry: address(mockRegistry),
            redemptionQueue: address(queue),
            treasury: address(treasury),
            yieldHarvester: yieldHarvester,
            pythAdapter: address(0x1),
            usdc: address(usdc),
            executor: executor,
            initialPhase: IAgentVault.Phase.PublicLaunch,
            assets: emptyAssets,
            weightConstraints: emptyWc,
            seniorWindowDuration: 0
        }));
        require(address(vault) == predictedVault, "vault addr");

        // Set registry mock
        mockRegistry.setDeployment(AGENT_ID, IHelmRegistry.AgentDeployment({
            agentId: AGENT_ID,
            nft: address(0),
            token: address(agentToken),
            vault: address(vault),
            founderVault: founderVault,
            founder: alice,
            phase: IHelmRegistry.Phase.PublicLaunch,
            incubationStart: 0,
            publicLaunchAt: 0
        }));

        // Allow ThirtyDay and NinetyDay tiers
        vm.prank(admin);
        queue.setAllowedTiers(AGENT_ID, [false, true, false, true]);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Mint shares to user by depositing USDC into vault.
    function _mintShares(address user, uint256 usdcAmt) internal returns (uint256 shares) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmt);
        shares = vault.deposit(usdcAmt, user);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Request with disallowed tier reverts
    // ---------------------------------------------------------------

    function test_requestRedeem_disallowedTier_reverts() public {
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        vm.expectRevert(
            abi.encodeWithSelector(IRedemptionQueue.TierNotAllowedByMandate.selector, IRedemptionQueue.LockupTier.Instant)
        );
        queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.Instant);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Claim before unlock reverts
    // ---------------------------------------------------------------

    function test_claim_beforeUnlock_reverts() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);
        vm.stopPrank();

        // Still within lockup
        vm.warp(10_000 + 29 days);
        vm.expectRevert(
            abi.encodeWithSelector(IRedemptionQueue.StillLocked.selector, uint64(10_000 + 30 days))
        );
        queue.claim(reqId);
    }

    // ---------------------------------------------------------------
    // Warp past unlock, claim succeeds, USDC received
    // ---------------------------------------------------------------

    function test_claim_afterUnlock_succeeds() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);
        vm.stopPrank();

        vm.warp(10_000 + 30 days);
        uint256 usdcOut = queue.claim(reqId);

        assertGt(usdcOut, 0);
        assertEq(usdc.balanceOf(alice), usdcOut);

        // Request marked claimed
        IRedemptionQueue.Request memory r = queue.requestOf(reqId);
        assertTrue(r.claimed);
    }

    // ---------------------------------------------------------------
    // Double claim reverts
    // ---------------------------------------------------------------

    function test_claim_alreadyClaimed_reverts() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);
        vm.stopPrank();

        vm.warp(10_000 + 30 days);
        queue.claim(reqId);

        vm.expectRevert(IRedemptionQueue.AlreadyClaimed.selector);
        queue.claim(reqId);
    }

    // ---------------------------------------------------------------
    // Cancel within window: shares returned
    // ---------------------------------------------------------------

    function test_cancel_withinWindow_succeeds() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);

        // Cancel well before unlock
        vm.warp(10_000 + 10 days);
        queue.cancel(reqId);
        vm.stopPrank();

        // Shares returned to alice
        assertEq(agentToken.balanceOf(alice), shares);

        IRedemptionQueue.Request memory r = queue.requestOf(reqId);
        assertTrue(r.cancelled);

        // Pending shares reduced
        assertEq(queue.pendingForAgent(AGENT_ID), 0);
    }

    // ---------------------------------------------------------------
    // Cancel within 1 day of unlock: revert
    // ---------------------------------------------------------------

    function test_cancel_withinLastDay_reverts() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);

        // Warp to exactly 1 day before unlock
        vm.warp(10_000 + 29 days);
        vm.expectRevert(IRedemptionQueue.CancelWindowClosed.selector);
        queue.cancel(reqId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Cancel by non-requester reverts
    // ---------------------------------------------------------------

    function test_cancel_nonRequester_reverts() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(IRedemptionQueue.NotRequestOwner.selector);
        queue.cancel(reqId);
    }

    // ---------------------------------------------------------------
    // Cancel already-cancelled reverts
    // ---------------------------------------------------------------

    function test_cancel_alreadyCancelled_reverts() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.ThirtyDay);

        vm.warp(10_000 + 5 days);
        queue.cancel(reqId);

        vm.expectRevert(IRedemptionQueue.AlreadyCancelled.selector);
        queue.cancel(reqId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // pendingRequestsOf / pendingForAgent views
    // ---------------------------------------------------------------

    function test_pendingViews() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 200_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 id1 = queue.requestRedeem(AGENT_ID, shares / 2, IRedemptionQueue.LockupTier.ThirtyDay);
        uint256 id2 = queue.requestRedeem(AGENT_ID, shares / 2, IRedemptionQueue.LockupTier.NinetyDay);
        vm.stopPrank();

        uint256[] memory pending = queue.pendingRequestsOf(alice);
        assertEq(pending.length, 2);
        assertEq(pending[0], id1);
        assertEq(pending[1], id2);

        assertEq(queue.pendingForAgent(AGENT_ID), shares);

        // Cancel one
        vm.warp(10_000 + 5 days);
        vm.prank(alice);
        queue.cancel(id1);

        pending = queue.pendingRequestsOf(alice);
        assertEq(pending.length, 1);
        assertEq(pending[0], id2);
        assertEq(queue.pendingForAgent(AGENT_ID), shares / 2);
    }

    // ---------------------------------------------------------------
    // NinetyDay tier works with correct unlock time
    // ---------------------------------------------------------------

    function test_ninetyDayTier_unlockTime() public {
        vm.warp(10_000);
        uint256 shares = _mintShares(alice, 100_000_000);

        vm.startPrank(alice);
        agentToken.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(AGENT_ID, shares, IRedemptionQueue.LockupTier.NinetyDay);
        vm.stopPrank();

        IRedemptionQueue.Request memory r = queue.requestOf(reqId);
        assertEq(r.unlockAt, uint64(10_000 + 90 days));

        // Can't claim at 89 days
        vm.warp(10_000 + 89 days);
        vm.expectRevert();
        queue.claim(reqId);

        // Can claim at 90 days
        vm.warp(10_000 + 90 days);
        uint256 usdcOut = queue.claim(reqId);
        assertGt(usdcOut, 0);
    }
}
