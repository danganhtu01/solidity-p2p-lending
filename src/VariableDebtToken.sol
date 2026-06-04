// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DebtToken.sol";

/// @title VariableDebtToken – Token đại diện khoản vay lãi suất biến động
/// @notice Mint khi user vay với lãi suất thay đổi, burn khi trả nợ
contract VariableDebtToken is DebtToken {
    constructor(address initialOwner) DebtToken(initialOwner) {}

    /// @notice Ghi đè tên token
    function name() public pure override returns (string memory) {
        return "Variable Debt Token";
    }

    /// @notice Ghi đè symbol token
    function symbol() public pure override returns (string memory) {
        return "vdETH";
    }
}
