// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPythPriceAdapter
/// @notice Thin wrapper over the Pyth pull oracle with built-in staleness checks and
///         normalized 1e18 scaling. SyntheticAsset.priceUSDC reads through this.
/// @dev    Pyth requires `updatePriceFeeds` to be called with signed update bytes (and
///         a small fee in native ETH/MNT) before reads will reflect the latest price.
///         The BE cron pushes updates ahead of every rebalance.
interface IPythPriceAdapter {
    error PriceStale(bytes32 feedId, uint64 publishTime, uint64 maxAge);
    error PriceNegative(bytes32 feedId, int256 raw);
    error InsufficientUpdateFee(uint256 sent, uint256 required);

    /// @notice Latest price (normalized to 1e18) and metadata.
    /// @param feedId Pyth feed identifier.
    function getPrice(bytes32 feedId)
        external
        view
        returns (uint256 price, uint8 decimals, uint64 publishTime);

    /// @notice Latest price, reverting if older than `maxAgeSeconds`.
    function getPriceWithMaxAge(bytes32 feedId, uint64 maxAgeSeconds)
        external
        view
        returns (uint256 price);

    /// @notice Forward signed price-update payload + fee to the Pyth contract.
    /// @param updateData Signed payload from Hermes (off-chain Pyth API).
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Required fee for a given updateData payload.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}
