// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PriceOracle - older settable mock, superseded by MockPriceOracle
/// @notice FIX (#5): price setter is now owner-only.
contract PriceOracle is Ownable {
    /// @notice Price of 1 ETH in USD, scaled by 1e18 (e.g., 2000 USD = 2000 * 1e18)
    uint256 private ethPrice = 2000 * 1e18;

    constructor() Ownable(msg.sender) {}

    function getPrice() external view returns (uint256) {
        return ethPrice;
    }

    function setPrice(uint256 _newPrice) external onlyOwner {
        ethPrice = _newPrice;
    }
}
