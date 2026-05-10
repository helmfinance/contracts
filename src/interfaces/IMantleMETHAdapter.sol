// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMantleMETHAdapter
/// @notice Wraps Mantle's mETH liquid staking. Yield = ETH staking rewards, captured
///         through `exchangeRate` growth. The adapter normalizes deposits in USDC by
///         routing USDC → ETH (via Merchant Moe) → stake → mETH, and the reverse on exit.
/// @dev    `harvestYield` returns 0 directly because mETH yield is reflected in price
///         growth rather than periodic distributions. The vault realizes yield on any
///         partial unstake. Implementation may instead snapshot exchange rate and convert
///         the gain to USDC on a schedule.
interface IMantleMETHAdapter {
    event Deposited(address indexed holder, uint256 usdcIn, uint256 mEthOut);
    event Withdrawn(address indexed holder, uint256 mEthIn, uint256 usdcOut);

    error OnlyRegisteredVault();
    error SlippageTooHigh(uint256 minOut, uint256 actualOut);

    function deposit(uint256 usdcAmount, uint256 minMEthOut) external returns (uint256 mEthReceived);
    function withdraw(uint256 mEthAmount, uint256 minUsdcOut) external returns (uint256 usdcReceived);

    function balanceOfHolder(address holder) external view returns (uint256 mEthBalance);
    function valueInUSDC(address holder) external view returns (uint256);
    function exchangeRate() external view returns (uint256);   // mETH → ETH, 1e18 scaled

    /// @notice Convert accrued exchange-rate gain to USDC and forward to vault yield pool.
    function harvestYield(address holder) external returns (uint256 usdcOut);
}
