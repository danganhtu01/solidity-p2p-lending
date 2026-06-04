// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {VNDStablecoin} from "../src/VNDStablecoin.sol";
import {aToken} from "../src/aToken.sol";
import {StableDebtToken} from "../src/StableDebtToken.sol";
import {VariableDebtToken} from "../src/VariableDebtToken.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

/// @title Deploy - deploys the full VND-stablecoin P2P lending stack and wires it together
/// @notice Run a local dry-run:   forge script script/Deploy.s.sol
///         Deploy to a testnet:   forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --account deployer
contract Deploy is Script {
    // Initial mock ETH price in VND (1e18-scaled): 70,000,000 VND per ETH. Swap MockPriceOracle for a
    // real ETH/VND oracle for a production deploy.
    uint256 public constant INITIAL_ETH_PRICE_VND = 70_000_000e18;

    // VNDD minted to the deployer, and how much of it is seeded into the pool as starting liquidity.
    uint256 public constant DEPLOYER_MINT = 10_000_000_000e18; // 10,000,000,000 VND
    uint256 public constant SEED_LIQUIDITY = 1_000_000_000e18; //  1,000,000,000 VND

    function run() external {
        vm.startBroadcast();
        address owner = msg.sender;

        VNDStablecoin vnd = new VNDStablecoin(owner);
        MockPriceOracle oracle = new MockPriceOracle(INITIAL_ETH_PRICE_VND);
        aToken at = new aToken(owner);
        StableDebtToken sdt = new StableDebtToken(owner);
        VariableDebtToken vdt = new VariableDebtToken(owner);
        InterestRateModel irm = new InterestRateModel();
        ProtocolFeeVault vault = new ProtocolFeeVault(address(vnd));

        LendingPool pool = new LendingPool(
            address(vnd), address(oracle), address(at), address(sdt), address(vdt), address(irm), address(vault)
        );

        // Only the pool may mint/burn the deposit + debt tokens
        at.setPool(address(pool));
        sdt.setPool(address(pool));
        vdt.setPool(address(pool));

        // Mint the deployer some VNDD and seed the pool with starting liquidity so borrowing works
        // immediately. (Anyone else can grab test VNDD via vnd.faucet().)
        vnd.mint(owner, DEPLOYER_MINT);
        vnd.approve(address(pool), SEED_LIQUIDITY);
        pool.deposit(SEED_LIQUIDITY);

        vm.stopBroadcast();

        console.log("VNDStablecoin    :", address(vnd));
        console.log("LendingPool      :", address(pool));
        console.log("MockPriceOracle  :", address(oracle));
        console.log("aToken (aVND)    :", address(at));
        console.log("StableDebtToken  :", address(sdt));
        console.log("VariableDebtToken:", address(vdt));
        console.log("InterestRateModel:", address(irm));
        console.log("ProtocolFeeVault :", address(vault));
        console.log("Seeded liquidity :", SEED_LIQUIDITY);
        console.log("Chain id         :", block.chainid);
    }
}
