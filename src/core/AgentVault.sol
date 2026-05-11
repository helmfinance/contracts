// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAgentVault} from "../interfaces/IAgentVault.sol";
import {IAgentToken} from "../interfaces/IAgentToken.sol";
import {IFounderVault} from "../interfaces/IFounderVault.sol";
import {IPlatformTreasury} from "../interfaces/IPlatformTreasury.sol";
import {ISyntheticAsset} from "../interfaces/ISyntheticAsset.sol";
import {IMantleMETHAdapter} from "../interfaces/IMantleMETHAdapter.sol";
import {IOndoUSDYAdapter} from "../interfaces/IOndoUSDYAdapter.sol";

/// @title AgentVault
/// @notice ERC-4626-shaped vault for a single Helm agent. Holds USDC plus
///         Pyth-priced synthetic equities and (optionally) mETH / USDY adapter
///         positions. Mints and rebalances are gated by phase and the mandate.
/// @dev Shares live in a separate IAgentToken contract; the IERC20 surface here
///      is a read-only facade. Standard ERC-4626 `withdraw`/`redeem` are disabled
///      — user redemptions go through the singleton RedemptionQueue.
contract AgentVault is IAgentVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── constants ───────────────────────────────────────────────────────────

    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant SHARE_SCALE = 1e18;
    uint64  internal constant DEFAULT_SENIOR_WINDOW = 90 days;

    // ─── types ───────────────────────────────────────────────────────────────

    enum AssetKind { Synthetic, METHAdapter, USDYAdapter }

    struct AssetEntry {
        address asset;
        AssetKind kind;
    }

    struct WeightConstraint {
        address asset;
        uint16  minBps;
        uint16  maxBps;
    }

    struct WindDown {
        bool    active;
        bool    settled;
        uint64  triggeredAt;
        uint64  seniorWindowEnd;
        string  reason;
        uint256 seniorClaimableUsdc;
        uint256 juniorClaimableUsdc;
    }

    struct InitParams {
        uint256 agentId;
        bytes32 mandateHash;
        string  mandateURI;
        address agentToken;
        address founderVault;
        address registry;
        address redemptionQueue;
        address treasury;
        address yieldHarvester;
        address pythAdapter;
        address usdc;
        address executor;
        Phase   initialPhase;
        AssetEntry[] assets;
        WeightConstraint[] weightConstraints;
        uint64  seniorWindowDuration; // 0 → DEFAULT_SENIOR_WINDOW
    }

    // ─── extra errors (interface defines the rest) ───────────────────────────

    error InsufficientShares();
    error MintsDisabled();
    error MandateBreach(address asset, uint256 actualBps, uint256 minBps, uint256 maxBps);
    error AssetNotWhitelisted(address asset);
    error WindDownActive();
    error WindDownNotActive();
    error SeniorWindowOpen(uint64 endsAt);
    error PositionsNotLiquidated(uint256 remaining);
    error AlreadySettled();
    error TransfersDisabled();
    error ERC4626RedeemDisabled();
    error NotAuthorizedToWindDown();
    error ZeroAmount();
    error ZeroAddress();

    // ─── immutable identity ──────────────────────────────────────────────────

    uint256 public immutable override agentId;
    bytes32 public immutable mandateHash;
    address public immutable usdc;
    IAgentToken public immutable agentToken;
    IFounderVault public immutable founderVault;
    IPlatformTreasury public immutable treasury;
    address public immutable redemptionQueue;
    address public immutable yieldHarvester;
    address public immutable registry;
    address public immutable pythAdapter;

    // ─── mutable state ───────────────────────────────────────────────────────

    string  public mandateURI;
    Phase   public override phase;
    address public override executor;
    uint256 public override yieldPool;

    AssetEntry[] internal _assets;
    mapping(address => bool) internal _isWhitelisted;
    mapping(address => AssetKind) internal _assetKind;
    mapping(address => WeightConstraint) internal _weightOf;

    WindDown public windDown;
    uint64   public seniorWindowDuration;

    uint256 internal _liquidationCursor;

    // ─── construct ───────────────────────────────────────────────────────────

    constructor(InitParams memory p) {
        if (
            p.agentToken == address(0) ||
            p.founderVault == address(0) ||
            p.usdc == address(0) ||
            p.treasury == address(0) ||
            p.redemptionQueue == address(0) ||
            p.registry == address(0)
        ) revert ZeroAddress();

        agentId = p.agentId;
        mandateHash = p.mandateHash;
        mandateURI = p.mandateURI;
        agentToken = IAgentToken(p.agentToken);
        founderVault = IFounderVault(p.founderVault);
        treasury = IPlatformTreasury(p.treasury);
        redemptionQueue = p.redemptionQueue;
        yieldHarvester = p.yieldHarvester;
        registry = p.registry;
        pythAdapter = p.pythAdapter;
        usdc = p.usdc;
        executor = p.executor;
        phase = p.initialPhase;
        seniorWindowDuration =
            p.seniorWindowDuration == 0 ? DEFAULT_SENIOR_WINDOW : p.seniorWindowDuration;

        for (uint256 i = 0; i < p.assets.length; i++) {
            AssetEntry memory a = p.assets[i];
            if (a.asset == address(0)) revert ZeroAddress();
            require(!_isWhitelisted[a.asset], "init/dup-asset");
            _assets.push(a);
            _isWhitelisted[a.asset] = true;
            _assetKind[a.asset] = a.kind;
        }
        for (uint256 i = 0; i < p.weightConstraints.length; i++) {
            WeightConstraint memory w = p.weightConstraints[i];
            require(_isWhitelisted[w.asset], "init/wc-asset");
            require(w.maxBps <= BPS_DENOM && w.minBps <= w.maxBps, "init/wc-range");
            _weightOf[w.asset] = w;
        }
    }

    // ─── modifiers ───────────────────────────────────────────────────────────

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }
    modifier onlyHarvester() {
        if (msg.sender != yieldHarvester) revert OnlyHarvester();
        _;
    }
    modifier onlyRedemptionQueue() {
        if (msg.sender != redemptionQueue) revert OnlyRedemptionQueue();
        _;
    }
    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }
    modifier mintsAllowed() {
        if (windDown.active) revert MintsDisabled();
        if (phase != Phase.PublicLaunch && phase != Phase.Incubation) revert WrongPhase();
        _;
    }
    modifier notWindDown() {
        if (windDown.active) revert WindDownActive();
        _;
    }

    // ─── ERC-20 facade (delegates to AgentToken) ─────────────────────────────

    function name() external view returns (string memory) {
        return IERC20Metadata(address(agentToken)).name();
    }
    function symbol() external view returns (string memory) {
        return IERC20Metadata(address(agentToken)).symbol();
    }
    function decimals() external view returns (uint8) {
        return IERC20Metadata(address(agentToken)).decimals();
    }
    function totalSupply() public view returns (uint256) {
        return IERC20(address(agentToken)).totalSupply();
    }
    function balanceOf(address who) public view returns (uint256) {
        return IERC20(address(agentToken)).balanceOf(who);
    }
    function transfer(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }
    function approve(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // ─── ERC-4626 views ──────────────────────────────────────────────────────

    function asset() external view returns (address) {
        return usdc;
    }

    function totalAssets() public view returns (uint256) {
        return totalNAV();
    }

    /// @notice Sum of cash USDC + every position priced in USDC.
    function totalNAV() public view override returns (uint256 nav) {
        nav = cashUSDC();
        uint256 n = _assets.length;
        for (uint256 i = 0; i < n; i++) {
            nav += _valueOfAsset(_assets[i]);
        }
    }

    function cashUSDC() public view override returns (uint256) {
        uint256 bal = IERC20(usdc).balanceOf(address(this));
        return bal > yieldPool ? bal - yieldPool : 0;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 nav = totalNAV();
        if (supply == 0 || nav == 0) {
            return assets * SHARE_SCALE / 10**IERC20Metadata(usdc).decimals();
        }
        return assets * supply / nav;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares * totalNAV() / supply;
    }

    function maxDeposit(address) external view returns (uint256) {
        return _mintsOpen() ? type(uint256).max : 0;
    }

    function maxMint(address) external view returns (uint256) {
        return _mintsOpen() ? type(uint256).max : 0;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 fee = assets * _mintFeeBps() / BPS_DENOM;
        return _sharesForDeposit(assets - fee);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 net = convertToAssets(shares);
        uint256 feeBps = _mintFeeBps();
        if (feeBps == 0) return net;
        // gross = ceil(net * 10000 / (10000 - feeBps))
        uint256 denom = BPS_DENOM - feeBps;
        return (net * BPS_DENOM + denom - 1) / denom;
    }

    function maxWithdraw(address) external pure returns (uint256) { return 0; }
    function maxRedeem(address) external pure returns (uint256)   { return 0; }
    function previewWithdraw(uint256) external pure returns (uint256) { return 0; }
    function previewRedeem(uint256)   external pure returns (uint256) { return 0; }

    // ─── ERC-4626 mutations ──────────────────────────────────────────────────

    /// @notice Deposit USDC and receive AGT shares at NAV/share. Mint fee is
    ///         skimmed off `assets` and forwarded to PlatformTreasury.
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        mintsAllowed
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), assets);

        uint256 fee = assets * _mintFeeBps() / BPS_DENOM;
        if (fee > 0) _payFee(IPlatformTreasury.FeeKind.Mint, fee);

        uint256 net = assets - fee;
        shares = _sharesForDeposit(net);
        if (shares == 0) revert InsufficientShares();

        agentToken.mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares` to `receiver`, pulling the gross USDC needed.
    function mint(uint256 shares, address receiver)
        external
        nonReentrant
        mintsAllowed
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        assets = previewMint(shares);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), assets);

        uint256 fee = assets * _mintFeeBps() / BPS_DENOM;
        if (fee > 0) _payFee(IPlatformTreasury.FeeKind.Mint, fee);

        agentToken.mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert ERC4626RedeemDisabled();
    }
    function redeem(uint256, address, address) external pure returns (uint256) {
        revert ERC4626RedeemDisabled();
    }

    // ─── redemption (queue-only) ─────────────────────────────────────────────

    /// @notice Burn shares custodied in the queue, pay USDC at current NAV/share
    ///         minus the redemption fee. During wind-down's senior window the
    ///         FounderVault (junior) may not redeem.
    function fulfillRedemption(address holder, uint256 shares)
        external
        override
        nonReentrant
        onlyRedemptionQueue
        returns (uint256 usdcOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (
            windDown.active &&
            holder == address(founderVault) &&
            block.timestamp < windDown.seniorWindowEnd
        ) {
            revert SeniorWindowOpen(windDown.seniorWindowEnd);
        }

        uint256 supply = totalSupply();
        if (supply < shares) revert InsufficientShares();

        uint256 nav = totalNAV();
        uint256 gross = shares * nav / supply;

        uint256 feeBps = treasury.feeRate(IPlatformTreasury.FeeKind.Redeem);
        uint256 fee = gross * feeBps / BPS_DENOM;
        if (fee > 0) _payFee(IPlatformTreasury.FeeKind.Redeem, fee);

        usdcOut = gross - fee;
        if (cashUSDC() < usdcOut) revert InsufficientCash();

        agentToken.burn(holder, shares);
        IERC20(usdc).safeTransfer(holder, usdcOut);

        emit RedemptionFulfilled(holder, shares, usdcOut);
    }

    // ─── yield (harvester-only) ──────────────────────────────────────────────

    function depositYield(uint256 amount) external override onlyHarvester {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        yieldPool += amount;
        emit YieldDeposited(amount, yieldPool);
    }

    // ─── rebalance (executor-only) ───────────────────────────────────────────

    /// @notice Drive current asset balances toward `targets`. The vault first
    ///         trims any over-target positions back to USDC, then tops up
    ///         under-target positions from cash. After the rebalance, every
    ///         constrained asset's USDC weight must satisfy the mandate or the
    ///         whole call reverts.
    function executeRebalance(Position[] calldata targets, bytes calldata strategyProof)
        external
        override
        nonReentrant
        notWindDown
        onlyExecutor
    {
        // Step 1: trim over-target balances.
        uint256 nAssets = _assets.length;
        for (uint256 i = 0; i < nAssets; i++) {
            address a = _assets[i].asset;
            uint256 current = _balanceOf(_assets[i]);
            uint256 target = _targetFor(a, targets);
            if (current > target) _sell(_assets[i], current - target);
        }

        // Step 2: top up under-target balances.
        for (uint256 i = 0; i < targets.length; i++) {
            Position calldata t = targets[i];
            if (!_isWhitelisted[t.asset]) revert AssetNotWhitelisted(t.asset);
            AssetEntry memory entry = AssetEntry({asset: t.asset, kind: _assetKind[t.asset]});
            uint256 current = _balanceOf(entry);
            if (t.amount > current) _buy(entry, t.amount - current);
        }

        // Step 3: enforce mandate weight bounds (NAV after the rebalance).
        uint256 nav = totalNAV();
        for (uint256 i = 0; i < nAssets; i++) {
            address a = _assets[i].asset;
            WeightConstraint memory w = _weightOf[a];
            if (w.maxBps == 0 && w.minBps == 0) continue; // unconstrained
            uint256 v = _valueOfAsset(_assets[i]);
            uint256 wbps = nav == 0 ? 0 : (v * BPS_DENOM) / nav;
            if (wbps < w.minBps || wbps > w.maxBps) {
                revert MandateBreach(a, wbps, w.minBps, w.maxBps);
            }
        }

        // Step 4: rebalance fee (bps of post-NAV).
        uint256 feeBps = treasury.feeRate(IPlatformTreasury.FeeKind.Rebalance);
        uint256 fee = nav * feeBps / BPS_DENOM;
        if (fee > 0) {
            if (cashUSDC() < fee) revert InsufficientCash();
            _payFee(IPlatformTreasury.FeeKind.Rebalance, fee);
        }

        emit Rebalanced(keccak256(strategyProof), totalNAV(), block.timestamp);
    }

    // ─── lifecycle ───────────────────────────────────────────────────────────

    function enterPublicLaunch() external override onlyRegistry {
        if (phase != Phase.Incubation) revert WrongPhase();
        Phase old = phase;
        phase = Phase.PublicLaunch;
        emit PhaseChanged(old, Phase.PublicLaunch);
    }

    /// @notice Move into wind-down. Callable by the FounderVault (auto-trigger
    ///         on subordination breach), the registry (slash), or the
    ///         RedemptionQueue (queue-driven subordination signal).
    function triggerWindDown(string calldata reason) external override {
        if (
            msg.sender != address(founderVault) &&
            msg.sender != registry &&
            msg.sender != redemptionQueue
        ) revert NotAuthorizedToWindDown();
        if (windDown.active) revert WindDownActive();

        Phase old = phase;
        phase = Phase.WindDown;
        windDown = WindDown({
            active: true,
            settled: false,
            triggeredAt: uint64(block.timestamp),
            seniorWindowEnd: uint64(block.timestamp) + seniorWindowDuration,
            reason: reason,
            seniorClaimableUsdc: 0,
            juniorClaimableUsdc: 0
        });
        emit PhaseChanged(old, Phase.WindDown);
        emit WindDownTriggered(msg.sender, reason);
    }

    /// @notice Liquidate the next non-empty position to USDC. Returns the count
    ///         of positions still open after this call (0 → ready to settle).
    function progressWindDown()
        external
        override
        nonReentrant
        returns (uint256 remainingPositions)
    {
        if (!windDown.active) revert WindDownNotActive();

        uint256 n = _assets.length;
        while (_liquidationCursor < n) {
            AssetEntry memory entry = _assets[_liquidationCursor];
            uint256 bal = _balanceOf(entry);
            if (bal > 0) {
                _sell(entry, bal);
                break;
            }
            _liquidationCursor += 1;
        }

        for (uint256 i = 0; i < n; i++) {
            if (_balanceOf(_assets[i]) > 0) remainingPositions += 1;
        }
        emit WindDownProgressed(remainingPositions);
    }

    /// @notice Final settlement: senior holders get pro-rata first, junior
    ///         (founder via FounderVault) absorbs whatever's left. Only
    ///         callable after all positions are liquidated and the senior
    ///         redemption window has elapsed.
    function settle() external override nonReentrant {
        if (!windDown.active) revert WindDownNotActive();
        if (windDown.settled) revert AlreadySettled();
        if (block.timestamp < windDown.seniorWindowEnd) {
            revert SeniorWindowOpen(windDown.seniorWindowEnd);
        }
        uint256 n = _assets.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = _balanceOf(_assets[i]);
            if (bal > 0) revert PositionsNotLiquidated(bal);
        }

        uint256 cash = cashUSDC();
        uint256 supply = totalSupply();
        uint256 founderShares = balanceOf(address(founderVault));
        uint256 seniorShares = supply > founderShares ? supply - founderShares : 0;

        uint256 seniorPay;
        uint256 juniorPay;
        if (supply == 0) {
            // nothing minted; nothing to pay
        } else if (seniorShares == 0) {
            juniorPay = cash;
        } else {
            // Senior is paid pro-rata of full cash; junior absorbs the residual.
            seniorPay = cash * seniorShares / supply;
            if (seniorPay > cash) seniorPay = cash;
            juniorPay = cash - seniorPay;
        }

        windDown.seniorClaimableUsdc = seniorPay;
        windDown.juniorClaimableUsdc = juniorPay;
        windDown.settled = true;

        Phase old = phase;
        phase = Phase.Settled;
        emit PhaseChanged(old, Phase.Settled);
        emit Settled(seniorPay, juniorPay);
    }

    // ─── views for tests / FE ────────────────────────────────────────────────

    function assetCount() external view returns (uint256) { return _assets.length; }

    function assetAt(uint256 i) external view returns (address asset_, uint8 kind_) {
        AssetEntry memory e = _assets[i];
        return (e.asset, uint8(e.kind));
    }

    function weightConstraintOf(address a) external view returns (uint16 minBps, uint16 maxBps) {
        WeightConstraint memory w = _weightOf[a];
        return (w.minBps, w.maxBps);
    }

    // ─── internal helpers ────────────────────────────────────────────────────

    function _mintsOpen() internal view returns (bool) {
        if (windDown.active) return false;
        return phase == Phase.Incubation || phase == Phase.PublicLaunch;
    }

    function _mintFeeBps() internal view returns (uint256) {
        return treasury.feeRate(IPlatformTreasury.FeeKind.Mint);
    }

    /// @dev `net` is the deposit net of fee, already pulled into the vault.
    ///      Price-per-share is pinned to NAV-before-deposit = totalNAV() − net.
    function _sharesForDeposit(uint256 net) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 navTotal = totalNAV();
        uint256 navBefore = navTotal > net ? navTotal - net : 0;
        if (supply == 0 || navBefore == 0) {
            return net * SHARE_SCALE / 10**IERC20Metadata(usdc).decimals();
        }
        return net * supply / navBefore;
    }

    function _payFee(IPlatformTreasury.FeeKind kind, uint256 amount) internal {
        IERC20(usdc).safeTransfer(address(treasury), amount);
        treasury.collectFee(agentId, kind, amount);
    }

    function _balanceOf(AssetEntry memory entry) internal view returns (uint256) {
        if (entry.kind == AssetKind.Synthetic) {
            return IERC20(entry.asset).balanceOf(address(this));
        } else if (entry.kind == AssetKind.METHAdapter) {
            return IMantleMETHAdapter(entry.asset).balanceOfHolder(address(this));
        } else {
            return IOndoUSDYAdapter(entry.asset).balanceOfHolder(address(this));
        }
    }

    function _valueOfAsset(AssetEntry memory entry) internal view returns (uint256) {
        uint256 bal = _balanceOf(entry);
        if (bal == 0) return 0;
        if (entry.kind == AssetKind.Synthetic) {
            uint256 price = ISyntheticAsset(entry.asset).priceUSDC(); // 1e6 USDC per token
            uint8 d = IERC20Metadata(entry.asset).decimals();
            return bal * price / 10**d;
        } else if (entry.kind == AssetKind.METHAdapter) {
            return IMantleMETHAdapter(entry.asset).valueInUSDC(address(this));
        } else {
            return IOndoUSDYAdapter(entry.asset).valueInUSDC(address(this));
        }
    }

    function _targetFor(address a, Position[] calldata targets) internal pure returns (uint256) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].asset == a) return targets[i].amount;
        }
        return 0;
    }

    function _buy(AssetEntry memory entry, uint256 desiredIncrease) internal {
        if (desiredIncrease == 0) return;
        if (entry.kind == AssetKind.Synthetic) {
            uint256 price = ISyntheticAsset(entry.asset).priceUSDC();
            uint8 d = IERC20Metadata(entry.asset).decimals();
            uint256 usdcIn = desiredIncrease * price / 10**d;
            if (cashUSDC() < usdcIn) revert InsufficientCash();
            IERC20(usdc).forceApprove(entry.asset, usdcIn);
            ISyntheticAsset(entry.asset).mint(address(this), usdcIn);
        } else if (entry.kind == AssetKind.METHAdapter) {
            // adapters: `desiredIncrease` is treated as USDC to deposit.
            if (cashUSDC() < desiredIncrease) revert InsufficientCash();
            IERC20(usdc).forceApprove(entry.asset, desiredIncrease);
            IMantleMETHAdapter(entry.asset).deposit(desiredIncrease, 0);
        } else {
            if (cashUSDC() < desiredIncrease) revert InsufficientCash();
            IERC20(usdc).forceApprove(entry.asset, desiredIncrease);
            IOndoUSDYAdapter(entry.asset).deposit(desiredIncrease, 0);
        }
    }

    function _sell(AssetEntry memory entry, uint256 amount) internal {
        if (amount == 0) return;
        if (entry.kind == AssetKind.Synthetic) {
            ISyntheticAsset(entry.asset).burn(address(this), amount);
        } else if (entry.kind == AssetKind.METHAdapter) {
            IMantleMETHAdapter(entry.asset).withdraw(amount, 0);
        } else {
            IOndoUSDYAdapter(entry.asset).redeem(amount, 0);
        }
    }
}
