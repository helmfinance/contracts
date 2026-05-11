// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {OndoUSDYAdapter} from "../src/adapters/OndoUSDYAdapter.sol";
import {IOndoUSDYAdapter} from "../src/interfaces/IOndoUSDYAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OndoUSDYAdapterTest is Test {
    OndoUSDYAdapter adapter;
    MockERC20 usdc;

    address alice = address(0xA);
    address bob   = address(0xB);
    address harvester = address(0x14E);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        adapter = new OndoUSDYAdapter(address(usdc), 1e18);
        vm.warp(1_700_000_000);
    }

    function _deposit(address user, uint256 usdcAmt) internal returns (uint256 usdyOut) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(adapter), usdcAmt);
        usdyOut = adapter.deposit(usdcAmt, 0);
        vm.stopPrank();
    }

    function test_deposit_mintsUsdyAtExchangeRate() public {
        uint256 usdyOut = _deposit(alice, 100e6);
        assertEq(usdyOut, 100e18);
        assertEq(adapter.balanceOfHolder(alice), 100e18);
        assertEq(usdc.balanceOf(address(adapter)), 100e6);
    }

    function test_valueInUSDC_excludesYield() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.valueInUSDC(alice), 100e6);
    }

    function test_harvest_after30Days_5pctAPY() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 30 days);

        // Expected: 100 × 5% × 30/365 ≈ 0.41096 USDC ≈ 410_958 base units.
        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);
        assertApproxEqAbs(yieldAmt, 410_958, 10);
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

        vm.warp(block.timestamp + 30 days);
        vm.prank(harvester);
        uint256 third = adapter.harvestYield(alice);
        assertApproxEqAbs(third, first, 10);
    }

    function test_redeem_includesPrincipalAndAccrued() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        uint256 out = adapter.redeem(100e18, 0);

        // ≈ 100 USDC principal + 0.41 USDC yield.
        assertApproxEqAbs(out, 100_410_958, 10);
        assertEq(adapter.balanceOfHolder(alice), 0);
        assertEq(usdc.balanceOf(alice), out);
    }

    function test_multipleDepositors_trackedIndependently() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 15 days);
        _deposit(bob, 100e6);

        vm.warp(block.timestamp + 15 days);

        uint256 alicePending = adapter.pendingYieldOf(alice);
        uint256 bobPending   = adapter.pendingYieldOf(bob);

        assertApproxEqAbs(alicePending, 410_958, 10);
        assertApproxEqAbs(bobPending,   205_479, 10);
        assertGt(alicePending, bobPending);
    }

    function test_deposit_revertsBelowMinOut() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 100e6);
        vm.expectRevert();
        adapter.deposit(100e6, 200e18);
        vm.stopPrank();
    }
}
