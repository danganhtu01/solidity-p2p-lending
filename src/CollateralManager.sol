// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LoanManager.sol";
import "./Utils.sol";

/// @title CollateralManager - Tách riêng xử lý thanh lý tài sản khỏi LendingPool
/// @notice LendingPool sẽ gọi hàm handleLiquidation() khi phát hiện user quá hạn hoặc thiếu tài sản thế chấp
contract CollateralManager is LoanManager {
    address public pool;

    /// @notice Event phát khi thanh lý thành công
    event LoanLiquidated(address indexed borrower, uint256 indexed index, address indexed liquidator, uint256 collateralSeized);

    /// @notice Chỉ cho gọi 1 lần để set pool (LendingPool)
    function setPool(address _pool) external {
        require(pool == address(0), "Pool already set");
        pool = _pool;
    }

    /// @dev Gọi từ LendingPool để thực hiện thanh lý nếu đủ điều kiện
    function handleLiquidation(
        address borrower,
        uint256 index,
        uint256 ethPrice
    ) external {
        require(msg.sender == pool, "Only LendingPool can call");

        Loan storage loan = userLoans[borrower][index];

        require(!loan.isRepaid, "Loan already repaid");
        require(!loan.isLiquidated, "Loan already liquidated");

        bool overdue = Utils.isOverdue(loan.dueDate);
        bool underCollateralized = Utils.isUnderCollateralized(
            loan.collateralAmount,
            loan.amountBorrowed,
            ethPrice
        );

        require(overdue || underCollateralized, "Not eligible for liquidation");

        loan.isRepaid = true;
        loan.isLiquidated = true;

        uint256 collateral = loan.collateralAmount;
        loan.collateralAmount = 0;

        // ⚠️ Trả toàn bộ tài sản thế chấp về cho người gọi (liquidator)
        (bool sent, ) = payable(msg.sender).call{value: collateral}("");
        require(sent, "Collateral transfer failed");

        emit LoanLiquidated(borrower, index, msg.sender, collateral);
    }
}
