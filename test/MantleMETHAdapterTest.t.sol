// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {MantleMETHAdapter} from "../src/adapters/MantleMETHAdapter.sol";
import {IMantleMETHAdapter} from "../src/interfaces/IMantleMETHAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract MantleMETHAdapterTest is Test {
    MantleMETHAdapter adapter;
    MockERC20 usdc;
    MockPyth pyth;

    bytes32 constant ETH_USD_FEED = keccak256("ETH/USD");
    uint64  constant MAX_STALENESS = 60;

    address alice = address(0xA);
    address bob   = address(0xB);
    address harvester = address(0x14E);

    // mETH/Sepolia address (used only as a reference; no transfers occur).
    address constant SEPOLIA_METH = 0x9EF6f9160Ba00B6621e5CB3217BB8b54a92B2828;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        pyth = new MockPyth(0);
        _setEthPrice(3000_00000); // $3000 with expo=-5

        adapter = new MantleMETHAdapter(
            address(usdc), address(pyth), ETH_USD_FEED, SEPOLIA_METH, MAX_STALENESS
        );
        usdc.addMinter(address(adapter));
    }

    // ─── helpers ────────────────────────────────────────────────────

    function _setEthPrice(uint256 priceWithExpoMinus5) internal {
        pyth.setPrice(
            ETH_USD_FEED,
            int64(int256(priceWithExpoMinus5)),
            50,
            -5,
            block.timestamp
        );
    }

    function _deposit(address user, uint256 usdcAmt) internal returns (uint256 mEthOut) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(adapter), usdcAmt);
        mEthOut = adapter.deposit(usdcAmt, 0);
        vm.stopPrank();
    }

    // ─── constants and constructor ──────────────────────────────────

    function test_constructor_state() public view {
        assertEq(address(adapter.usdc()), address(usdc));
        assertEq(address(adapter.pyth()), address(pyth));
        assertEq(adapter.ethUsdPriceId(), ETH_USD_FEED);
        assertEq(adapter.meth(), SEPOLIA_METH);
        assertEq(adapter.mEthEthRatio(), 1e18);
        assertEq(adapter.SIMULATED_APY_BPS(), 400);
        assertEq(adapter.realMethAddress(), SEPOLIA_METH);
        assertEq(adapter.productionMethAddress(), adapter.MANTLE_METH_MAINNET());
    }

    // ─── deposit @ fixed Pyth price ─────────────────────────────────

    function test_deposit_atPythPrice() public {
        // 100 USDC at ETH=$3000 ⇒ mETH ≈ 100/3000 = 0.0333… ETH (1e18 scaled).
        uint256 mEthOut = _deposit(alice, 100e6);
        assertApproxEqAbs(mEthOut, 33_333_333_333_333_333, 1e10);
        assertEq(adapter.balanceOfHolder(alice), mEthOut);
        // Adapter still holds the 100 USDC principal.
        assertEq(usdc.balanceOf(address(adapter)), 100e6);
    }

    function test_deposit_revertsBelowMinOut() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 100e6);
        vm.expectRevert();
        adapter.deposit(100e6, 200e18); // demanding more than possible
        vm.stopPrank();
    }

    // ─── withdraw with price increase (P&L mint backstop) ───────────

    function test_withdraw_priceIncrease_mintsBackstop() public {
        uint256 mEthOut = _deposit(alice, 100e6); // adapter holds 100 USDC

        // ETH +20% → $3600. mETH USDC value is now ~120.
        _setEthPrice(3600_00000);

        vm.prank(alice);
        uint256 usdcOut = adapter.withdraw(mEthOut, 0);

        // Expect roughly 120 USDC after the price move.
        assertApproxEqAbs(usdcOut, 120e6, 1e4);
        assertEq(usdc.balanceOf(alice), usdcOut);
        // Adapter minted the shortfall — its balance is fully drained.
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(adapter.balanceOfHolder(alice), 0);
    }

    function test_withdraw_priceDecrease_noMintNeeded() public {
        uint256 mEthOut = _deposit(alice, 100e6);

        // ETH -10% → $2700. mETH worth ~90 USDC; adapter has 100 USDC.
        _setEthPrice(2700_00000);

        vm.prank(alice);
        uint256 usdcOut = adapter.withdraw(mEthOut, 0);

        assertApproxEqAbs(usdcOut, 90e6, 1e4);
        // No mint needed — adapter retains the 10 USDC surplus (junior P&L).
        assertEq(usdc.balanceOf(address(adapter)), 100e6 - usdcOut);
    }

    // ─── harvest accrues at 4% APY ──────────────────────────────────

    function test_harvest_after30Days_4pctAPY() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 30 days);
        _setEthPrice(3000_00000); // re-stamp publish time so Pyth isn't stale

        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);

        // 100 USDC × 4% × 30/365 ≈ 0.32877 USDC ≈ 328_767 base units.
        assertApproxEqAbs(yieldAmt, 328_767, 100);
        // Yield is minted to the harvester (msg.sender).
        assertEq(usdc.balanceOf(harvester), yieldAmt);
        // No more pending immediately after harvest.
        assertEq(adapter.pendingYieldOf(alice), 0);
    }

    function test_harvest_resetsAccrualTimer() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 30 days);
        _setEthPrice(3000_00000);
        vm.prank(harvester);
        uint256 first = adapter.harvestYield(alice);

        // No additional time: nothing to harvest.
        vm.prank(harvester);
        uint256 second = adapter.harvestYield(alice);
        assertEq(second, 0);

        // Another 30 days → similar amount accrues. The second window
        // starts from a slightly higher mEthEthRatio (compounded growth)
        // so allow ~0.5% delta.
        vm.warp(block.timestamp + 30 days);
        _setEthPrice(3000_00000);
        vm.prank(harvester);
        uint256 third = adapter.harvestYield(alice);
        assertApproxEqAbs(third, first, 2_000);
    }

    function test_yield_oneYear_approximately4pct() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 365 days);
        _setEthPrice(3000_00000);

        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);

        // ~4 USDC over one year on 100 USDC principal. Compound-growth ratio
        // makes the actual figure slightly above 4_000_000 µUSDC.
        assertApproxEqAbs(yieldAmt, 4_000_000, 100_000);
    }

    // ─── currentValueUsdc view ──────────────────────────────────────

    function test_currentValueUsdc() public {
        uint256 mEthOut = _deposit(alice, 100e6);
        // Same block, same price → roughly 100 USDC.
        assertApproxEqAbs(adapter.currentValueUsdc(alice), 100e6, 1e4);

        // After 30 days the projected ratio bumps the spot value by ~0.33 USDC.
        vm.warp(block.timestamp + 30 days);
        _setEthPrice(3000_00000);
        uint256 valAfter = adapter.currentValueUsdc(alice);
        assertGt(valAfter, 100e6);
        assertApproxEqAbs(valAfter, 100_328_767, 1_000);

        // Price doubles → spot value doubles.
        _setEthPrice(6000_00000);
        uint256 valDoubled = adapter.currentValueUsdc(alice);
        assertApproxEqAbs(valDoubled, valAfter * 2, 1_000);

        // Sanity: also exposed via the IERC-style view.
        assertEq(adapter.valueInUSDC(alice), adapter.currentValueUsdc(alice));
        // Suppress unused-var warning for mEthOut.
        mEthOut;
    }

    // ─── multiple depositors ────────────────────────────────────────

    function test_multipleDepositors_trackedIndependently() public {
        _deposit(alice, 100e6);
        // Bob deposits 15 days later → shorter accrual.
        vm.warp(block.timestamp + 15 days);
        _setEthPrice(3000_00000);
        _deposit(bob, 100e6);

        vm.warp(block.timestamp + 15 days);
        _setEthPrice(3000_00000);

        uint256 aliceP = adapter.pendingYieldOf(alice);
        uint256 bobP   = adapter.pendingYieldOf(bob);
        assertGt(aliceP, bobP);
        // alice accrued over 30d on her balance, bob over 15d.
        assertApproxEqAbs(aliceP, 328_767, 1_000);
        assertApproxEqAbs(bobP,   164_383, 1_000);
    }

    // ─── exchangeRate projects forward ──────────────────────────────

    function test_exchangeRate_growsOverTime() public {
        uint256 r0 = adapter.exchangeRate();
        assertEq(r0, 1e18);

        vm.warp(block.timestamp + 365 days);
        uint256 r1 = adapter.exchangeRate();
        // Grows by ~4% (compounded once via additive formula).
        assertApproxEqAbs(r1, 1_040_000_000_000_000_000, 1e15);
    }
}
