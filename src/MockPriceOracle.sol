// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MockPriceOracle - Chỉ dùng để test, giả lập giá ETH/USD.
contract MockPriceOracle {
    uint256 private ethPrice;

    constructor(uint256 _initialPrice) {
        ethPrice = _initialPrice;  // Ví dụ khởi tạo: 2000 * 1e18
    }

    function getLatestEthPrice() external view returns (uint256) {
        return ethPrice;
    }

    function setEthPrice(uint256 _newPrice) external {
        ethPrice = _newPrice;
    }
}
