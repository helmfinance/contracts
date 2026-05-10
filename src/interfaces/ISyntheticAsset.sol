// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISyntheticAsset
/// @notice Pyth-priced synthetic equity (sNVDA, sSPY, sMSFT, etc.). 1 unit tracks the
///         underlying spot price reported by Pyth. Backed by USDC collateral held inside
///         the agent vault — no external counterparty.
/// @dev    Mintable / burnable only by registered agent vaults. Price freshness enforced
///         per call via the linked PythPriceAdapter.
interface ISyntheticAsset is IERC20 {
    event Minted(address indexed to, uint256 syntheticOut, uint256 usdcIn, uint256 priceUsed);
    event Burned(address indexed from, uint256 syntheticIn, uint256 usdcOut, uint256 priceUsed);

    error OnlyRegisteredVault();
    error PriceStale(uint64 lastUpdate, uint64 maxAge);

    function symbol() external view returns (string memory);   // "sNVDA"
    function pythFeedId() external view returns (bytes32);

    /// @notice Current price in USDC (1e6 scaled).
    function priceUSDC() external view returns (uint256);

    /// @notice Mint synthetic tokens, depositing USDC collateral.
    /// @return syntheticOut Synthetic units minted at the current Pyth price.
    function mint(address to, uint256 usdcCollateral) external returns (uint256 syntheticOut);

    /// @notice Burn synthetic tokens, withdrawing USDC at the current Pyth price.
    function burn(address from, uint256 syntheticIn) external returns (uint256 usdcOut);
}
