// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title aToken - interest-bearing receipt for VNDS deposited into the pool
/// @notice Aave-style scaled-balance model: a holder's ERC20 balance is the *scaled* amount, and the
///         redeemable VNDS = scaledBalance * liquidityIndex / RAY.
/// @dev FIX (#4): the liquidity index now rises ONLY when the pool credits REAL interest via
///      accrueToLenders(). The original design grew the index purely with elapsed time at a fixed
///      rate, i.e. it manufactured yield that the pool did not actually hold (insolvency risk).
contract aToken is ERC20, Ownable {
    address public pool;

    uint256 public constant RAY = 1e27; // Aave standard: 1 RAY = 1e27
    uint256 public liquidityIndex = RAY; // starts 1:1

    constructor(address _initialOwner) ERC20("aToken VND", "aVND") Ownable(_initialOwner) {}

    modifier onlyPool() {
        require(msg.sender == pool, "Only pool can call");
        _;
    }

    function setPool(address _pool) external onlyOwner {
        pool = _pool;
    }

    /// @notice Mint scaled aTokens for VNDS deposited (`amount` is the underlying VNDS in 1e18 units)
    function mint(address user, uint256 amount) external onlyPool {
        uint256 scaledAmount = (amount * RAY) / liquidityIndex;
        _mint(user, scaledAmount);
    }

    /// @notice Burn scaled aTokens when a lender withdraws
    function burn(address user, uint256 amount) external onlyPool {
        _burn(user, amount);
    }

    /// @notice Credit real interest to all lenders by raising the liquidity index.
    /// @dev The VNDS itself stays in the pool; this only increases what each scaled token redeems.
    function accrueToLenders(uint256 vndAmount) external onlyPool {
        uint256 supply = totalSupply();
        if (supply == 0 || vndAmount == 0) return;
        liquidityIndex += (vndAmount * RAY) / supply;
    }

    /// @notice Current liquidity index (VNDS redeemable per scaled token = index / RAY)
    function getLiquidityIndex() public view returns (uint256) {
        return liquidityIndex;
    }

    /// @notice Underlying VNDS a user could withdraw right now
    function previewWithdraw(address user) external view returns (uint256) {
        return (balanceOf(user) * liquidityIndex) / RAY;
    }
}
