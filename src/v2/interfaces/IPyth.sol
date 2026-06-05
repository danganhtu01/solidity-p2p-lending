// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Minimal Pyth interface (vendored subset of @pythnetwork/pyth-sdk-solidity)
/// @notice Pyth is a PULL oracle: an off-chain "Hermes" service signs the latest price, a caller posts
///         it on-chain via updatePriceFeeds{value: fee}(...), and contracts then read it. We vendor only
///         the pieces this protocol needs (read + update + fee) to avoid an extra dependency.
library PythStructs {
    /// @dev `price` is scaled by 10**expo (expo is normally negative, e.g. -8). publishTime is unix secs.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
}

interface IPyth {
    /// @notice Latest price for `id`, reverting if it is older than `age` seconds.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory);

    /// @notice Latest price for `id` with no freshness check (use with care).
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory);

    /// @notice Post fresh signed price updates on-chain. Pay `getUpdateFee(updateData)` as msg.value.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice The wei fee required to submit `updateData`.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
}
