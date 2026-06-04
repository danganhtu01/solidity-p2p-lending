// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VNDStablecoin - an educational stablecoin pegged to the Vietnamese Dong (VND)
/// @notice This is the protocol's **loan asset**: lenders supply VNDS, borrowers post ETH collateral
///         and borrow VNDS. 1 VNDS is intended to represent 1 VND.
/// @dev ⚠️ EDUCATIONAL / TESTNET ONLY. A real fiat-pegged stablecoin needs reserves, redemption, and
///      a peg-defence mechanism (off-chain VND backing, or on-chain over-collateralization à la DAI).
///      This token has NONE of that — the "peg" is purely nominal and is only reflected in the price
///      oracle (which quotes ETH in VND). Issuance is an owner `mint` plus an open `faucet` so anyone
///      can grab test VNDS. Uses 18 decimals (like ETH) so the protocol's 1e18 / RAY math stays
///      uniform; 1 VNDS = 1e18 base units = 1 VND.
contract VNDStablecoin is ERC20, Ownable {
    /// @notice Amount minted per `faucet()` call: 100,000,000 VND (so a tester can lend/borrow at a
    ///         realistic VND scale, where 1 ETH ≈ tens of millions of VND).
    uint256 public constant FAUCET_AMOUNT = 100_000_000 * 1e18;

    event Faucet(address indexed to, uint256 amount);

    constructor(address initialOwner) ERC20("VND Stablecoin", "VNDS") Ownable(initialOwner) {}

    /// @notice Controlled issuance by the owner (e.g. to seed initial pool liquidity).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Open testnet faucet — anyone can mint themselves FAUCET_AMOUNT VNDS to try the dApp.
    /// @dev No cooldown by design: this is throwaway test money on a testnet, not a real asset.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
        emit Faucet(msg.sender, FAUCET_AMOUNT);
    }
}
