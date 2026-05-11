// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOndoUSDYAdapter} from "../interfaces/IOndoUSDYAdapter.sol";

/// @dev Minimal interface used to mint simulated yield in the mock. Any
///      mintable testnet USDC (e.g. MockERC20) satisfies this.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

// TODO(human): replace this mock with the real Ondo USDY contract on Mantle
//              (USDC → USDY redeem path, real rebase accrual) before mainnet
//              deployment. The mock simulates a constant 5% APY by minting
//              USDC on harvest — works against a mintable testnet USDC only.

/// @title OndoUSDYAdapter (MOCK)
/// @notice Hackathon stub for Ondo's USDY (tokenised US Treasuries).
///         Simulates a constant 5% APY on the depositor's USDC balance. The
///         exchange rate is fixed for the mock — actual USDY rebase growth
///         is not modelled.
/// @dev Per-holder yield accrual: yield = balanceUsdc × 5% × dt / 365 days.
///      harvestYield realises it to USDC (minted via IMintableUSDC) and
///      resets the accrual timestamp.
contract OndoUSDYAdapter is IOndoUSDYAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant APY_BPS         = 500;          // 5%
    uint256 internal constant BPS_DENOM       = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SCALE           = 1e18;

    /// @notice USDC token (must be mintable for the mock yield path).
    IERC20 public immutable usdc;

    /// @inheritdoc IOndoUSDYAdapter
    uint256 public override exchangeRate; // 1e18 fixed; default 1e18 = 1:1

    mapping(address => uint256) internal _balances;        // USDY balance, 18-dec
    mapping(address => uint256) internal _pendingYield;    // USDC, 6-dec
    mapping(address => uint64)  internal _lastAccrualAt;

    /// @param usdc_ USDC token address.
    /// @param exchangeRate_ Initial USDY ↔ USDC rate in 1e18 fixed point.
    constructor(address usdc_, uint256 exchangeRate_) {
        usdc = IERC20(usdc_);
        exchangeRate = exchangeRate_;
    }

    // ─── IOndoUSDYAdapter ───────────────────────────────────────────

    /// @inheritdoc IOndoUSDYAdapter
    function deposit(uint256 usdcAmount, uint256 minUsdyOut)
        external override returns (uint256 usdyReceived)
    {
        _accrue(msg.sender);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdyReceived = _usdcToUsdy(usdcAmount);
        if (usdyReceived < minUsdyOut) revert SlippageTooHigh(minUsdyOut, usdyReceived);
        _balances[msg.sender] += usdyReceived;
        emit Deposited(msg.sender, usdcAmount, usdyReceived);
    }

    /// @inheritdoc IOndoUSDYAdapter
    function redeem(uint256 usdyAmount, uint256 minUsdcOut)
        external override returns (uint256 usdcOut)
    {
        _accrue(msg.sender);
        require(_balances[msg.sender] >= usdyAmount, "insufficient USDY");
        _balances[msg.sender] -= usdyAmount;

        uint256 principalUsdc = _usdyToUsdc(usdyAmount);
        uint256 yieldUsdc = _pendingYield[msg.sender];
        _pendingYield[msg.sender] = 0;

        usdcOut = principalUsdc + yieldUsdc;
        if (usdcOut < minUsdcOut) revert SlippageTooHigh(minUsdcOut, usdcOut);

        if (yieldUsdc > 0) IMintableUSDC(address(usdc)).mint(address(this), yieldUsdc);
        usdc.safeTransfer(msg.sender, usdcOut);
        emit Redeemed(msg.sender, usdyAmount, usdcOut);
    }

    /// @inheritdoc IOndoUSDYAdapter
    function harvestYield(address holder) external override returns (uint256 usdcOut) {
        _accrue(holder);
        usdcOut = _pendingYield[holder];
        if (usdcOut == 0) return 0;
        _pendingYield[holder] = 0;
        IMintableUSDC(address(usdc)).mint(msg.sender, usdcOut);
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IOndoUSDYAdapter
    function balanceOfHolder(address holder) external view override returns (uint256) {
        return _balances[holder];
    }

    /// @inheritdoc IOndoUSDYAdapter
    function valueInUSDC(address holder) external view override returns (uint256) {
        return _usdyToUsdc(_balances[holder]);
    }

    /// @notice Pending USDC yield not yet harvested (realised + implicit accrual).
    function pendingYieldOf(address holder) external view returns (uint256) {
        return _pendingYield[holder] + _accruedSinceLast(holder);
    }

    // ─── internal ───────────────────────────────────────────────────

    function _accrue(address holder) internal {
        uint256 acc = _accruedSinceLast(holder);
        if (acc > 0) _pendingYield[holder] += acc;
        _lastAccrualAt[holder] = uint64(block.timestamp);
    }

    function _accruedSinceLast(address holder) internal view returns (uint256) {
        uint64 last = _lastAccrualAt[holder];
        uint256 bal = _balances[holder];
        if (last == 0 || bal == 0 || block.timestamp <= last) return 0;
        uint256 dt = block.timestamp - last;
        uint256 principalUsdc = _usdyToUsdc(bal);
        return (principalUsdc * APY_BPS * dt) / (BPS_DENOM * SECONDS_PER_YEAR);
    }

    function _usdcToUsdy(uint256 usdcAmount) internal view returns (uint256) {
        return (usdcAmount * 1e12 * SCALE) / exchangeRate;
    }

    function _usdyToUsdc(uint256 usdyAmount) internal view returns (uint256) {
        return (usdyAmount * exchangeRate) / (SCALE * 1e12);
    }
}
