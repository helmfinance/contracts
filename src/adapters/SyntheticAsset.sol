// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISyntheticAsset} from "../interfaces/ISyntheticAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PythPriceAdapter} from "./PythPriceAdapter.sol";

/// @title SyntheticAsset
/// @notice Pyth-priced synthetic equity (e.g. sNVDA). Virtual position accounting —
///         USDC is locked on mint and released on burn at the prevailing oracle price.
/// @dev Non-transferable ERC-20. Only registered agent vaults may mint/burn.
contract SyntheticAsset is ISyntheticAsset, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when transfer/approve is attempted (non-transferable token).
    error NonTransferable();

    string private _name;
    string private _symbol;

    /// @notice Underlying equity ticker (e.g. "NVDA").
    string public underlyingSymbol;

    /// @inheritdoc ISyntheticAsset
    bytes32 public override pythFeedId;

    /// @notice The PythPriceAdapter used for pricing.
    PythPriceAdapter public priceAdapter;

    /// @notice USDC token used as collateral.
    IERC20 public usdc;

    /// @notice Admin that can register vaults.
    address public admin;

    /// @notice Whether an address is a registered agent vault.
    mapping(address => bool) public registeredVaults;

    /// @notice Per-vault synthetic share balance (18 decimals).
    mapping(address => uint256) private _balances;

    /// @notice Total synthetic shares outstanding.
    uint256 private _totalSupply;

    modifier onlyRegisteredVault() {
        if (!registeredVaults[msg.sender]) revert OnlyRegisteredVault();
        _;
    }

    /// @param name_ Token name (e.g. "Synthetic NVIDIA").
    /// @param symbol_ Token symbol (e.g. "sNVDA").
    /// @param underlyingSymbol_ Underlying equity ticker (e.g. "NVDA").
    /// @param pythFeedId_ Pyth feed identifier for pricing.
    /// @param priceAdapter_ Address of the PythPriceAdapter contract.
    /// @param usdc_ Address of the USDC token.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory underlyingSymbol_,
        bytes32 pythFeedId_,
        address priceAdapter_,
        address usdc_
    ) {
        _name = name_;
        _symbol = symbol_;
        underlyingSymbol = underlyingSymbol_;
        pythFeedId = pythFeedId_;
        priceAdapter = PythPriceAdapter(priceAdapter_);
        usdc = IERC20(usdc_);
        admin = msg.sender;
    }

    /// @notice Register an agent vault that is allowed to mint/burn.
    /// @param vault Address of the agent vault.
    function registerVault(address vault) external {
        require(msg.sender == admin, "only admin");
        registeredVaults[vault] = true;
    }

    // ---------------------------------------------------------------
    // ISyntheticAsset
    // ---------------------------------------------------------------

    /// @inheritdoc ISyntheticAsset
    function priceUSDC() public view returns (uint256) {
        return priceAdapter.getPriceUsdc(pythFeedId);
    }

    /// @inheritdoc ISyntheticAsset
    function mint(address to, uint256 usdcCollateral)
        external
        override
        onlyRegisteredVault
        nonReentrant
        returns (uint256 syntheticOut)
    {
        uint256 price = priceUSDC();

        // syntheticOut (18 dec) = usdcCollateral (6 dec) * 1e18 / price (6 dec)
        syntheticOut = (usdcCollateral * 1e18) / price;

        usdc.safeTransferFrom(msg.sender, address(this), usdcCollateral);

        _balances[msg.sender] += syntheticOut;
        _totalSupply += syntheticOut;

        emit Minted(to, syntheticOut, usdcCollateral, price);
    }

    /// @inheritdoc ISyntheticAsset
    function burn(address from, uint256 syntheticIn)
        external
        override
        onlyRegisteredVault
        nonReentrant
        returns (uint256 usdcOut)
    {
        require(_balances[msg.sender] >= syntheticIn, "insufficient balance");

        uint256 price = priceUSDC();

        // usdcOut (6 dec) = syntheticIn (18 dec) * price (6 dec) / 1e18
        usdcOut = (syntheticIn * price) / 1e18;

        _balances[msg.sender] -= syntheticIn;
        _totalSupply -= syntheticIn;

        usdc.safeTransfer(from, usdcOut);

        emit Burned(from, syntheticIn, usdcOut, price);
    }

    // ---------------------------------------------------------------
    // ERC-20 read interface
    // ---------------------------------------------------------------

    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc ISyntheticAsset
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    // ---------------------------------------------------------------
    // ERC-20 write interface — all disabled (non-transferable)
    // ---------------------------------------------------------------

    function transfer(address, uint256) external pure override returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert NonTransferable();
    }
}
