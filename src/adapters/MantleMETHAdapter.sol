// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMantleMETHAdapter} from "../interfaces/IMantleMETHAdapter.sol";
import {ITimeProvider} from "../interfaces/ITimeProvider.sol";
import {IPyth} from "@pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pyth-sdk-solidity/PythStructs.sol";

/// @dev Mintable interface for the testnet/local USDC. Production USDC
///      doesn't satisfy this, but the adapter's mint paths are gated by
///      chainId in MockERC20 itself, so a misconfigured mainnet deployment
///      can't actually print value.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

/// @title MantleMETHAdapter — Hybrid integration for Mantle's mETH liquid staking
/// @notice On Mantle Mainnet, this adapter would route USDC → ETH (Merchant Moe)
///         → ETH staking (Mantle Staking contract) → mETH, and the reverse on exit.
///         Mantle Sepolia has no DEX liquidity for that path, so this adapter:
///           1. Uses the Pyth ETH/USD oracle for live USDC ↔ mETH pricing.
///           2. Simulates mETH ↔ ETH exchange-rate growth (4% APY) as a global
///              `mEthEthRatio` that accrues over time.
///           3. Mints testnet USDC via MockERC20 to cover P&L gains on
///              withdraw and the periodic yield extracted on harvest.
/// @dev Production migration: replace _accrueYield with reads from the Mantle
///      Staking contract's mETH→ETH ratio, replace the MockERC20.mint backstop
///      with a real DEX swap path, and verify the real mETH address below.
contract MantleMETHAdapter is IMantleMETHAdapter {
    using SafeERC20 for IERC20;

    /// @notice mETH on Ethereum L1 (Mantle Staking's mETH token).
    /// @dev TODO(human): verify this address before any mainnet deployment.
    ///      Mantle's mETH primarily lives on Ethereum mainnet; the Mantle L2
    ///      version may differ.
    address public constant MANTLE_METH_MAINNET = 0xcDA86A272531e8640cD7F1a92c01839911B90bb0;

    /// @notice mETH proxy on Mantle Sepolia (used as the real-token reference;
    ///         no minting/burning happens against it in this hybrid adapter).
    address public constant MANTLE_SEPOLIA_METH = 0x9EF6f9160Ba00B6621e5CB3217BB8b54a92B2828;

    /// @notice Simulated annualised staking yield, in basis points (4%).
    uint256 public constant SIMULATED_APY_BPS = 400;

    uint256 internal constant BPS_DENOM        = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SCALE            = 1e18;

    /// @notice USDC token (testnet MockERC20 with adapter as authorised minter).
    IERC20 public immutable usdc;

    /// @notice Pyth pull oracle used for ETH/USD pricing.
    IPyth public immutable pyth;

    /// @notice Pyth feed ID for ETH/USD.
    bytes32 public immutable ethUsdPriceId;

    /// @notice Real mETH token reference (Mantle Sepolia on testnet, mainnet on mainnet).
    address public immutable meth;

    /// @notice Maximum staleness tolerated for the ETH/USD feed.
    uint64 public immutable maxEthPriceStaleness;

    /// @notice Demo time source (drives `_accrueYield`-based ratio growth).
    ITimeProvider public immutable timeProvider;

    /// @notice Per-vault mETH balance (18-dec).
    mapping(address => uint256) public vaultMethBalance;

    /// @notice mEthEthRatio captured at the last touch for each vault. Used
    ///         to compute yield since last harvest/deposit.
    mapping(address => uint256) public vaultLastRatio;

    /// @notice Pending USDC yield accrued but not yet harvested (6-dec).
    mapping(address => uint256) internal _pendingYield;

    /// @notice Global mETH ↔ ETH exchange rate, 1e18 scaled. Starts at 1e18
    ///         and grows continuously at SIMULATED_APY_BPS APY.
    uint256 public mEthEthRatio;

    /// @notice Last timestamp at which mEthEthRatio was updated.
    uint256 public lastRatioUpdateTime;

    /// @param usdc_ USDC token (mintable on testnet).
    /// @param pyth_ Pyth oracle contract.
    /// @param ethUsdPriceId_ Pyth feed identifier for ETH/USD.
    /// @param meth_ Real mETH address — pass MANTLE_SEPOLIA_METH on testnet,
    ///        MANTLE_METH_MAINNET on production.
    /// @param maxEthPriceStaleness_ Max age for the Pyth ETH/USD price (seconds).
    /// @param timeProvider_ Singleton TimeProvider for demo fast-forward.
    constructor(
        address usdc_,
        address pyth_,
        bytes32 ethUsdPriceId_,
        address meth_,
        uint64 maxEthPriceStaleness_,
        address timeProvider_
    ) {
        usdc = IERC20(usdc_);
        pyth = IPyth(pyth_);
        ethUsdPriceId = ethUsdPriceId_;
        meth = meth_;
        maxEthPriceStaleness = maxEthPriceStaleness_;
        timeProvider = ITimeProvider(timeProvider_);
        mEthEthRatio = SCALE;
        lastRatioUpdateTime = timeProvider_ == address(0)
            ? block.timestamp
            : ITimeProvider(timeProvider_).currentTime();
    }

    function _now() internal view returns (uint256) {
        return timeProvider.currentTime();
    }

    // ─── IMantleMETHAdapter ─────────────────────────────────────────

    /// @inheritdoc IMantleMETHAdapter
    function deposit(uint256 usdcAmount, uint256 minMEthOut)
        external override returns (uint256 mEthReceived)
    {
        _accrueGlobalYield();
        _accrueVaultYield(msg.sender);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 ethPrice = _readEthUsdPrice();
        // methOut = usdcAmount * 1e48 / (ethPrice * mEthEthRatio).
        // usdcAmount is 1e6, ethPrice/mEthEthRatio are 1e18 ⇒ result is 1e18 mETH.
        mEthReceived = (usdcAmount * 1e48) / (ethPrice * mEthEthRatio);
        if (mEthReceived < minMEthOut) revert SlippageTooHigh(minMEthOut, mEthReceived);

        vaultMethBalance[msg.sender] += mEthReceived;
        vaultLastRatio[msg.sender] = mEthEthRatio;

        emit Deposited(msg.sender, usdcAmount, mEthReceived);
    }

    /// @inheritdoc IMantleMETHAdapter
    function withdraw(uint256 mEthAmount, uint256 minUsdcOut)
        external override returns (uint256 usdcReceived)
    {
        _accrueGlobalYield();
        _accrueVaultYield(msg.sender);

        require(vaultMethBalance[msg.sender] >= mEthAmount, "insufficient mEth");
        vaultMethBalance[msg.sender] -= mEthAmount;

        uint256 ethPrice = _readEthUsdPrice();
        // Path: mETH(1e18) × ratio(1e18) → ETH(1e18), × price(1e18 USD/ETH) → USD(1e18), / 1e12 → USDC(1e6).
        // Combined divisor: 1e48.
        usdcReceived = (mEthAmount * mEthEthRatio * ethPrice) / 1e48;
        if (usdcReceived < minUsdcOut) revert SlippageTooHigh(minUsdcOut, usdcReceived);

        _ensureBalance(usdcReceived);
        usdc.safeTransfer(msg.sender, usdcReceived);

        emit Withdrawn(msg.sender, mEthAmount, usdcReceived);
    }

    /// @inheritdoc IMantleMETHAdapter
    /// @dev Mints the realised yield as fresh testnet USDC and forwards it to
    ///      msg.sender (expected to be the YieldHarvester contract, which
    ///      then deposits it into the vault's yield pool).
    function harvestYield(address holder) external override returns (uint256 usdcOut) {
        _accrueGlobalYield();
        _accrueVaultYield(holder);
        usdcOut = _pendingYield[holder];
        if (usdcOut == 0) return 0;
        _pendingYield[holder] = 0;
        IMintableUSDC(address(usdc)).mint(msg.sender, usdcOut);
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IMantleMETHAdapter
    function balanceOfHolder(address holder) external view override returns (uint256) {
        return vaultMethBalance[holder];
    }

    /// @inheritdoc IMantleMETHAdapter
    /// @notice Spot USDC value of the holder's mETH at current Pyth ETH/USD
    ///         and current mEthEthRatio. Excludes already-accrued yield.
    function valueInUSDC(address holder) external view override returns (uint256) {
        uint256 bal = vaultMethBalance[holder];
        if (bal == 0) return 0;
        uint256 ratio = _projectedRatio();
        uint256 ethPrice = _readEthUsdPrice();
        return (bal * ratio * ethPrice) / 1e48;
    }

    /// @inheritdoc IMantleMETHAdapter
    function exchangeRate() external view override returns (uint256) {
        return _projectedRatio();
    }

    /// @notice Alias of `valueInUSDC(vault)` matching the spec's naming.
    function currentValueUsdc(address vault) external view returns (uint256) {
        uint256 bal = vaultMethBalance[vault];
        if (bal == 0) return 0;
        uint256 ratio = _projectedRatio();
        uint256 ethPrice = _readEthUsdPrice();
        return (bal * ratio * ethPrice) / 1e48;
    }

    /// @notice Pending USDC yield (already accrued + projected since last touch).
    function pendingYieldOf(address holder) external view returns (uint256) {
        uint256 projectedRatio = _projectedRatio();
        uint256 bal = vaultMethBalance[holder];
        uint256 lastR = vaultLastRatio[holder];
        if (bal == 0 || lastR == 0 || projectedRatio <= lastR) return _pendingYield[holder];
        uint256 ethPrice = _readEthUsdPrice();
        uint256 delta = projectedRatio - lastR;
        uint256 newAccrual = (bal * delta * ethPrice) / 1e48;
        return _pendingYield[holder] + newAccrual;
    }

    /// @notice Real mETH token address on the active chain (Sepolia testnet by default).
    function realMethAddress() external view returns (address) {
        return meth;
    }

    /// @notice Address of mETH on Ethereum mainnet (for production migration reference).
    function productionMethAddress() external pure returns (address) {
        return MANTLE_METH_MAINNET;
    }

    // ─── internal ───────────────────────────────────────────────────

    /// @dev Grow `mEthEthRatio` by SIMULATED_APY_BPS for the elapsed seconds.
    function _accrueGlobalYield() internal {
        uint256 nowTs = _now();
        uint256 elapsed = nowTs - lastRatioUpdateTime;
        if (elapsed == 0) return;
        uint256 yieldFactor = (SIMULATED_APY_BPS * elapsed * SCALE) / (BPS_DENOM * SECONDS_PER_YEAR);
        mEthEthRatio += (mEthEthRatio * yieldFactor) / SCALE;
        lastRatioUpdateTime = nowTs;
    }

    /// @dev Capture yield for `holder` since their last touch, priced in USDC.
    function _accrueVaultYield(address holder) internal {
        uint256 bal = vaultMethBalance[holder];
        uint256 lastR = vaultLastRatio[holder];
        if (bal == 0 || lastR == 0 || mEthEthRatio <= lastR) {
            vaultLastRatio[holder] = mEthEthRatio;
            return;
        }
        uint256 delta = mEthEthRatio - lastR;
        uint256 ethPrice = _readEthUsdPrice();
        uint256 newAccrualUsdc = (bal * delta * ethPrice) / 1e48;
        _pendingYield[holder] += newAccrualUsdc;
        vaultLastRatio[holder] = mEthEthRatio;
    }

    /// @dev Project what `mEthEthRatio` would be at the current time, without writing state.
    function _projectedRatio() internal view returns (uint256) {
        uint256 nowTs = _now();
        if (nowTs <= lastRatioUpdateTime) return mEthEthRatio;
        uint256 elapsed = nowTs - lastRatioUpdateTime;
        uint256 yieldFactor = (SIMULATED_APY_BPS * elapsed * SCALE) / (BPS_DENOM * SECONDS_PER_YEAR);
        return mEthEthRatio + (mEthEthRatio * yieldFactor) / SCALE;
    }

    /// @dev Read ETH/USD price from Pyth and normalise to 1e18.
    function _readEthUsdPrice() internal view returns (uint256) {
        PythStructs.Price memory p = pyth.getPriceUnsafe(ethUsdPriceId);
        require(p.price > 0, "ETH price <= 0");
        require(block.timestamp - p.publishTime <= maxEthPriceStaleness, "ETH price stale");
        // raw price × 10^(expo + 18). For e.g. expo=-5, multiply by 1e13.
        int256 adjustedExpo = int256(int32(p.expo)) + 18;
        uint256 raw = uint256(uint64(p.price));
        if (adjustedExpo >= 0) {
            return raw * (10 ** uint256(adjustedExpo));
        } else {
            return raw / (10 ** uint256(-adjustedExpo));
        }
    }

    /// @dev If we don't hold enough USDC to honour `needed`, mint the shortage
    ///      from MockERC20 (testnet-only — the chainId guard in MockERC20
    ///      makes this no-op outside testnets).
    function _ensureBalance(uint256 needed) internal {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal >= needed) return;
        IMintableUSDC(address(usdc)).mint(address(this), needed - bal);
    }
}
