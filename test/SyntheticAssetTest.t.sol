// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/adapters/SyntheticAsset.sol";
import "../src/adapters/PythPriceAdapter.sol";
import "./mocks/MockPyth.sol";
import "./mocks/MockERC20.sol";

contract SyntheticAssetTest is Test {
    SyntheticAsset synth;
    PythPriceAdapter adapter;
    MockPyth mockPyth;
    MockERC20 usdc;

    bytes32 constant FEED_ID = keccak256("NVDA/USD");
    uint64 constant STALENESS = 96 hours;
    uint256 constant UPDATE_FEE = 1;

    address vaultA = address(0xA);
    address vaultB = address(0xB);
    address recipient = address(0xC);

    function setUp() public {
        mockPyth = new MockPyth(UPDATE_FEE);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        bytes32[] memory feedIds = new bytes32[](1);
        uint64[] memory maxStale = new uint64[](1);
        feedIds[0] = FEED_ID;
        maxStale[0] = STALENESS;
        adapter = new PythPriceAdapter(address(mockPyth), feedIds, maxStale);

        synth = new SyntheticAsset(
            "Synthetic NVIDIA",
            "sNVDA",
            "NVDA",
            FEED_ID,
            address(adapter),
            address(usdc)
        );

        synth.registerVault(vaultA);
        synth.registerVault(vaultB);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Set Pyth price. priceUsd is in whole dollars (e.g. 950 = $950).
    function _setPrice(uint256 priceUsd) internal {
        // expo=-2, so raw = priceUsd * 100 for cents precision
        int64 raw = int64(int256(priceUsd * 100));
        vm.warp(1_000_000);
        mockPyth.setPrice(FEED_ID, raw, 50, -2, 1_000_000);
    }

    /// @dev Set price with a specific raw/expo for finer control.
    function _setPriceRaw(int64 raw, int32 expo, uint256 publishTime) internal {
        vm.warp(publishTime);
        mockPyth.setPrice(FEED_ID, raw, 50, expo, publishTime);
    }

    /// @dev Fund vault with USDC and approve synth.
    function _fundVault(address vault, uint256 usdcAmount) internal {
        usdc.mint(vault, usdcAmount);
        vm.prank(vault);
        usdc.approve(address(synth), usdcAmount);
    }

    // ---------------------------------------------------------------
    // Mint → burn at same price returns full USDC (minus rounding)
    // ---------------------------------------------------------------

    function test_mintBurn_samePriceReturnsFullUsdc() public {
        _setPrice(950); // $950
        uint256 usdcIn = 950_000_000; // 950 USDC

        _fundVault(vaultA, usdcIn);

        vm.prank(vaultA);
        uint256 shares = synth.mint(recipient, usdcIn);

        // Should get 1e18 shares (1 sNVDA at $950)
        assertEq(shares, 1e18);
        assertEq(synth.balanceOf(vaultA), 1e18);

        // Burn all shares at same price
        vm.prank(vaultA);
        uint256 usdcOut = synth.burn(recipient, shares);

        assertEq(usdcOut, usdcIn);
        assertEq(usdc.balanceOf(recipient), usdcIn);
        assertEq(synth.balanceOf(vaultA), 0);
    }

    // ---------------------------------------------------------------
    // Capital gain: price doubles → 2x USDC back
    // ---------------------------------------------------------------

    function test_mintBurn_priceDoubles_capitalGain() public {
        _setPrice(500); // mint at $500
        uint256 usdcIn = 500_000_000; // 500 USDC → 1 share

        _fundVault(vaultA, usdcIn);

        vm.prank(vaultA);
        uint256 shares = synth.mint(recipient, usdcIn);
        assertEq(shares, 1e18);

        // Price doubles to $1000
        _setPrice(1000);

        // Fund synth contract with extra USDC to cover the gain
        usdc.mint(address(synth), 500_000_000);

        vm.prank(vaultA);
        uint256 usdcOut = synth.burn(recipient, shares);

        // 1 share * $1000 = 1000 USDC
        assertEq(usdcOut, 1_000_000_000);
    }

    // ---------------------------------------------------------------
    // Loss: price halves → 0.5x USDC back
    // ---------------------------------------------------------------

    function test_mintBurn_priceHalves_loss() public {
        _setPrice(1000); // mint at $1000
        uint256 usdcIn = 1_000_000_000; // 1000 USDC → 1 share

        _fundVault(vaultA, usdcIn);

        vm.prank(vaultA);
        uint256 shares = synth.mint(recipient, usdcIn);
        assertEq(shares, 1e18);

        // Price halves to $500
        _setPrice(500);

        vm.prank(vaultA);
        uint256 usdcOut = synth.burn(recipient, shares);

        // 1 share * $500 = 500 USDC
        assertEq(usdcOut, 500_000_000);
    }

    // ---------------------------------------------------------------
    // Vault A cannot burn vault B's shares
    // ---------------------------------------------------------------

    function test_burn_cannotBurnOtherVaultShares() public {
        _setPrice(100);
        uint256 usdcIn = 100_000_000;

        _fundVault(vaultA, usdcIn);

        vm.prank(vaultA);
        uint256 shares = synth.mint(recipient, usdcIn);

        // vaultB tries to burn — has 0 balance
        vm.prank(vaultB);
        vm.expectRevert("insufficient balance");
        synth.burn(recipient, shares);
    }

    // ---------------------------------------------------------------
    // Reverts on stale price
    // ---------------------------------------------------------------

    function test_mint_revertsOnStalePrice() public {
        // Set price published long ago
        _setPriceRaw(95012, -2, 100_000);
        vm.warp(100_000 + uint256(STALENESS) + 1);

        _fundVault(vaultA, 1_000_000);
        vm.prank(vaultA);
        vm.expectRevert(); // PriceStale from PythPriceAdapter
        synth.mint(recipient, 1_000_000);
    }

    function test_burn_revertsOnStalePrice() public {
        _setPrice(100);
        uint256 usdcIn = 100_000_000;
        _fundVault(vaultA, usdcIn);

        vm.prank(vaultA);
        uint256 shares = synth.mint(recipient, usdcIn);

        // Advance time past staleness
        vm.warp(block.timestamp + uint256(STALENESS) + 1);

        vm.prank(vaultA);
        vm.expectRevert(); // PriceStale
        synth.burn(recipient, shares);
    }

    // ---------------------------------------------------------------
    // Only registered vault
    // ---------------------------------------------------------------

    function test_mint_revertsForUnregisteredVault() public {
        _setPrice(100);
        address rando = address(0xDEAD);
        _fundVault(rando, 100_000_000);

        vm.prank(rando);
        vm.expectRevert(ISyntheticAsset.OnlyRegisteredVault.selector);
        synth.mint(recipient, 100_000_000);
    }

    function test_burn_revertsForUnregisteredVault() public {
        address rando = address(0xDEAD);
        vm.prank(rando);
        vm.expectRevert(ISyntheticAsset.OnlyRegisteredVault.selector);
        synth.burn(recipient, 1e18);
    }

    // ---------------------------------------------------------------
    // Non-transferable
    // ---------------------------------------------------------------

    function test_transfer_reverts() public {
        vm.expectRevert(SyntheticAsset.NonTransferable.selector);
        synth.transfer(address(1), 1);
    }

    function test_approve_reverts() public {
        vm.expectRevert(SyntheticAsset.NonTransferable.selector);
        synth.approve(address(1), 1);
    }

    function test_transferFrom_reverts() public {
        vm.expectRevert(SyntheticAsset.NonTransferable.selector);
        synth.transferFrom(address(1), address(2), 1);
    }

    // ---------------------------------------------------------------
    // priceUSDC
    // ---------------------------------------------------------------

    function test_priceUSDC_returnsCorrectValue() public {
        _setPrice(950); // $950 → 950_000_000 in 6 dec
        assertEq(synth.priceUSDC(), 950_000_000);
    }

    // ---------------------------------------------------------------
    // ERC-20 metadata
    // ---------------------------------------------------------------

    function test_metadata() public view {
        assertEq(synth.name(), "Synthetic NVIDIA");
        assertEq(synth.symbol(), "sNVDA");
        assertEq(synth.decimals(), 18);
    }
}
