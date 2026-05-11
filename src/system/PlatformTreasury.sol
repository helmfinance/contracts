// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPlatformTreasury} from "../interfaces/IPlatformTreasury.sol";

/// @title PlatformTreasury
/// @notice Singleton sink for Helm platform fees (mint / redeem / rebalance).
///         AgentVaults push fees via {collectFee}; admin can withdraw collected
///         USDC and adjust per-fee-kind basis-point rates.
/// @dev Vaults transfer USDC to this contract *before* calling collectFee; the
///      treasury does not pull funds itself.
contract PlatformTreasury is IPlatformTreasury {
    using SafeERC20 for IERC20;

    /// @notice Maximum fee rate any kind may be set to (10%).
    uint256 internal constant MAX_FEE_BPS = 1_000;

    /// @notice USDC token (the only asset the treasury accounts for).
    IERC20 public immutable usdc;

    /// @notice Admin / owner. Set at construction; transferable via {transferAdmin}.
    address public admin;

    /// @inheritdoc IPlatformTreasury
    uint256 public override totalFeesCollected;

    mapping(IPlatformTreasury.FeeKind => uint256) internal _feeRates;
    mapping(uint256 => uint256) internal _feesByAgent;

    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @param usdc_ USDC token address.
    /// @param admin_ Initial admin (typically the deployer).
    constructor(address usdc_, address admin_) {
        usdc = IERC20(usdc_);
        admin = admin_;
        // Default rates: mint 0.5%, redeem 0.5%, rebalance 0.05%.
        _feeRates[FeeKind.Mint]      = 50;
        _feeRates[FeeKind.Redeem]    = 50;
        _feeRates[FeeKind.Rebalance] = 5;
    }

    // ─── IPlatformTreasury ──────────────────────────────────────────

    /// @inheritdoc IPlatformTreasury
    function collectFee(uint256 agentId, FeeKind kind, uint256 amount) external override {
        totalFeesCollected += amount;
        _feesByAgent[agentId] += amount;
        emit FeeCollected(agentId, kind, amount);
    }

    /// @inheritdoc IPlatformTreasury
    function withdraw(address to, uint256 amount) external override onlyAdmin {
        usdc.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @inheritdoc IPlatformTreasury
    function setFeeRate(FeeKind kind, uint256 newBps) external override onlyAdmin {
        if (newBps > MAX_FEE_BPS) revert FeeRateTooHigh(MAX_FEE_BPS);
        uint256 old = _feeRates[kind];
        _feeRates[kind] = newBps;
        emit FeeRateUpdated(kind, old, newBps);
    }

    /// @notice Batch update for all three fee kinds. Same per-kind bounds apply.
    function setFeeRates(uint256 mintBps, uint256 redeemBps, uint256 rebalanceBps)
        external
        onlyAdmin
    {
        if (mintBps > MAX_FEE_BPS || redeemBps > MAX_FEE_BPS || rebalanceBps > MAX_FEE_BPS) {
            revert FeeRateTooHigh(MAX_FEE_BPS);
        }
        _setRate(FeeKind.Mint, mintBps);
        _setRate(FeeKind.Redeem, redeemBps);
        _setRate(FeeKind.Rebalance, rebalanceBps);
    }

    /// @notice Transfer admin authority to a new address.
    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ─── views ──────────────────────────────────────────────────────

    /// @inheritdoc IPlatformTreasury
    function feeRate(FeeKind kind) external view override returns (uint256) {
        return _feeRates[kind];
    }

    /// @inheritdoc IPlatformTreasury
    function feesCollectedFor(uint256 agentId) external view override returns (uint256) {
        return _feesByAgent[agentId];
    }

    /// @notice Tuple view returning (mint, redeem, rebalance) rates in basis points.
    function feeRates() external view returns (uint256 mintBps, uint256 redeemBps, uint256 rebalanceBps) {
        return (
            _feeRates[FeeKind.Mint],
            _feeRates[FeeKind.Redeem],
            _feeRates[FeeKind.Rebalance]
        );
    }

    // ─── internal ───────────────────────────────────────────────────

    function _setRate(FeeKind kind, uint256 newBps) internal {
        uint256 old = _feeRates[kind];
        _feeRates[kind] = newBps;
        emit FeeRateUpdated(kind, old, newBps);
    }
}
