// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@pyth-sdk-solidity/PythStructs.sol";

/// @title MockPyth
/// @notice Minimal mock of the Pyth oracle for unit testing PythPriceAdapter.
contract MockPyth {
    mapping(bytes32 => PythStructs.Price) private _prices;
    uint256 private _updateFee;
    uint256 public lastUpdateValue;

    constructor(uint256 updateFee_) {
        _updateFee = updateFee_;
    }

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = PythStructs.Price({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: publishTime
        });
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return _updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= _updateFee, "insufficient fee");
        lastUpdateValue = msg.value;
    }
}
