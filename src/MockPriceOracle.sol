// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockPriceOracle - settable ETH/USD price for testing
/// @notice FIX (#5): price setter is now owner-only. An open setter would let anyone move the
///         price and grief collateral checks / liquidations.
contract MockPriceOracle is Ownable {
    uint256 private ethPrice;

    constructor(uint256 _initialPrice) Ownable(msg.sender) {
        ethPrice = _initialPrice; // e.g. 2000 * 1e18
    }

    function getLatestEthPrice() external view returns (uint256) {
        return ethPrice;
    }

    function setEthPrice(uint256 _newPrice) external onlyOwner {
        ethPrice = _newPrice;
    }
}
