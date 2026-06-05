// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "./interfaces/IPyth.sol";

/// @title PriceOracleRouter - one oracle facade over Chainlink, Pyth, and a manual rate
/// @notice Each asset is priced by exactly one source:
///   - Chainlink (push): ETH/USD, USDC/USD — read `latestRoundData()` directly. (Real on Sepolia.)
///   - Pyth (pull): SOL/USD — read a recently-posted price; the frontend/keeper posts updates first.
///   - Manual: a fallback owner/updater-set USD price (for assets without a feed on this network).
/// And one global **USD→VND rate** (`usdVndRate`, VND per 1 USD, 1e18-scaled) supplied off-chain from a
/// real FX source (e.g. Google), because NO decentralized oracle carries the Vietnamese Dong.
/// @dev `getUsdPrice` returns USD per *whole* token (1e18). Callers scale by the token's own decimals.
contract PriceOracleRouter is Ownable {
    enum SourceKind {
        None,
        Chainlink,
        Pyth,
        Manual
    }

    struct Source {
        SourceKind kind;
        address chainlinkFeed; // when Chainlink
        bytes32 pythId; // when Pyth
        uint256 manualUsdPrice; // when Manual (USD per whole token, 1e18)
    }

    IPyth public pyth; // Pyth contract on this network (0 if unused)
    mapping(address => Source) public sources; // asset => price source
    uint256 public usdVndRate; // VND per 1 USD, 1e18-scaled (e.g. 25_400e18)
    uint256 public maxStaleSeconds = 1 hours; // reject prices older than this
    address public updater; // may push usdVndRate + manual prices (the off-chain keeper)

    event SourceSet(address indexed asset, SourceKind kind);
    event UsdVndRateSet(uint256 rate);
    event ManualPriceSet(address indexed asset, uint256 usdPrice);
    event UpdaterSet(address indexed updater);

    constructor(address _pyth, uint256 _initialUsdVndRate) Ownable(msg.sender) {
        pyth = IPyth(_pyth);
        usdVndRate = _initialUsdVndRate;
        updater = msg.sender;
    }

    modifier onlyUpdater() {
        require(msg.sender == updater || msg.sender == owner(), "Not updater");
        _;
    }

    // --- configuration (owner) ------------------------------------------

    function setChainlinkSource(address asset, address feed) external onlyOwner {
        sources[asset] = Source(SourceKind.Chainlink, feed, bytes32(0), 0);
        emit SourceSet(asset, SourceKind.Chainlink);
    }

    function setPythSource(address asset, bytes32 pythId) external onlyOwner {
        sources[asset] = Source(SourceKind.Pyth, address(0), pythId, 0);
        emit SourceSet(asset, SourceKind.Pyth);
    }

    function setManualSource(address asset, uint256 usdPrice) external onlyOwner {
        sources[asset] = Source(SourceKind.Manual, address(0), bytes32(0), usdPrice);
        emit SourceSet(asset, SourceKind.Manual);
    }

    function setPyth(address _pyth) external onlyOwner {
        pyth = IPyth(_pyth);
    }

    function setMaxStaleSeconds(uint256 s) external onlyOwner {
        require(s > 0, "zero");
        maxStaleSeconds = s;
    }

    function setUpdater(address _updater) external onlyOwner {
        updater = _updater;
        emit UpdaterSet(_updater);
    }

    // --- live updates (updater/keeper) ----------------------------------

    /// @notice Push the latest USD→VND rate (VND per 1 USD, 1e18-scaled) from the off-chain FX source.
    function setUsdVndRate(uint256 rate) external onlyUpdater {
        require(rate > 0, "zero rate");
        usdVndRate = rate;
        emit UsdVndRateSet(rate);
    }

    /// @notice Update a manual asset's USD price (for assets configured as Manual).
    function setManualPrice(address asset, uint256 usdPrice) external onlyUpdater {
        require(sources[asset].kind == SourceKind.Manual, "not manual");
        require(usdPrice > 0, "zero");
        sources[asset].manualUsdPrice = usdPrice;
        emit ManualPriceSet(asset, usdPrice);
    }

    // --- reads ----------------------------------------------------------

    /// @notice USD price per whole token, 1e18-scaled.
    function getUsdPrice(address asset) public view returns (uint256) {
        Source memory s = sources[asset];
        if (s.kind == SourceKind.Chainlink) {
            AggregatorV3Interface feed = AggregatorV3Interface(s.chainlinkFeed);
            (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
            require(answer > 0, "bad chainlink price");
            require(block.timestamp - updatedAt <= maxStaleSeconds, "stale chainlink price");
            return uint256(answer) * 1e18 / (10 ** feed.decimals());
        } else if (s.kind == SourceKind.Pyth) {
            PythStructs.Price memory p = pyth.getPriceNoOlderThan(s.pythId, maxStaleSeconds);
            return _pythTo1e18(p.price, p.expo);
        } else if (s.kind == SourceKind.Manual) {
            require(s.manualUsdPrice > 0, "manual price unset");
            return s.manualUsdPrice;
        }
        revert("no price source");
    }

    /// @notice VND price per whole token, 1e18-scaled = USD price x USD/VND rate.
    function getVndPrice(address asset) external view returns (uint256) {
        return getUsdPrice(asset) * usdVndRate / 1e18;
    }

    /// @notice Convert a USD amount (1e18) to VND (1e18) using the current rate.
    function usdToVnd(uint256 usdAmount) external view returns (uint256) {
        return usdAmount * usdVndRate / 1e18;
    }

    /// @notice Convert a VND amount (1e18) to USD (1e18) using the current rate.
    function vndToUsd(uint256 vndAmount) external view returns (uint256) {
        return vndAmount * 1e18 / usdVndRate;
    }

    /// @dev Scale a Pyth (price, expo) pair to a positive 1e18-scaled integer.
    function _pythTo1e18(int64 price, int32 expo) internal pure returns (uint256) {
        require(price > 0, "bad pyth price");
        uint256 p = uint256(uint64(price));
        int256 power = int256(18) + int256(expo); // target 1e18
        if (power >= 0) {
            return p * (10 ** uint256(power));
        } else {
            return p / (10 ** uint256(-power));
        }
    }
}
