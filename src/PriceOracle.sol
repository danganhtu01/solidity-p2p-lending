// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Mock Price Oracle - Simulates ETH price for liquidation testing
/// @notice This contract allows manual price setting, to simulate Chainlink in testing
contract PriceOracle {
    /// @notice Price of 1 ETH in USD, scaled by 1e18 (e.g., 2000 USD = 2000 * 1e18)
    uint256 private ethPrice = 2000 * 1e18;

    /// @notice Get the current ETH price (used by LendingPool)
    /// @return Price of ETH in USD, scaled by 1e18
    function getPrice() external view returns (uint256) {
        return ethPrice;
    }

    /// @notice Set a new ETH price (for testing liquidation)
    /// @param _newPrice New ETH price in USD (scaled by 1e18)
    function setPrice(uint256 _newPrice) external {
        ethPrice = _newPrice;
    }
}
