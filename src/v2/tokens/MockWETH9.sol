// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWETH9 - canonical Wrapped Ether (WETH9) pattern
/// @notice Lets users turn native (test) ETH into an ERC-20 so the protocol can treat ETH collateral
///         uniformly alongside other ERC-20 collateral (wSOL). 1 WETH is always backed 1:1 by 1 ETH:
///         `deposit()` mints WETH for the ETH you send; `withdraw()` burns WETH and returns the ETH.
contract MockWETH9 is ERC20 {
    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        deposit();
    }
}
