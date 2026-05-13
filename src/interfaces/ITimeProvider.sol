// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITimeProvider
/// @notice Returns the effective system time. On testnet / local chains this
///         is `block.timestamp + timeOffset` where an admin may advance the
///         offset to demo time-dependent flows; on production it always
///         returns `block.timestamp` because the admin cannot advance.
interface ITimeProvider {
    /// @notice Effective system time (seconds since unix epoch).
    function currentTime() external view returns (uint256);
}
