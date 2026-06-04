// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title InterestRateModel - Calculates dynamic interest rates based on pool usage
/// @notice Mô phỏng giống Aave: baseRate + slope dựa theo pool utilization
contract InterestRateModel {
    // 🟡 Lãi suất cơ bản khi pool chưa được sử dụng nhiều (2.5%)
    uint256 public constant BASE_RATE = 25e15; // 2.5%

    // 🟡 Slope nhẹ khi chưa đến 80% (3%)
    uint256 public constant SLOPE1 = 3e16; // 3%

    // 🟡 Slope mạnh khi vượt 80% (9%)
    uint256 public constant SLOPE2 = 9e16; // 9%

    // ✅ Tỷ lệ sử dụng tối ưu
    uint256 public constant OPTIMAL_UTILIZATION = 80e16; // 80%

    // ✅ Protocol giữ lại 0.5% (50 basis points)
    uint256 public constant PROTOCOL_FEE = 5e15; // 0.5%

    /// @notice Tính lãi suất cho borrower theo mức sử dụng
    /// @param totalLiquidity Tổng ETH trong pool
    /// @param totalDebt Tổng số ETH đang được vay
    /// @return interestRate Tổng lãi suất borrower phải trả (scaled 1e18)
    function getInterestRate(
        uint256 totalLiquidity,
        uint256 totalDebt
    ) external pure returns (uint256 interestRate) {
        if (totalLiquidity == 0) return BASE_RATE + PROTOCOL_FEE;

        uint256 utilization = (totalDebt * 1e18) / totalLiquidity;

        if (utilization <= OPTIMAL_UTILIZATION) {
            interestRate =
                BASE_RATE +
                (utilization * SLOPE1) / OPTIMAL_UTILIZATION;
        } else {
            uint256 excessUtil = utilization - OPTIMAL_UTILIZATION;
            interestRate =
                BASE_RATE +
                SLOPE1 +
                (excessUtil * SLOPE2) / (1e18 - OPTIMAL_UTILIZATION);
        }

        interestRate += PROTOCOL_FEE; // ✅ Cộng thêm phí giữ lại
    }

    /// @notice Trả về phần dành cho protocol
    function getProtocolFee() external pure returns (uint256) {
        return PROTOCOL_FEE;
    }
}
