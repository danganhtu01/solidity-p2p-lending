// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title aToken - Token đại diện tài sản gửi vào pool, sử dụng lãi kép (liquidity index)
contract aToken is ERC20, Ownable {
    address public pool;

    uint256 public constant RAY = 1e27; // Aave standard: 1 RAY = 1e27
    uint256 public liquidityIndex = RAY; // Bắt đầu 1:1
    uint256 public lastUpdateTimestamp;
    uint256 public interestRate; // annual rate (scaled 1e18)

    mapping(address => uint256) public userIndex;

    constructor(address _initialOwner) ERC20("aToken ETH", "aETH") Ownable(_initialOwner) {
        lastUpdateTimestamp = block.timestamp;
        interestRate = 3e16; // 3% mặc định
    }

    modifier onlyPool() {
        require(msg.sender == pool, "Only pool can call");
        _;
    }

    function setPool(address _pool) external onlyOwner {
        pool = _pool;
    }

    /// @notice Pool cập nhật lãi suất (APR), tính theo năm
    function updateInterestRate(uint256 newRate) external onlyPool {
        _accrue();
        interestRate = newRate;
    }

    /// @notice Mint aToken (user gửi ETH vào pool)
    function mint(address user, uint256 amount) external onlyPool {
        _accrue();

        uint256 scaledAmount = (amount * RAY) / liquidityIndex;
        _mint(user, scaledAmount);
        userIndex[user] = liquidityIndex;
    }

    /// @notice Burn aToken (user rút ETH khỏi pool)
    function burn(address user, uint256 amount) external onlyPool {
        _accrue();
        _burn(user, amount);
    }

    /// @dev Cập nhật chỉ số liquidityIndex theo thời gian
    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastUpdateTimestamp;
        if (elapsed == 0) return;

        uint256 accruedInterest = (liquidityIndex * interestRate * elapsed) / (365 days * 1e18);
        liquidityIndex += accruedInterest;
        lastUpdateTimestamp = block.timestamp;
    }

    /// @notice Dự đoán số ETH người dùng sẽ nhận được khi rút
    function previewWithdraw(address user) external view returns (uint256) {
        uint256 currentIndex = getLiquidityIndex();
        return (balanceOf(user) * currentIndex) / RAY;
    }

    /// @notice Lấy chỉ số liquidityIndex cập nhật
    function getLiquidityIndex() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdateTimestamp;
        if (elapsed == 0) return liquidityIndex;

        uint256 accruedInterest = (liquidityIndex * interestRate * elapsed) / (365 days * 1e18);
        return liquidityIndex + accruedInterest;
    }
}
