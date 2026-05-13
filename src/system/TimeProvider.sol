// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITimeProvider} from "../interfaces/ITimeProvider.sol";

/// @title TimeProvider
/// @notice Singleton clock used by every time-dependent Helm contract. On
///         Mantle Sepolia (5003) and local Foundry/anvil (31337) — both
///         `devEnabled` — an admin can {advance} the offset to fast-forward
///         lockups, incubation, redemption windows, etc. for demos. On any
///         other chain `devEnabled == false` so the admin cannot advance,
///         keeping production time unmanipulable.
/// @dev Renamed the spec's `now()` to {currentTime} because `now` is the
///      legacy Solidity ≤0.6 alias for `block.timestamp` and reusing the
///      name as a function identifier confuses readers.
contract TimeProvider is ITimeProvider {
    /// @notice Additional seconds added on top of `block.timestamp`.
    uint256 public timeOffset;

    /// @notice Admin authorized to advance/reset offset (testnet only).
    address public admin;

    /// @notice True only on testnet/local chains. Frozen at construction.
    bool public immutable devEnabled;

    error NotAdmin();
    error NotDevEnabled();

    event TimeAdvanced(uint256 secondsAdded, uint256 newOffset, uint256 currentBlockTime);
    event TimeReset(uint256 previousOffset);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        admin = msg.sender;
        devEnabled = (block.chainid == 5003 || block.chainid == 31337);
        emit AdminTransferred(address(0), msg.sender);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyDevEnabled() {
        if (!devEnabled) revert NotDevEnabled();
        _;
    }

    /// @inheritdoc ITimeProvider
    function currentTime() external view override returns (uint256) {
        return block.timestamp + timeOffset;
    }

    /// @notice Advance the demo clock by `secondsToAdd`. Testnet/local only.
    function advance(uint256 secondsToAdd) external onlyAdmin onlyDevEnabled {
        timeOffset += secondsToAdd;
        emit TimeAdvanced(secondsToAdd, timeOffset, block.timestamp);
    }

    /// @notice Wipe the offset back to 0. Testnet/local only.
    function reset() external onlyAdmin onlyDevEnabled {
        emit TimeReset(timeOffset);
        timeOffset = 0;
    }

    /// @notice Hand admin authority to a new address.
    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }
}
