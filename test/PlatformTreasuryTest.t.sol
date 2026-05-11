// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {PlatformTreasury} from "../src/system/PlatformTreasury.sol";
import {IPlatformTreasury} from "../src/interfaces/IPlatformTreasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PlatformTreasuryTest is Test {
    PlatformTreasury treasury;
    MockERC20 usdc;

    address admin = address(0xA1);
    address vault = address(0xBEEF);
    address alice = address(0xA);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        treasury = new PlatformTreasury(address(usdc), admin);
    }

    function test_constructor_initialRates() public view {
        (uint256 m, uint256 r, uint256 rb) = treasury.feeRates();
        assertEq(m,  50);
        assertEq(r,  50);
        assertEq(rb, 5);
        assertEq(treasury.feeRate(IPlatformTreasury.FeeKind.Mint),      50);
        assertEq(treasury.feeRate(IPlatformTreasury.FeeKind.Redeem),    50);
        assertEq(treasury.feeRate(IPlatformTreasury.FeeKind.Rebalance), 5);
    }

    function test_setFeeRates_updatesAll() public {
        vm.prank(admin);
        treasury.setFeeRates(75, 25, 10);
        (uint256 m, uint256 r, uint256 rb) = treasury.feeRates();
        assertEq(m,  75);
        assertEq(r,  25);
        assertEq(rb, 10);
    }

    function test_setFeeRate_singleKind() public {
        vm.prank(admin);
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint, 200);
        assertEq(treasury.feeRate(IPlatformTreasury.FeeKind.Mint), 200);
        // Other kinds untouched.
        assertEq(treasury.feeRate(IPlatformTreasury.FeeKind.Redeem), 50);
    }

    function test_setFeeRates_revertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPlatformTreasury.FeeRateTooHigh.selector, 1_000));
        treasury.setFeeRates(1_001, 50, 5);
    }

    function test_setFeeRate_revertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPlatformTreasury.FeeRateTooHigh.selector, 1_000));
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint, 1_001);
    }

    function test_setFeeRates_revertsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IPlatformTreasury.OnlyAdmin.selector);
        treasury.setFeeRates(60, 60, 6);
    }

    function test_collectFee_accumulates() public {
        // Pretend a vault paid 100 USDC of fees split into two events.
        usdc.mint(address(treasury), 100e6);
        vm.prank(vault);
        treasury.collectFee(1, IPlatformTreasury.FeeKind.Mint, 60e6);
        vm.prank(vault);
        treasury.collectFee(1, IPlatformTreasury.FeeKind.Redeem, 40e6);

        assertEq(treasury.totalFeesCollected(), 100e6);
        assertEq(treasury.feesCollectedFor(1),  100e6);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
    }

    function test_withdraw_admin() public {
        usdc.mint(address(treasury), 100e6);

        vm.prank(admin);
        treasury.withdraw(alice, 40e6);
        assertEq(usdc.balanceOf(alice), 40e6);
        assertEq(usdc.balanceOf(address(treasury)), 60e6);
    }

    function test_withdraw_revertsNonAdmin() public {
        usdc.mint(address(treasury), 10e6);
        vm.prank(alice);
        vm.expectRevert(IPlatformTreasury.OnlyAdmin.selector);
        treasury.withdraw(alice, 1e6);
    }

    function test_transferAdmin() public {
        address newAdmin = address(0xA2);
        vm.prank(admin);
        treasury.transferAdmin(newAdmin);
        assertEq(treasury.admin(), newAdmin);

        // Old admin can no longer act.
        vm.prank(admin);
        vm.expectRevert(IPlatformTreasury.OnlyAdmin.selector);
        treasury.setFeeRates(10, 10, 10);

        // New admin can.
        vm.prank(newAdmin);
        treasury.setFeeRates(10, 10, 10);
    }
}
