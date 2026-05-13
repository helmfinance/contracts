// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Mintable ERC-20 used as testnet USDC. On Mantle Sepolia (chainId
///         5003) and local Foundry/anvil (31337), addresses registered via
///         {addMinter} may call {mint} — this lets adapters mint testnet USDC
///         to cover simulated yield and P&L. On any other chain, only the
///         minterAdmin can mint, so accidental mainnet deployment can't be
///         abused to print real value.
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    /// @notice Address with unconditional mint authority and the right to
    ///         add/remove minters. Set to the deployer.
    address public minterAdmin;

    /// @notice Addresses authorised to mint on testnet chains only.
    mapping(address => bool) public minters;

    error NotMinterAdmin();
    error NotMinter();

    event MinterAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
        minterAdmin = msg.sender;
        emit MinterAdminTransferred(address(0), msg.sender);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    modifier onlyMinterAdmin() {
        if (msg.sender != minterAdmin) revert NotMinterAdmin();
        _;
    }

    /// @notice Caller passes if (a) they are minterAdmin, or (b) they are in
    ///         the minters set AND we're on a testnet chain (5003 = Mantle
    ///         Sepolia, 31337 = anvil/Foundry default).
    modifier onlyMinter() {
        if (msg.sender != minterAdmin) {
            bool testnet = block.chainid == 5003 || block.chainid == 31337;
            if (!testnet || !minters[msg.sender]) revert NotMinter();
        }
        _;
    }

    function addMinter(address minter) external onlyMinterAdmin {
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyMinterAdmin {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    function transferMinterAdmin(address newAdmin) external onlyMinterAdmin {
        emit MinterAdminTransferred(minterAdmin, newAdmin);
        minterAdmin = newAdmin;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }
}
