// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IPyth, PythStructs} from "../../src/v2/interfaces/IPyth.sol";

/// @notice Settable Chainlink aggregator for tests.
contract MockAggregator is AggregatorV3Interface {
    int256 public answer;
    uint8 public immutable dec;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        dec = _decimals;
    }

    function set(int256 _answer) external {
        answer = _answer;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Minimal settable Pyth stub for tests (returns a fresh price for an id).
contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal prices;

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        prices[id] = PythStructs.Price(price, 0, expo, block.timestamp);
    }

    function getPriceNoOlderThan(bytes32 id, uint256) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory p = prices[id];
        require(p.publishTime != 0, "no price");
        // keep it fresh for tests
        p.publishTime = block.timestamp;
        return p;
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }
}
