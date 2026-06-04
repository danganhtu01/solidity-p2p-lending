// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DebtToken – Đại diện khoản nợ người dùng sau khi vay
/// @notice Mint khi user vay ETH, burn khi user trả ETH
contract DebtToken is ERC20, Ownable {
    address public pool;

    /// 📢 Emit khi DebtToken được mint cho borrower
    event MintDebt(address indexed user, uint256 amount);

    /// 📢 Emit khi DebtToken bị burn sau khi repay
    event BurnDebt(address indexed user, uint256 amount);

    /// @notice Khởi tạo DebtToken với tên và symbol
    constructor(address _initialOwner)
        ERC20("Debt Token", "dETH")
        Ownable(_initialOwner)
    {}

    /// @notice Chỉ định địa chỉ LendingPool được phép mint/burn
    function setPool(address _pool) external onlyOwner {
        pool = _pool;
    }

    /// @notice Mint DebtToken cho borrower khi họ vay ETH
    function mint(address user, uint256 amount) external {
        require(msg.sender == pool, "Only pool can mint");
        _mint(user, amount);
        emit MintDebt(user, amount);
    }

    /// @notice Burn DebtToken khi borrower trả nợ
    function burn(address user, uint256 amount) external {
        require(msg.sender == pool, "Only pool can burn");
        _burn(user, amount);
        emit BurnDebt(user, amount);
    }

    /// @dev Chặn mọi hành vi chuyển nhượng DebtToken (chỉ cho phép mint và burn)
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), "DebtToken: non-transferable");
        super._update(from, to, value);
    }

}
