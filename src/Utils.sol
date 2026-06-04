// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Utils - Helper functions used by lending contracts
library Utils {
    /// @notice Ngưỡng bị thanh lý (120% nghĩa là giá trị collateral phải ≥ 1.2x khoản nợ)
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120%

    /// @notice Check if a loan is overdue
    /// @param dueDate Timestamp of loan due
    function isOverdue(uint256 dueDate) internal view returns (bool) {
        return block.timestamp > dueDate;
    }

    /// @notice Check if a loan is under-collateralized.
    /// @dev Collateral is ETH, debt is VND, so the ETH→VND price does NOT cancel here (unlike the old
    ///      ETH/ETH design): a falling ETH price genuinely pushes a loan under water and makes it
    ///      liquidatable. Debt is already in VND, so it needs no conversion.
    /// @param collateralEth Amount of ETH used as collateral (in wei)
    /// @param borrowedVnd Amount of VND borrowed (1e18-scaled)
    /// @param ethPriceVnd ETH price in VND (1e18-scaled)
    /// @return true if collateral value (VND) < borrowed (VND) * threshold
    function isUnderCollateralized(
        uint256 collateralEth,
        uint256 borrowedVnd,
        uint256 ethPriceVnd
    ) internal pure returns (bool) {
        // Value the ETH collateral in VND; the debt is already in VND.
        uint256 collateralVnd = (collateralEth * ethPriceVnd) / 1e18;

        // Collateral must be ≥ borrowed * 120%, otherwise undercollateralized
        return collateralVnd * 100 < borrowedVnd * LIQUIDATION_THRESHOLD;
    }
}
