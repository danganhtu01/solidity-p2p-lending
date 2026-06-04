// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title LoanManager - Handles storage and basic struct for user loans
/// @notice This is inherited by LendingPool to manage user's loans
contract LoanManager {
    /// @notice Enum cho biết kiểu vay: stable hay variable
    enum RateMode { Stable, Variable }

    /// @notice Struct định nghĩa 1 khoản vay
    struct Loan {
        uint256 amountBorrowed;     // Số ETH vay (wei)
        uint256 collateralAmount;   // Số ETH thế chấp (wei)
        uint256 dueDate;            // Thời hạn đáo hạn (timestamp)
        bool isRepaid;              // Trạng thái đã trả nợ
        bool isLiquidated;          // ✅ Trạng thái đã bị thanh lý (mới thêm)
        uint256 interestRate;       // Lãi suất theo năm (scaled 1e18), ví dụ 6e16 = 6%
        RateMode rateMode;          // Kiểu vay: Stable hoặc Variable
        uint256 durationDays;       // Số ngày vay ban đầu
    }

    /// @notice Lưu trữ nhiều khoản vay theo địa chỉ người dùng
    mapping(address => Loan[]) internal userLoans;

    /// @notice Trả về chi tiết khoản vay của user tại index cụ thể
    function getUserLoan(address user, uint256 index) external view returns (
        uint256 amountBorrowed,
        uint256 collateralAmount,
        uint256 dueDate,
        bool isRepaid,
        bool isLiquidated,
        uint256 interestRate,
        RateMode rateMode,
        uint256 durationDays
    ) {
        Loan memory loan = userLoans[user][index];
        return (
            loan.amountBorrowed,
            loan.collateralAmount,
            loan.dueDate,
            loan.isRepaid,
            loan.isLiquidated,
            loan.interestRate,
            loan.rateMode,
            loan.durationDays
        );
    }
}
