// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockYieldAdapter
/// @notice Mock mETH/USDY adapter that returns a configurable yield on harvestYield().
contract MockYieldAdapter {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    uint256 public yieldAmount;

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    function setYieldAmount(uint256 amount) external {
        yieldAmount = amount;
    }

    /// @dev Simulates harvesting yield — mints USDC to caller.
    function harvestYield(address) external returns (uint256) {
        if (yieldAmount == 0) return 0;
        uint256 amt = yieldAmount;
        yieldAmount = 0;
        // Transfer USDC to caller (harvester)
        usdc.safeTransfer(msg.sender, amt);
        return amt;
    }
}
