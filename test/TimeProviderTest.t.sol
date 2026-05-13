// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {TimeProvider} from "../src/system/TimeProvider.sol";

contract TimeProviderTest is Test {
    TimeProvider tp;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        // Foundry's default chainId is 31337 → devEnabled = true.
        tp = new TimeProvider();
        vm.warp(1_700_000_000);
    }

    // ─── constructor ────────────────────────────────────────────────

    function test_constructor_defaultsAreSane() public view {
        assertEq(tp.admin(), address(this));
        assertEq(tp.timeOffset(), 0);
        assertTrue(tp.devEnabled()); // chainId 31337
    }

    // ─── currentTime ────────────────────────────────────────────────

    function test_currentTime_zeroOffset_returnsBlockTimestamp() public view {
        assertEq(tp.currentTime(), block.timestamp);
    }

    function test_currentTime_withOffset_returnsBlockTimestampPlusOffset() public {
        tp.advance(1 days);
        assertEq(tp.currentTime(), block.timestamp + 1 days);
    }

    function test_currentTime_vmWarpAddsToCurrentTime() public {
        tp.advance(3 days);
        uint256 before = tp.currentTime();
        vm.warp(block.timestamp + 1 days);
        assertEq(tp.currentTime(), before + 1 days);
    }

    // ─── advance ────────────────────────────────────────────────────

    function test_advance_addsToOffset() public {
        tp.advance(30 days);
        assertEq(tp.timeOffset(), 30 days);
        tp.advance(60 days);
        assertEq(tp.timeOffset(), 90 days);
    }

    function test_advance_byNonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(TimeProvider.NotAdmin.selector);
        tp.advance(1 days);
    }

    function test_advance_onMainnet_reverts() public {
        vm.chainId(1);
        TimeProvider mainnetTp = new TimeProvider();
        assertFalse(mainnetTp.devEnabled());
        vm.expectRevert(TimeProvider.NotDevEnabled.selector);
        mainnetTp.advance(1 days);
    }

    // ─── reset ──────────────────────────────────────────────────────

    function test_reset_returnsOffsetToZero() public {
        tp.advance(30 days);
        tp.reset();
        assertEq(tp.timeOffset(), 0);
        assertEq(tp.currentTime(), block.timestamp);
    }

    function test_reset_byNonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(TimeProvider.NotAdmin.selector);
        tp.reset();
    }

    function test_reset_onMainnet_reverts() public {
        vm.chainId(1);
        TimeProvider mainnetTp = new TimeProvider();
        vm.expectRevert(TimeProvider.NotDevEnabled.selector);
        mainnetTp.reset();
    }

    // ─── transferAdmin ──────────────────────────────────────────────

    function test_transferAdmin() public {
        tp.transferAdmin(alice);
        assertEq(tp.admin(), alice);

        // New admin can advance.
        vm.prank(alice);
        tp.advance(1 days);
        assertEq(tp.timeOffset(), 1 days);

        // Old admin can't.
        vm.expectRevert(TimeProvider.NotAdmin.selector);
        tp.advance(1 days);
    }

    function test_transferAdmin_byNonAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert(TimeProvider.NotAdmin.selector);
        tp.transferAdmin(bob);
    }

    // ─── demo-style multi-period fast-forward ──────────────────────

    function test_fastForward_thirtyDays_thenSixMonths_thenNinetyDays() public {
        uint256 t0 = tp.currentTime();
        tp.advance(30 days);
        assertEq(tp.currentTime(), t0 + 30 days);

        tp.advance(180 days);
        assertEq(tp.currentTime(), t0 + 30 days + 180 days);

        tp.advance(90 days);
        assertEq(tp.currentTime(), t0 + 30 days + 180 days + 90 days);
    }
}
