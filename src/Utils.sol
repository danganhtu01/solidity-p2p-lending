// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Utils - Helper functions used by lending contracts
library Utils {
    /// @notice Ngưỡng bị thanh lý (120% nghĩa là collateral phải ≥ 1.2x borrowed)
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120%

    /// @notice Check if a loan is overdue
    /// @param dueDate Timestamp of loan due
    function isOverdue(uint256 dueDate) internal view returns (bool) {
        return block.timestamp > dueDate;
    }

    /// @notice Check if loan is under-collateralized
    /// @param collateralAmount Amount of ETH used as collateral (in wei)
    /// @param borrowedAmount Amount borrowed by user (in wei)
    /// @param ethPrice ETH price in USD (1e18)
    /// @return true if collateral value < borrowed value * threshold
    function isUnderCollateralized(
        uint256 collateralAmount,
        uint256 borrowedAmount,
        uint256 ethPrice
    ) internal pure returns (bool) {
        // Convert both to USD
        uint256 collateralUSD = (collateralAmount * ethPrice) / 1e18;
        uint256 borrowedUSD = (borrowedAmount * ethPrice) / 1e18;

        // Collateral must ≥ borrowed * 120%, otherwise undercollateralized
        return collateralUSD * 100 < borrowedUSD * LIQUIDATION_THRESHOLD;
    }
}
