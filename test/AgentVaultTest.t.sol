// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/core/AgentVault.sol";
import "../src/core/AgentToken.sol";
import "../src/adapters/PythPriceAdapter.sol";
import "../src/adapters/SyntheticAsset.sol";
import "../src/system/TimeProvider.sol";
import "./mocks/MockPyth.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPlatformTreasury.sol";

contract AgentVaultTest is Test {
    AgentVault vault;
    AgentToken agentToken;
    MockERC20 usdc;
    MockPyth mockPyth;
    PythPriceAdapter priceAdapter;
    SyntheticAsset sNVDA;
    MockPlatformTreasury treasury;
    TimeProvider timeProvider;

    bytes32 constant FEED_ID = keccak256("NVDA/USD");
    uint64 constant STALENESS = 96 hours;
    uint256 constant AGENT_ID = 1;

    address founder = address(0xF0);
    address founderVault = address(0xF1);
    address registry = address(0xAA);
    address redemptionQueue = address(0xBB);
    address yieldHarvester = address(0xCC);
    address executor = address(0xDD);
    address alice = address(0xA1);
    address bob = address(0xB0);

    function setUp() public {
        // Deploy USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy Pyth stack
        mockPyth = new MockPyth(1);
        bytes32[] memory feedIds = new bytes32[](1);
        uint64[] memory maxStale = new uint64[](1);
        feedIds[0] = FEED_ID;
        maxStale[0] = STALENESS;
        priceAdapter = new PythPriceAdapter(address(mockPyth), feedIds, maxStale);

        // Deploy sNVDA
        sNVDA = new SyntheticAsset(
            "Synthetic NVIDIA", "sNVDA", "NVDA",
            FEED_ID, address(priceAdapter), address(usdc)
        );

        // Deploy treasury
        treasury = new MockPlatformTreasury();
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint, 50);       // 0.5%
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Redeem, 50);     // 0.5%
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Rebalance, 5);   // 0.05%

        // TimeProvider singleton.
        timeProvider = new TimeProvider();

        // With EIP-1167 clones we clone both first, then initialize. No nonce
        // prediction needed because each clone exists before its initialize call.
        AgentToken tokenImpl = new AgentToken();
        AgentVault vaultImpl = new AgentVault();
        agentToken = AgentToken(Clones.clone(address(tokenImpl)));
        vault = AgentVault(Clones.clone(address(vaultImpl)));

        agentToken.initialize("Agent 1 Shares", "AGT-1", address(vault), AGENT_ID);

        IAgentVault.AssetEntry[] memory assets = new IAgentVault.AssetEntry[](1);
        assets[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});

        IAgentVault.WeightConstraint[] memory wc = new IAgentVault.WeightConstraint[](1);
        wc[0] = IAgentVault.WeightConstraint({asset: address(sNVDA), minBps: 0, maxBps: 5000}); // max 50%

        IAgentVault.InitParams memory params = IAgentVault.InitParams({
            agentId: AGENT_ID,
            mandateHash: keccak256("mandate"),
            mandateURI: "ipfs://mandate",
            agentToken: address(agentToken),
            founderVault: founderVault,
            registry: registry,
            redemptionQueue: redemptionQueue,
            treasury: address(treasury),
            yieldHarvester: yieldHarvester,
            pythAdapter: address(priceAdapter),
            usdc: address(usdc),
            executor: executor,
            initialPhase: IAgentVault.Phase.PublicLaunch,
            assets: assets,
            weightConstraints: wc,
            seniorWindowDuration: 0,
            timeProvider: address(timeProvider)
        });

        vault.initialize(params);

        // Register vault in SyntheticAsset so it can mint/burn sNVDA
        sNVDA.registerVault(address(vault));

        // Set a fresh NVDA price: $100
        _setNvdaPrice(100);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _setNvdaPrice(uint256 priceUsd) internal {
        int64 raw = int64(int256(priceUsd * 100));
        vm.warp(1_000_000);
        mockPyth.setPrice(FEED_ID, raw, 50, -2, 1_000_000);
    }

    function _setNvdaPriceAtTime(uint256 priceUsd, uint256 t) internal {
        int64 raw = int64(int256(priceUsd * 100));
        vm.warp(t);
        mockPyth.setPrice(FEED_ID, raw, 50, -2, t);
    }

    function _depositAsUser(address user, uint256 usdcAmt) internal returns (uint256 shares) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmt);
        shares = vault.deposit(usdcAmt, user);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Mint at 1.0 NAV: deposit 100 USDC → ~99.5 shares (0.5% fee)
    // ---------------------------------------------------------------

    function test_deposit_atParNAV() public {
        uint256 usdcIn = 100_000_000; // 100 USDC
        uint256 shares = _depositAsUser(alice, usdcIn);

        // Fee = 100 * 0.5% = 0.5 USDC = 500_000
        // Net deposit = 99.5 USDC = 99_500_000
        // First deposit: shares = net * 1e18 / 1e6 = 99_500_000 * 1e12 = 99.5e18
        assertEq(shares, 99_500_000 * 1e12);
        assertEq(agentToken.balanceOf(alice), shares);
    }

    // ---------------------------------------------------------------
    // Mint after rebalance gain: NAV/share = 1.2
    // ---------------------------------------------------------------

    function test_deposit_afterNavGain() public {
        // First user deposits 100 USDC
        uint256 firstShares = _depositAsUser(alice, 100_000_000);

        // Simulate NAV increase: airdrop 19.5 USDC to vault (NAV ~119.5, minus fees)
        // After first deposit: vault has 99.5 USDC (fee sent to treasury)
        // Add 20 USDC to make NAV ~119.5 USDC
        usdc.mint(address(vault), 20_000_000);

        // Now NAV = 119.5 USDC, supply = 99.5e18 shares
        // NAV/share = 119.5 / 99.5 ≈ 1.2 USDC per share (in 1e6 terms)
        uint256 navBefore = vault.totalNAV();

        // Bob deposits 120 USDC
        uint256 bobShares = _depositAsUser(bob, 120_000_000);

        // Fee = 120 * 0.5% = 0.6 USDC = 600_000
        // Net = 119.4 USDC = 119_400_000
        // Shares = 119_400_000 * firstShares / navBefore
        uint256 expectedShares = uint256(119_400_000) * firstShares / navBefore;
        assertEq(bobShares, expectedShares);
        // Bob should get fewer shares than net USDC because NAV/share > 1
        assertLt(bobShares, 119_400_000 * 1e12); // less than par
    }

    // ---------------------------------------------------------------
    // Redeem at higher NAV: profit captured
    // ---------------------------------------------------------------

    function test_redeem_atHigherNav_profitCaptured() public {
        uint256 shares = _depositAsUser(alice, 100_000_000);

        // Airdrop 50 USDC to vault → NAV goes up
        usdc.mint(address(vault), 50_000_000);

        // Redeem via queue
        vm.prank(redemptionQueue);
        uint256 usdcOut = vault.fulfillRedemption(alice, shares);

        // gross = shares * totalNAV / supply (before burn)
        // fee = gross * 0.5%
        // usdcOut = gross - fee
        // usdcOut should be > 99.5 USDC (initial net deposit)
        assertGt(usdcOut, 99_000_000);
    }

    // ---------------------------------------------------------------
    // Redeem at lower NAV: loss absorbed
    // ---------------------------------------------------------------

    function test_redeem_atLowerNav_lossAbsorbed() public {
        uint256 shares = _depositAsUser(alice, 100_000_000);

        // Remove USDC from vault to simulate loss
        // vault has ~99.5 USDC. Burn 49.5 to leave ~50 USDC
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), 49_500_000);

        vm.prank(redemptionQueue);
        uint256 usdcOut = vault.fulfillRedemption(alice, shares);

        // NAV ≈ 50 USDC, redeem fee on top → should get < 50 USDC
        assertLt(usdcOut, 50_000_000);
    }

    // ---------------------------------------------------------------
    // Mint reverts during WindDown
    // ---------------------------------------------------------------

    function test_deposit_revertsDuringWindDown() public {
        // Trigger wind-down
        vm.prank(registry);
        vault.triggerWindDown("test slash");

        usdc.mint(alice, 100_000_000);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000_000);
        vm.expectRevert(AgentVault.MintsDisabled.selector);
        vault.deposit(100_000_000, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Rebalance reverts when called by non-backend
    // ---------------------------------------------------------------

    function test_rebalance_revertsNonExecutor() public {
        IAgentVault.Position[] memory targets = new IAgentVault.Position[](0);

        vm.prank(alice);
        vm.expectRevert(IAgentVault.OnlyExecutor.selector);
        vault.executeRebalance(targets, "");
    }

    // ---------------------------------------------------------------
    // Rebalance: buy sNVDA within mandate
    // ---------------------------------------------------------------

    function test_rebalance_buySynthetic() public {
        // Deposit 1000 USDC
        _depositAsUser(alice, 1000_000_000);

        // Rebalance: buy 2 sNVDA at $100 = 200 USDC worth of sNVDA
        // Target: 2e18 sNVDA shares
        IAgentVault.Position[] memory targets = new IAgentVault.Position[](1);
        targets[0] = IAgentVault.Position({asset: address(sNVDA), amount: 2e18});

        vm.prank(executor);
        vault.executeRebalance(targets, "strategy1");

        // sNVDA balance should be 2e18
        assertEq(sNVDA.balanceOf(address(vault)), 2e18);
    }

    // ---------------------------------------------------------------
    // Rebalance reverts if exceeds mandate maxBps
    // ---------------------------------------------------------------

    function test_rebalance_mandateBreach() public {
        // Deposit 1000 USDC → ~995 USDC after fee
        _depositAsUser(alice, 1000_000_000);

        // Try to buy 6 sNVDA at $100 = 600 USDC → ~60% of NAV > 50% max
        IAgentVault.Position[] memory targets = new IAgentVault.Position[](1);
        targets[0] = IAgentVault.Position({asset: address(sNVDA), amount: 6e18});

        vm.prank(executor);
        vm.expectRevert(); // MandateBreach
        vault.executeRebalance(targets, "");
    }

    // ---------------------------------------------------------------
    // Wind-down: senior holders redeem first, junior gets remainder
    // ---------------------------------------------------------------

    function test_windDown_seniorFirst() public {
        // Alice (senior) deposits 100 USDC
        _depositAsUser(alice, 100_000_000);

        // Mint founder shares to founderVault
        // We simulate by having founder vault deposit too
        usdc.mint(founderVault, 50_000_000);
        vm.startPrank(founderVault);
        usdc.approve(address(vault), 50_000_000);
        vault.deposit(50_000_000, founderVault);
        vm.stopPrank();

        // Trigger wind-down
        vm.prank(registry);
        vault.triggerWindDown("test wind down");

        assertTrue(vault.phase() == IAgentVault.Phase.WindDown);

        // During senior window, founderVault (junior) cannot redeem
        uint256 founderShares = agentToken.balanceOf(founderVault);
        vm.prank(redemptionQueue);
        vm.expectRevert(); // SeniorWindowOpen
        vault.fulfillRedemption(founderVault, founderShares);

        // Senior (alice) CAN redeem during senior window
        uint256 aliceShares = agentToken.balanceOf(alice);
        vm.prank(redemptionQueue);
        uint256 usdcOut = vault.fulfillRedemption(alice, aliceShares);
        assertGt(usdcOut, 0);
    }

    // ---------------------------------------------------------------
    // NAV calc with stale Pyth reverts
    // ---------------------------------------------------------------

    function test_totalNAV_revertsOnStalePrice() public {
        // Deposit and buy some sNVDA
        _depositAsUser(alice, 1000_000_000);

        IAgentVault.Position[] memory targets = new IAgentVault.Position[](1);
        targets[0] = IAgentVault.Position({asset: address(sNVDA), amount: 1e18});
        vm.prank(executor);
        vault.executeRebalance(targets, "");

        // Advance time past staleness
        vm.warp(block.timestamp + uint256(STALENESS) + 1);

        // totalNAV should revert because sNVDA.priceUSDC() hits stale Pyth
        vm.expectRevert();
        vault.totalNAV();
    }

    // ---------------------------------------------------------------
    // Rebalance reverts during wind-down
    // ---------------------------------------------------------------

    function test_rebalance_revertsDuringWindDown() public {
        _depositAsUser(alice, 100_000_000);

        vm.prank(registry);
        vault.triggerWindDown("slash");

        IAgentVault.Position[] memory targets = new IAgentVault.Position[](0);
        vm.prank(executor);
        vm.expectRevert(AgentVault.WindDownActive.selector);
        vault.executeRebalance(targets, "");
    }

    // ---------------------------------------------------------------
    // Only authorized callers can trigger wind-down
    // ---------------------------------------------------------------

    function test_triggerWindDown_revertsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(AgentVault.NotAuthorizedToWindDown.selector);
        vault.triggerWindDown("unauthorized");
    }

    // ---------------------------------------------------------------
    // Settle after wind-down
    // ---------------------------------------------------------------

    function test_settle_afterWindDown() public {
        // Alice and founderVault both deposit
        _depositAsUser(alice, 100_000_000);
        usdc.mint(founderVault, 50_000_000);
        vm.startPrank(founderVault);
        usdc.approve(address(vault), 50_000_000);
        vault.deposit(50_000_000, founderVault);
        vm.stopPrank();

        // Trigger wind-down
        vm.prank(registry);
        vault.triggerWindDown("test settle");

        // Advance past senior window (90 days)
        vm.warp(block.timestamp + 91 days);
        _setNvdaPriceAtTime(100, block.timestamp);

        // Settle
        vault.settle();

        assertTrue(vault.phase() == IAgentVault.Phase.Settled);

        (,,,,, uint256 seniorPay, uint256 juniorPay) = vault.windDown();
        assertGt(seniorPay, 0);
        assertGt(juniorPay, 0);
        // Senior should get proportionally more (they deposited more)
        assertGt(seniorPay, juniorPay);
    }

    // ---------------------------------------------------------------
    // ERC-4626 views
    // ---------------------------------------------------------------

    function test_erc4626_asset() public view {
        assertEq(vault.asset(), address(usdc));
    }

    function test_erc4626_redeemDisabled() public {
        vm.expectRevert(AgentVault.ERC4626RedeemDisabled.selector);
        vault.redeem(1, alice, alice);
    }

    function test_erc4626_withdrawDisabled() public {
        vm.expectRevert(AgentVault.ERC4626RedeemDisabled.selector);
        vault.withdraw(1, alice, alice);
    }
}
