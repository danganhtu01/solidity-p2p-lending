// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DebtToken.sol";

/// @title StableDebtToken – Token đại diện khoản vay VNDS lãi suất cố định
/// @notice Mint khi user vay với fixed rate, burn khi user trả nợ
contract StableDebtToken is DebtToken {
    constructor(address initialOwner) DebtToken(initialOwner) {}

    /// @notice Ghi đè tên và ký hiệu token
    function name() public pure override returns (string memory) {
        return "Stable Debt Token VND";
    }

    function symbol() public pure override returns (string memory) {
        return "sdVND";
    }
}
