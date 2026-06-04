// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ProtocolFeeVault - Lưu trữ phí (bằng VNDD) từ lãi suất borrower trả
/// @notice LendingPool chuyển VNDD vào đây bằng ERC20 transfer, và chủ sở hữu có thể rút.
/// @dev Loan asset đổi từ ETH sang VNDD, nên vault giờ giữ một ERC20 (VNDD) thay vì native ETH.
contract ProtocolFeeVault {
    address public owner;
    IERC20 public immutable vnd;

    constructor(address _vnd) {
        owner = msg.sender;
        vnd = IERC20(_vnd);
    }

    /// @notice Chủ sở hữu rút toàn bộ phí VNDD đã thu
    function withdraw() external {
        require(msg.sender == owner, "Not owner");
        uint256 bal = vnd.balanceOf(address(this));
        require(vnd.transfer(owner, bal), "VND transfer failed");
    }

    /// @notice Xem số VNDD đã thu được
    function getBalance() external view returns (uint256) {
        return vnd.balanceOf(address(this));
    }

    /// @notice Đổi chủ sở hữu nếu cần
    function setOwner(address newOwner) external {
        require(msg.sender == owner, "Not owner");
        owner = newOwner;
    }
}
