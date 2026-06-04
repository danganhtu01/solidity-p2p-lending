// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IPriceOracle - Interface chuẩn cho các Oracle (Chainlink hoặc Mock)
interface IPriceOracle {
    /// @notice Trả về giá ETH/USD (scaled 1e18)
    function getLatestEthPrice() external view returns (uint256);
}
