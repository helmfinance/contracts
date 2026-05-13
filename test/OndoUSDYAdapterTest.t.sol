// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {OndoUSDYAdapter} from "../src/adapters/OndoUSDYAdapter.sol";
import {IOndoUSDYAdapter} from "../src/interfaces/IOndoUSDYAdapter.sol";
import {TimeProvider} from "../src/system/TimeProvider.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OndoUSDYAdapterTest is Test {
    OndoUSDYAdapter adapter;
    MockERC20 usdc;
    TimeProvider timeProvider;

    address alice = address(0xA);
    address bob   = address(0xB);
    address harvester = address(0x14E);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        timeProvider = new TimeProvider();
        adapter = new OndoUSDYAdapter(address(usdc), address(timeProvider));
        usdc.addMinter(address(adapter));
    }

    function _deposit(address user, uint256 usdcAmt) internal returns (uint256 usdyOut) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(adapter), usdcAmt);
        usdyOut = adapter.deposit(usdcAmt, 0);
        vm.stopPrank();
    }

    // ─── constructor and constants ──────────────────────────────────

    function test_constructor_state() public view {
        assertEq(address(adapter.usdc()), address(usdc));
        assertEq(adapter.usdyPricePerShare(), 1e18);
        assertEq(adapter.SIMULATED_APY_BPS(), 500);
        assertEq(adapter.productionUsdyAddress(), adapter.ONDO_USDY_MAINNET());
        assertEq(adapter.productionOracleAddress(), adapter.ONDO_USDY_ORACLE_MAINNET());
    }

    // ─── deposit / redeem at price-per-share ────────────────────────

    function test_deposit_oneToOneAtT0() public {
        uint256 usdyOut = _deposit(alice, 100e6);
        assertEq(usdyOut, 100e18);
        assertEq(adapter.balanceOfHolder(alice), 100e18);
        assertEq(usdc.balanceOf(address(adapter)), 100e6);
    }

    function test_redeem_atT0_returnsPrincipal() public {
        uint256 usdyOut = _deposit(alice, 100e6);
        vm.prank(alice);
        uint256 usdcOut = adapter.redeem(usdyOut, 0);
        assertEq(usdcOut, 100e6);
        assertEq(adapter.balanceOfHolder(alice), 0);
    }

    function test_deposit_revertsBelowMinOut() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 100e6);
        vm.expectRevert();
        adapter.deposit(100e6, 200e18);
        vm.stopPrank();
    }

    // ─── price-per-share growth ─────────────────────────────────────

    function test_pricePerShare_growsMonotonically() public {
        uint256 p0 = adapter.usdyPricePerShare();
        vm.warp(block.timestamp + 30 days);
        uint256 p1 = adapter.exchangeRate(); // projected
        assertGt(p1, p0);
        vm.warp(block.timestamp + 30 days);
        uint256 p2 = adapter.exchangeRate();
        assertGt(p2, p1);
    }

    // ─── harvest @ 5% APY ───────────────────────────────────────────

    function test_harvest_after30Days_5pctAPY() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 30 days);

        // 100 × 5% × 30/365 ≈ 0.41096 USDC ≈ 410_958 base units.
        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);
        assertApproxEqAbs(yieldAmt, 410_958, 100);
        assertEq(usdc.balanceOf(harvester), yieldAmt);
        assertEq(adapter.pendingYieldOf(alice), 0);
    }

    function test_harvest_resetsAccrualTimer() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 30 days);
        vm.prank(harvester);
        uint256 first = adapter.harvestYield(alice);

        vm.prank(harvester);
        uint256 second = adapter.harvestYield(alice);
        assertEq(second, 0);

        // Second window starts from a slightly higher usdyPricePerShare
        // (compounding) so allow ~0.5% tolerance.
        vm.warp(block.timestamp + 30 days);
        vm.prank(harvester);
        uint256 third = adapter.harvestYield(alice);
        assertApproxEqAbs(third, first, 2_500);
    }

    function test_yield_oneYear_approximately5pct() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 365 days);
        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);

        // ~5 USDC over a year on 100 USDC principal.
        assertApproxEqAbs(yieldAmt, 5_000_000, 200_000);
    }

    // ─── redeem after growth includes yield via pricePerShare ───────

    function test_redeem_afterGrowth_includesPriceGain() public {
        uint256 usdyOut = _deposit(alice, 100e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        uint256 usdcOut = adapter.redeem(usdyOut, 0);

        // ~100.41 USDC after 30 days at 5% APY. Adapter mints the shortfall.
        assertApproxEqAbs(usdcOut, 100_410_958, 100);
    }

    // ─── multiple depositors ────────────────────────────────────────

    function test_multipleDepositors_trackedIndependently() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 15 days);
        _deposit(bob, 100e6);

        vm.warp(block.timestamp + 15 days);

        uint256 aliceP = adapter.pendingYieldOf(alice);
        uint256 bobP   = adapter.pendingYieldOf(bob);

        assertApproxEqAbs(aliceP, 410_958, 1_000);
        assertApproxEqAbs(bobP,   205_479, 1_000);
        assertGt(aliceP, bobP);
    }

    // ─── valueInUSDC reflects growth ────────────────────────────────

    function test_valueInUSDC_reflectsGrowth() public {
        _deposit(alice, 100e6);
        assertApproxEqAbs(adapter.valueInUSDC(alice), 100e6, 1);

        vm.warp(block.timestamp + 30 days);
        uint256 vAfter = adapter.valueInUSDC(alice);
        // ~100.41 USDC.
        assertApproxEqAbs(vAfter, 100_410_958, 100);
    }
}
