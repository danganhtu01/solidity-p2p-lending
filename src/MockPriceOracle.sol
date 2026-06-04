// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockPriceOracle - settable ETH price, quoted in VND, for testing
/// @notice Returns the price of 1 ETH **in VND** (1e18-scaled), e.g. 70,000,000 VND/ETH = 70_000_000e18.
///         The protocol's loan unit is VND (see VNDStablecoin), so collateral (ETH) is valued against
///         this feed while debt is already in VND. Because the two assets now differ, the price no
///         longer cancels in the collateral check — under-collateralization is a real, reachable
///         liquidation trigger (unlike the old single-asset ETH/ETH design).
/// @dev FIX (#5): the setter is owner-only. An open setter would let anyone move the price and grief
///      collateral checks / liquidations. Function names are kept (`getLatestEthPrice`/`setEthPrice`)
///      for IPriceOracle compatibility — only the *unit* changed (USD → VND).
contract MockPriceOracle is Ownable {
    uint256 private ethPriceVnd;

    constructor(uint256 _initialPriceVnd) Ownable(msg.sender) {
        ethPriceVnd = _initialPriceVnd; // e.g. 70_000_000 * 1e18 (70,000,000 VND per ETH)
    }

    /// @notice Price of 1 ETH in VND (1e18-scaled).
    function getLatestEthPrice() external view returns (uint256) {
        return ethPriceVnd;
    }

    function setEthPrice(uint256 _newPriceVnd) external onlyOwner {
        ethPriceVnd = _newPriceVnd;
    }
}
