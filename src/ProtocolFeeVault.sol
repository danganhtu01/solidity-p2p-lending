// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ProtocolFeeVault - Lưu trữ phí từ lãi suất borrower trả
/// @notice LendingPool sẽ gọi gửi ETH vào đây, và chủ sở hữu có thể rút
contract ProtocolFeeVault {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Nhận ETH từ LendingPool
    receive() external payable {}

    /// @notice Chủ sở hữu rút toàn bộ phí đã thu
    function withdraw() external {
        require(msg.sender == owner, "Not owner");
        payable(owner).transfer(address(this).balance);
    }

    /// @notice Xem số ETH đã thu được
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Đổi chủ sở hữu nếu cần
    function setOwner(address newOwner) external {
        require(msg.sender == owner, "Not owner");
        owner = newOwner;
    }
}
