// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/AggregatorV3Interface.sol";

/// @title ChainlinkPriceOracle – Lấy giá ETH/USD từ Chainlink
contract ChainlinkPriceOracle {
    AggregatorV3Interface internal priceFeed;

    /// @notice Khởi tạo oracle với địa chỉ feed cụ thể (tuỳ testnet/mainnet)
    /// @param _feed Địa chỉ ETH/USD Price Feed của Chainlink
    constructor(address _feed) {
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Lấy giá ETH mới nhất, scale thành 1e18
    /// @return Giá ETH/USD (ví dụ: 2200 * 1e18)
    function getLatestEthPrice() external view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price) * 1e10; // Vì Chainlink trả về 8 decimals → scale lên 18
    }
}
