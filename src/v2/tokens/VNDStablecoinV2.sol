// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VNDStablecoinV2 - VND-pegged stablecoin with role-based mint/burn (DAI-style)
/// @notice Unlike v1 (owner-only mint), v2 lets authorized **minters** (the lending protocol's vault)
///         create and destroy VNDD against on-chain collateral. That is what turns VNDD into a *real*
///         over-collateralized stablecoin: every unit in circulation is backed by a collateralized
///         position, and is burned when that position is repaid.
/// @dev Still 18 decimals; 1 VNDD = 1 VND (nominal peg, enforced by collateral + the oracle, not reserves).
contract VNDStablecoinV2 is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 100_000_000 * 1e18; // 100,000,000 VND test funds

    mapping(address => bool) public isMinter;

    event MinterSet(address indexed account, bool allowed);
    event Faucet(address indexed to, uint256 amount);

    constructor(address initialOwner) ERC20("VND Stablecoin", "VNDD") Ownable(initialOwner) {}

    modifier onlyMinter() {
        require(isMinter[msg.sender], "VNDD: not a minter");
        _;
    }

    /// @notice Authorize (or revoke) a contract that may mint/burn VNDD — e.g. the vault engine.
    function setMinter(address account, bool allowed) external onlyOwner {
        isMinter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    /// @notice Mint VNDD into existence against collateral (only the vault).
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    /// @notice Burn VNDD on repayment (only the vault).
    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    /// @notice Owner can still mint directly (e.g. to seed demos or a separate market).
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Open testnet faucet for trying the dApp.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
        emit Faucet(msg.sender, FAUCET_AMOUNT);
    }
}
