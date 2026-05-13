// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract MockERC20Test is Test {
    MockERC20 usdc;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address adapter = makeAddr("adapter");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    // ─── constructor ────────────────────────────────────────────────

    function test_constructor_setsDeployerAsMinterAdmin() public view {
        assertEq(usdc.minterAdmin(), address(this));
        assertFalse(usdc.minters(address(this)));
        assertEq(usdc.decimals(), 6);
    }

    // ─── add/remove minter ──────────────────────────────────────────

    function test_addMinter_byAdmin() public {
        usdc.addMinter(adapter);
        assertTrue(usdc.minters(adapter));
    }

    function test_addMinter_byNonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MockERC20.NotMinterAdmin.selector);
        usdc.addMinter(adapter);
    }

    function test_removeMinter_byAdmin() public {
        usdc.addMinter(adapter);
        usdc.removeMinter(adapter);
        assertFalse(usdc.minters(adapter));
    }

    function test_removeMinter_byNonAdmin_reverts() public {
        usdc.addMinter(adapter);
        vm.prank(alice);
        vm.expectRevert(MockERC20.NotMinterAdmin.selector);
        usdc.removeMinter(adapter);
    }

    // ─── mint authority ─────────────────────────────────────────────

    function test_mint_byMinterAdmin_succeeds() public {
        usdc.mint(alice, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_mint_byRegisteredMinter_succeedsOnTestnet() public {
        usdc.addMinter(adapter);
        vm.chainId(5003);
        vm.prank(adapter);
        usdc.mint(bob, 50e6);
        assertEq(usdc.balanceOf(bob), 50e6);
    }

    function test_mint_byRegisteredMinter_succeedsOnAnvil() public {
        usdc.addMinter(adapter);
        // chainId 31337 is the foundry default, but be explicit.
        vm.chainId(31337);
        vm.prank(adapter);
        usdc.mint(bob, 50e6);
        assertEq(usdc.balanceOf(bob), 50e6);
    }

    function test_mint_byRegisteredMinter_revertsOnMainnet() public {
        usdc.addMinter(adapter);
        vm.chainId(1); // Ethereum mainnet
        vm.prank(adapter);
        vm.expectRevert(MockERC20.NotMinter.selector);
        usdc.mint(bob, 50e6);
    }

    function test_mint_byUnregisteredCaller_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MockERC20.NotMinter.selector);
        usdc.mint(bob, 1e6);
    }

    function test_mint_byRemovedMinter_reverts() public {
        usdc.addMinter(adapter);
        usdc.removeMinter(adapter);
        vm.prank(adapter);
        vm.expectRevert(MockERC20.NotMinter.selector);
        usdc.mint(bob, 1e6);
    }

    // ─── admin transfer ─────────────────────────────────────────────

    function test_transferMinterAdmin() public {
        usdc.transferMinterAdmin(alice);
        assertEq(usdc.minterAdmin(), alice);

        // Old admin can no longer mint.
        vm.expectRevert(MockERC20.NotMinter.selector);
        usdc.mint(bob, 1e6);

        // New admin can.
        vm.prank(alice);
        usdc.mint(bob, 1e6);
        assertEq(usdc.balanceOf(bob), 1e6);
    }

    function test_transferMinterAdmin_byNonAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert(MockERC20.NotMinterAdmin.selector);
        usdc.transferMinterAdmin(bob);
    }
}
