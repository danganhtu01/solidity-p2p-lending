// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20 - a faucet-mintable test token with configurable decimals
/// @notice Stand-in for assets that have no canonical testnet token here — e.g. wrapped SOL (`wSOL`,
///         18 dec) and a test `USDC` (6 dec, like the real thing). Educational/testnet only.
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;
    uint256 public faucetAmount;

    event Faucet(address indexed to, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        faucetAmount = faucetAmount_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setFaucetAmount(uint256 amount) external onlyOwner {
        faucetAmount = amount;
    }

    /// @notice Open testnet faucet — mint yourself the configured amount.
    function faucet() external {
        _mint(msg.sender, faucetAmount);
        emit Faucet(msg.sender, faucetAmount);
    }
}
