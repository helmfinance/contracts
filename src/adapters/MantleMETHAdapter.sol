// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMantleMETHAdapter} from "../interfaces/IMantleMETHAdapter.sol";

/// @dev Minimal interface used to mint simulated yield in the mock. Any
///      mintable testnet USDC (e.g. MockERC20) satisfies this; production USDC
///      will not, which is fine because the production adapter never uses it.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

// TODO(human): replace this mock with the real Mantle mETH staking contract
//              integration (USDC → ETH via Merchant Moe → stake → mETH, and
//              reverse on exit) before mainnet deployment. The current
//              implementation simulates a constant-rate yield by minting USDC
//              via MockERC20 on harvest — that only works against a mintable
//              USDC, which is acceptable for a hackathon testnet but not for
//              production.

/// @title MantleMETHAdapter (MOCK)
/// @notice Hackathon stub for Mantle's mETH liquid staking. Simulates a
///         constant 4% APY on the depositor's USDC balance. The exchange rate
///         is fixed (1 USDC = 1 mETH in human terms) for the mock — actual
///         mETH/ETH exchange-rate growth is not modelled.
/// @dev Per-holder yield accrual: yield = balanceUsdc × 4% × dt / 365 days.
///      A holder's pending yield grows continuously; harvestYield realises it
///      to USDC (minted via MockERC20) and resets the accrual timestamp.
contract MantleMETHAdapter is IMantleMETHAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant APY_BPS         = 400;          // 4%
    uint256 internal constant BPS_DENOM       = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SCALE           = 1e18;

    /// @notice USDC token (must be MockERC20-compatible for yield minting).
    IERC20 public immutable usdc;

    /// @inheritdoc IMantleMETHAdapter
    uint256 public override exchangeRate; // 1e18 fixed; default 1e18 = 1:1

    mapping(address => uint256) internal _balances;        // mETH balance, 18-dec
    mapping(address => uint256) internal _pendingYield;    // USDC, 6-dec
    mapping(address => uint64)  internal _lastAccrualAt;

    /// @param usdc_ USDC token address.
    /// @param exchangeRate_ Initial mETH ↔ USDC rate in 1e18 fixed point.
    ///        Use 1e18 for the simplest mock (1 USDC ≈ 1 mETH).
    constructor(address usdc_, uint256 exchangeRate_) {
        usdc = IERC20(usdc_);
        exchangeRate = exchangeRate_;
    }

    // ─── IMantleMETHAdapter ─────────────────────────────────────────

    /// @inheritdoc IMantleMETHAdapter
    function deposit(uint256 usdcAmount, uint256 minMEthOut)
        external override returns (uint256 mEthReceived)
    {
        _accrue(msg.sender);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        mEthReceived = _usdcToMEth(usdcAmount);
        if (mEthReceived < minMEthOut) revert SlippageTooHigh(minMEthOut, mEthReceived);
        _balances[msg.sender] += mEthReceived;
        emit Deposited(msg.sender, usdcAmount, mEthReceived);
    }

    /// @inheritdoc IMantleMETHAdapter
    function withdraw(uint256 mEthAmount, uint256 minUsdcOut)
        external override returns (uint256 usdcReceived)
    {
        _accrue(msg.sender);
        require(_balances[msg.sender] >= mEthAmount, "insufficient mEth");
        _balances[msg.sender] -= mEthAmount;

        uint256 principalUsdc = _mEthToUsdc(mEthAmount);
        uint256 yieldUsdc = _pendingYield[msg.sender];
        _pendingYield[msg.sender] = 0;

        usdcReceived = principalUsdc + yieldUsdc;
        if (usdcReceived < minUsdcOut) revert SlippageTooHigh(minUsdcOut, usdcReceived);

        // Principal is already custodied; mint the yield portion (mock-only).
        if (yieldUsdc > 0) IMintableUSDC(address(usdc)).mint(address(this), yieldUsdc);
        usdc.safeTransfer(msg.sender, usdcReceived);
        emit Withdrawn(msg.sender, mEthAmount, usdcReceived);
    }

    /// @inheritdoc IMantleMETHAdapter
    function harvestYield(address holder) external override returns (uint256 usdcOut) {
        _accrue(holder);
        usdcOut = _pendingYield[holder];
        if (usdcOut == 0) return 0;
        _pendingYield[holder] = 0;
        // Mock-only: mint the simulated yield. Production would draw from
        // realized staking proceeds.
        IMintableUSDC(address(usdc)).mint(msg.sender, usdcOut);
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IMantleMETHAdapter
    function balanceOfHolder(address holder) external view override returns (uint256) {
        return _balances[holder];
    }

    /// @inheritdoc IMantleMETHAdapter
    function valueInUSDC(address holder) external view override returns (uint256) {
        // NAV-facing value excludes pending yield (per spec); only the
        // principal-equivalent USDC of the mETH balance is reported.
        return _mEthToUsdc(_balances[holder]);
    }

    /// @notice Pending USDC yield not yet harvested. Includes both already-
    ///         realised pending and the implicit accrual since the last touch.
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
        uint256 principalUsdc = _mEthToUsdc(bal);
        // yield = principalUsdc × APY × dt / (BPS × YEAR)
        return (principalUsdc * APY_BPS * dt) / (BPS_DENOM * SECONDS_PER_YEAR);
    }

    /// @dev USDC (6-dec) → mETH (18-dec) via exchange rate. With rate = 1e18
    ///      this is a pure 1e12 decimal shift (1 USDC → 1 mETH).
    function _usdcToMEth(uint256 usdcAmount) internal view returns (uint256) {
        return (usdcAmount * 1e12 * SCALE) / exchangeRate;
    }

    /// @dev mETH (18-dec) → USDC (6-dec) via exchange rate (inverse).
    function _mEthToUsdc(uint256 mEthAmount) internal view returns (uint256) {
        return (mEthAmount * exchangeRate) / (SCALE * 1e12);
    }
}
