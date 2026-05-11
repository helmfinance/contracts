// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IPythPriceAdapter.sol";
import "@pyth-sdk-solidity/IPyth.sol";
import "@pyth-sdk-solidity/PythStructs.sol";

/// @title PythPriceAdapter
/// @notice Wraps the Pyth pull oracle with per-feed staleness checks and normalized pricing.
/// @dev Each registered feed has its own max staleness window (crypto ~60s, equity ~96h).
contract PythPriceAdapter is IPythPriceAdapter {
    /// @notice Thrown when a feed is not registered in this adapter.
    error UnknownFeed(bytes32 feedId);

    /// @notice The underlying Pyth oracle contract.
    IPyth public immutable pyth;

    /// @notice Per-feed maximum staleness in seconds.
    mapping(bytes32 => uint64) public maxStaleness;

    /// @notice Whether a feed has been registered.
    mapping(bytes32 => bool) public feedRegistered;

    /// @param _pyth Address of the Pyth oracle contract.
    /// @param feedIds Array of Pyth feed identifiers to register.
    /// @param maxStaleSeconds Corresponding max staleness window for each feed.
    constructor(address _pyth, bytes32[] memory feedIds, uint64[] memory maxStaleSeconds) {
        require(feedIds.length == maxStaleSeconds.length, "length mismatch");
        pyth = IPyth(_pyth);
        for (uint256 i = 0; i < feedIds.length; i++) {
            feedRegistered[feedIds[i]] = true;
            maxStaleness[feedIds[i]] = maxStaleSeconds[i];
        }
    }

    /// @inheritdoc IPythPriceAdapter
    function getPrice(bytes32 feedId)
        external
        view
        returns (uint256 price, uint8 decimals, uint64 publishTime)
    {
        if (!feedRegistered[feedId]) revert UnknownFeed(feedId);

        PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);

        if (p.price <= 0) revert PriceNegative(feedId, int256(p.price));

        uint64 maxAge = maxStaleness[feedId];
        if (block.timestamp - p.publishTime > maxAge) {
            revert PriceStale(feedId, uint64(p.publishTime), maxAge);
        }

        price = _normalize(uint256(uint64(p.price)), p.expo, 18);
        decimals = 18;
        publishTime = uint64(p.publishTime);
    }

    /// @inheritdoc IPythPriceAdapter
    function getPriceWithMaxAge(bytes32 feedId, uint64 maxAgeSeconds)
        external
        view
        returns (uint256 price)
    {
        if (!feedRegistered[feedId]) revert UnknownFeed(feedId);

        PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);

        if (p.price <= 0) revert PriceNegative(feedId, int256(p.price));

        if (block.timestamp - p.publishTime > maxAgeSeconds) {
            revert PriceStale(feedId, uint64(p.publishTime), maxAgeSeconds);
        }

        price = _normalize(uint256(uint64(p.price)), p.expo, 18);
    }

    /// @notice Latest price normalized to 6 decimals (USDC scale), using per-feed staleness.
    /// @param feedId Pyth feed identifier.
    /// @return price Price in 6-decimal (USDC) format.
    function getPriceUsdc(bytes32 feedId) external view returns (uint256 price) {
        if (!feedRegistered[feedId]) revert UnknownFeed(feedId);

        PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);

        if (p.price <= 0) revert PriceNegative(feedId, int256(p.price));

        uint64 maxAge = maxStaleness[feedId];
        if (block.timestamp - p.publishTime > maxAge) {
            revert PriceStale(feedId, uint64(p.publishTime), maxAge);
        }

        price = _normalize(uint256(uint64(p.price)), p.expo, 6);
    }

    /// @inheritdoc IPythPriceAdapter
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientUpdateFee(msg.value, fee);
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }

    /// @inheritdoc IPythPriceAdapter
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }

    /// @notice Convert a raw Pyth price with its expo to a fixed-point number with targetDecimals.
    /// @dev Pyth price = rawPrice * 10^expo. Result = rawPrice * 10^(expo + targetDecimals).
    function _normalize(uint256 rawPrice, int32 expo, uint8 targetDecimals) internal pure returns (uint256) {
        int256 adjustedExpo = int256(int32(expo)) + int256(uint256(targetDecimals));
        if (adjustedExpo >= 0) {
            return rawPrice * (10 ** uint256(adjustedExpo));
        } else {
            return rawPrice / (10 ** uint256(-adjustedExpo));
        }
    }
}
