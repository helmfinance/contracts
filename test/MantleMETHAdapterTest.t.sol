// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {MantleMETHAdapter} from "../src/adapters/MantleMETHAdapter.sol";
import {IMantleMETHAdapter} from "../src/interfaces/IMantleMETHAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MantleMETHAdapterTest is Test {
    MantleMETHAdapter adapter;
    MockERC20 usdc;

    address alice = address(0xA);
    address bob   = address(0xB);
    address harvester = address(0x14E);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        adapter = new MantleMETHAdapter(address(usdc), 1e18);
        vm.warp(1_700_000_000);
    }

    function _deposit(address user, uint256 usdcAmt) internal returns (uint256 mEthOut) {
        usdc.mint(user, usdcAmt);
        vm.startPrank(user);
        usdc.approve(address(adapter), usdcAmt);
        mEthOut = adapter.deposit(usdcAmt, 0);
        vm.stopPrank();
    }

    function test_deposit_mintsMEthAtExchangeRate() public {
        uint256 mEthOut = _deposit(alice, 100e6); // 100 USDC
        assertEq(mEthOut, 100e18);
        assertEq(adapter.balanceOfHolder(alice), 100e18);
        assertEq(usdc.balanceOf(address(adapter)), 100e6);
    }

    function test_valueInUSDC_excludesYield() public {
        _deposit(alice, 100e6);
        // Even after time passes, valueInUSDC reflects only the principal.
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.valueInUSDC(alice), 100e6);
    }

    function test_harvest_after30Days_4pctAPY() public {
        _deposit(alice, 100e6); // 100 USDC of mETH

        vm.warp(block.timestamp + 30 days);

        // Expected: 100 × 4% × 30/365 ≈ 0.32877 USDC ≈ 328_767 base units.
        vm.prank(harvester);
        uint256 yieldAmt = adapter.harvestYield(alice);
        assertApproxEqAbs(yieldAmt, 328_767, 10);
        // Yield was minted to the harvester (the caller).
        assertEq(usdc.balanceOf(harvester), yieldAmt);
        // No more pending immediately after harvest.
        assertEq(adapter.pendingYieldOf(alice), 0);
    }

    function test_harvest_resetsAccrualTimer() public {
        _deposit(alice, 100e6);

        vm.warp(block.timestamp + 30 days);
        vm.prank(harvester);
        uint256 first = adapter.harvestYield(alice);

        // No additional time: nothing left to harvest.
        vm.prank(harvester);
        uint256 second = adapter.harvestYield(alice);
        assertEq(second, 0);

        // Another 30 days: similar amount accrues.
        vm.warp(block.timestamp + 30 days);
        vm.prank(harvester);
        uint256 third = adapter.harvestYield(alice);
        assertApproxEqAbs(third, first, 10);
    }

    function test_withdraw_includesPrincipalAndAccrued() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        uint256 out = adapter.withdraw(100e18, 0);

        // ≈ 100 USDC principal + 0.328 USDC yield.
        assertApproxEqAbs(out, 100_328_767, 10);
        assertEq(adapter.balanceOfHolder(alice), 0);
        // Alice received the USDC.
        assertEq(usdc.balanceOf(alice), out);
    }

    function test_multipleDepositors_trackedIndependently() public {
        _deposit(alice, 100e6);
        // Bob deposits later so his accrual window is shorter.
        vm.warp(block.timestamp + 15 days);
        _deposit(bob, 100e6);

        vm.warp(block.timestamp + 15 days);

        // Alice accrued over 30d, Bob over 15d.
        uint256 alicePending = adapter.pendingYieldOf(alice);
        uint256 bobPending   = adapter.pendingYieldOf(bob);

        assertApproxEqAbs(alicePending, 328_767, 10);
        assertApproxEqAbs(bobPending,   164_383, 10);
        assertGt(alicePending, bobPending);
    }

    function test_deposit_revertsBelowMinOut() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 100e6);
        vm.expectRevert();
        adapter.deposit(100e6, 200e18); // demand 200 mETH for 100 USDC — too much
        vm.stopPrank();
    }
}
