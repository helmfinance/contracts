// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/AgentToken.sol";

contract AgentTokenTest is Test {
    AgentToken token;

    address vault = address(0x1234);
    address alice = address(0xA);
    address bob = address(0xB);
    uint256 constant AGENT_ID = 42;

    function setUp() public {
        token = new AgentToken("Agent 42 Shares", "AGT-42", vault, AGENT_ID);
    }

    // ---------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Agent 42 Shares");
        assertEq(token.symbol(), "AGT-42");
        assertEq(token.decimals(), 18);
        assertEq(token.vault(), vault);
        assertEq(token.agentId(), AGENT_ID);
    }

    // ---------------------------------------------------------------
    // Vault can mint and burn
    // ---------------------------------------------------------------

    function test_vault_canMint() public {
        vm.prank(vault);
        token.mint(alice, 100e18);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_vault_canBurn() public {
        vm.prank(vault);
        token.mint(alice, 100e18);

        vm.prank(vault);
        token.burn(alice, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    // ---------------------------------------------------------------
    // Non-vault mint/burn reverts
    // ---------------------------------------------------------------

    function test_nonVault_mintReverts() public {
        vm.prank(alice);
        vm.expectRevert(IAgentToken.OnlyVault.selector);
        token.mint(alice, 1e18);
    }

    function test_nonVault_burnReverts() public {
        vm.prank(vault);
        token.mint(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(IAgentToken.OnlyVault.selector);
        token.burn(alice, 1e18);
    }

    // ---------------------------------------------------------------
    // Standard ERC-20 transfer
    // ---------------------------------------------------------------

    function test_transfer() public {
        vm.prank(vault);
        token.mint(alice, 50e18);

        vm.prank(alice);
        token.transfer(bob, 20e18);

        assertEq(token.balanceOf(alice), 30e18);
        assertEq(token.balanceOf(bob), 20e18);
    }

    // ---------------------------------------------------------------
    // Approval and transferFrom
    // ---------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(vault);
        token.mint(alice, 50e18);

        vm.prank(alice);
        token.approve(bob, 30e18);
        assertEq(token.allowance(alice, bob), 30e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 25e18);

        assertEq(token.balanceOf(alice), 25e18);
        assertEq(token.balanceOf(bob), 25e18);
        assertEq(token.allowance(alice, bob), 5e18);
    }

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    function test_mint_emitsEvent() public {
        vm.prank(vault);
        vm.expectEmit(true, false, false, true);
        emit IAgentToken.MintedByVault(alice, 10e18);
        token.mint(alice, 10e18);
    }

    function test_burn_emitsEvent() public {
        vm.prank(vault);
        token.mint(alice, 10e18);

        vm.prank(vault);
        vm.expectEmit(true, false, false, true);
        emit IAgentToken.BurnedByVault(alice, 5e18);
        token.burn(alice, 5e18);
    }
}
