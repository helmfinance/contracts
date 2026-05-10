// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOndoUSDYAdapter
/// @notice Wraps Ondo's USDY (yield-bearing tokenized US Treasuries). USDY rebases via
///         a growing per-share exchange rate; cash yield is realized on any partial redeem.
interface IOndoUSDYAdapter {
    event Deposited(address indexed holder, uint256 usdcIn, uint256 usdyOut);
    event Redeemed(address indexed holder, uint256 usdyIn, uint256 usdcOut);

    error OnlyRegisteredVault();
    error SlippageTooHigh(uint256 minOut, uint256 actualOut);

    function deposit(uint256 usdcAmount, uint256 minUsdyOut) external returns (uint256 usdyReceived);
    function redeem(uint256 usdyAmount, uint256 minUsdcOut) external returns (uint256 usdcOut);

    function balanceOfHolder(address holder) external view returns (uint256 usdyBalance);
    function valueInUSDC(address holder) external view returns (uint256);
    function exchangeRate() external view returns (uint256);   // USDY → USDC, 1e18 scaled

    /// @notice Realize accrued yield as USDC and forward to vault yield pool.
    function harvestYield(address holder) external returns (uint256 usdcOut);
}
