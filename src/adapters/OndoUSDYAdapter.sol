// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOndoUSDYAdapter} from "../interfaces/IOndoUSDYAdapter.sol";
import {ITimeProvider} from "../interfaces/ITimeProvider.sol";

/// @dev Mintable interface for the testnet/local USDC. Gated by MockERC20's
///      chainId guard, so a mistaken mainnet deployment can't print value.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

/// @title OndoUSDYAdapter — Mantle integration for Ondo's USDY T-bill token
/// @notice Real USDY (Mantle Mainnet: 0x5bE26527e817998A7206475496fDE1E68957c5A6) is
///         regulated and not available on Sepolia. This testnet adapter
///         simulates USDY's accumulating value (~5% APY) using a global
///         `usdyPricePerShare` that grows continuously, exposing a
///         production-equivalent interface so the vault side stays unchanged
///         on migration.
/// @dev Production migration: replace `_accrueYield` with reads from Ondo's
///      RWADynamicRateOracle (Mantle Mainnet 0xA96abbe61AfEdEB0D14a20440Ae7100D9aB4882f),
///      replace the MockERC20.mint backstop with a real USDY redeem path,
///      and route USDY transfers through the on-chain USDY contract.
contract OndoUSDYAdapter is IOndoUSDYAdapter {
    using SafeERC20 for IERC20;

    /// @notice Real USDY token on Mantle Mainnet.
    address public constant ONDO_USDY_MAINNET = 0x5bE26527e817998A7206475496fDE1E68957c5A6;

    /// @notice Ondo's RWADynamicRateOracle on Mantle Mainnet — the production
    ///         source of USDY's per-share accrual.
    address public constant ONDO_USDY_ORACLE_MAINNET = 0xA96abbe61AfEdEB0D14a20440Ae7100D9aB4882f;

    /// @notice Simulated annualised yield, in basis points (5%, matching USDY).
    uint256 public constant SIMULATED_APY_BPS = 500;

    uint256 internal constant BPS_DENOM        = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SCALE            = 1e18;

    /// @notice USDC token (testnet MockERC20 with adapter as authorised minter).
    IERC20 public immutable usdc;

    /// @notice Demo time source (drives `_accrueYield`-based price growth).
    ITimeProvider public immutable timeProvider;

    /// @notice Per-vault USDY balance (18-dec).
    mapping(address => uint256) public vaultUsdyBalance;

    /// @notice Snapshot of `usdyPricePerShare` captured at each vault's last
    ///         touch. Used to compute yield since last harvest.
    mapping(address => uint256) public vaultLastPrice;

    /// @notice Pending USDC yield accrued but not yet harvested (6-dec).
    mapping(address => uint256) internal _pendingYield;

    /// @notice Global USDY price-per-share, 1e18 scaled. Starts at 1e18 and
    ///         grows continuously at SIMULATED_APY_BPS APY.
    uint256 public usdyPricePerShare;

    /// @notice Last timestamp at which usdyPricePerShare was updated.
    uint256 public lastPriceUpdateTime;

    /// @param usdc_ USDC token (mintable on testnet).
    /// @param timeProvider_ Singleton TimeProvider for demo fast-forward.
    constructor(address usdc_, address timeProvider_) {
        usdc = IERC20(usdc_);
        timeProvider = ITimeProvider(timeProvider_);
        usdyPricePerShare = SCALE;
        lastPriceUpdateTime = timeProvider_ == address(0)
            ? block.timestamp
            : ITimeProvider(timeProvider_).currentTime();
    }

    function _now() internal view returns (uint256) {
        return timeProvider.currentTime();
    }

    // ─── IOndoUSDYAdapter ───────────────────────────────────────────

    /// @inheritdoc IOndoUSDYAdapter
    function deposit(uint256 usdcAmount, uint256 minUsdyOut)
        external override returns (uint256 usdyReceived)
    {
        _accrueGlobalYield();
        _accrueVaultYield(msg.sender);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        // usdyReceived = usdcAmount * 1e12 * 1e18 / usdyPricePerShare.
        // 6-dec USDC → 18-dec USDY, scaled by 1e18 / pricePerShare.
        usdyReceived = (usdcAmount * 1e30) / usdyPricePerShare;
        if (usdyReceived < minUsdyOut) revert SlippageTooHigh(minUsdyOut, usdyReceived);

        vaultUsdyBalance[msg.sender] += usdyReceived;
        vaultLastPrice[msg.sender] = usdyPricePerShare;

        emit Deposited(msg.sender, usdcAmount, usdyReceived);
    }

    /// @inheritdoc IOndoUSDYAdapter
    function redeem(uint256 usdyAmount, uint256 minUsdcOut)
        external override returns (uint256 usdcOut)
    {
        _accrueGlobalYield();
        _accrueVaultYield(msg.sender);

        require(vaultUsdyBalance[msg.sender] >= usdyAmount, "insufficient USDY");
        vaultUsdyBalance[msg.sender] -= usdyAmount;

        // usdcOut = usdyAmount * usdyPricePerShare / 1e30 (18-dec USDY → 6-dec USDC).
        usdcOut = (usdyAmount * usdyPricePerShare) / 1e30;
        if (usdcOut < minUsdcOut) revert SlippageTooHigh(minUsdcOut, usdcOut);

        _ensureBalance(usdcOut);
        usdc.safeTransfer(msg.sender, usdcOut);

        emit Redeemed(msg.sender, usdyAmount, usdcOut);
    }

    /// @inheritdoc IOndoUSDYAdapter
    /// @dev Mints the accrued yield as testnet USDC to msg.sender (the YieldHarvester).
    function harvestYield(address holder) external override returns (uint256 usdcOut) {
        _accrueGlobalYield();
        _accrueVaultYield(holder);
        usdcOut = _pendingYield[holder];
        if (usdcOut == 0) return 0;
        _pendingYield[holder] = 0;
        IMintableUSDC(address(usdc)).mint(msg.sender, usdcOut);
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IOndoUSDYAdapter
    function balanceOfHolder(address holder) external view override returns (uint256) {
        return vaultUsdyBalance[holder];
    }

    /// @inheritdoc IOndoUSDYAdapter
    /// @notice Spot USDC value at the current (projected) USDY price-per-share.
    function valueInUSDC(address holder) external view override returns (uint256) {
        uint256 bal = vaultUsdyBalance[holder];
        if (bal == 0) return 0;
        return (bal * _projectedPrice()) / 1e30;
    }

    /// @inheritdoc IOndoUSDYAdapter
    function exchangeRate() external view override returns (uint256) {
        return _projectedPrice();
    }

    /// @notice Pending USDC yield (already accrued + projected since last touch).
    function pendingYieldOf(address holder) external view returns (uint256) {
        uint256 bal = vaultUsdyBalance[holder];
        uint256 lastP = vaultLastPrice[holder];
        uint256 projected = _projectedPrice();
        if (bal == 0 || lastP == 0 || projected <= lastP) return _pendingYield[holder];
        uint256 delta = projected - lastP;
        uint256 newAccrual = (bal * delta) / 1e30;
        return _pendingYield[holder] + newAccrual;
    }

    /// @notice USDY token address on Mantle mainnet (production migration reference).
    function productionUsdyAddress() external pure returns (address) {
        return ONDO_USDY_MAINNET;
    }

    /// @notice Production RWADynamicRateOracle (Mantle mainnet).
    function productionOracleAddress() external pure returns (address) {
        return ONDO_USDY_ORACLE_MAINNET;
    }

    // ─── internal ───────────────────────────────────────────────────

    function _accrueGlobalYield() internal {
        uint256 nowTs = _now();
        if (nowTs <= lastPriceUpdateTime) return;
        uint256 elapsed = nowTs - lastPriceUpdateTime;
        uint256 yieldFactor = (SIMULATED_APY_BPS * elapsed * SCALE) / (BPS_DENOM * SECONDS_PER_YEAR);
        usdyPricePerShare += (usdyPricePerShare * yieldFactor) / SCALE;
        lastPriceUpdateTime = nowTs;
    }

    function _accrueVaultYield(address holder) internal {
        uint256 bal = vaultUsdyBalance[holder];
        uint256 lastP = vaultLastPrice[holder];
        if (bal == 0 || lastP == 0 || usdyPricePerShare <= lastP) {
            vaultLastPrice[holder] = usdyPricePerShare;
            return;
        }
        uint256 delta = usdyPricePerShare - lastP;
        uint256 newAccrualUsdc = (bal * delta) / 1e30;
        _pendingYield[holder] += newAccrualUsdc;
        vaultLastPrice[holder] = usdyPricePerShare;
    }

    function _projectedPrice() internal view returns (uint256) {
        uint256 nowTs = _now();
        if (nowTs <= lastPriceUpdateTime) return usdyPricePerShare;
        uint256 elapsed = nowTs - lastPriceUpdateTime;
        uint256 yieldFactor = (SIMULATED_APY_BPS * elapsed * SCALE) / (BPS_DENOM * SECONDS_PER_YEAR);
        return usdyPricePerShare + (usdyPricePerShare * yieldFactor) / SCALE;
    }

    function _ensureBalance(uint256 needed) internal {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal >= needed) return;
        IMintableUSDC(address(usdc)).mint(address(this), needed - bal);
    }
}
