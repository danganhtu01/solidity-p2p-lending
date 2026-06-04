// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {aToken} from "../src/aToken.sol";
import {StableDebtToken} from "../src/StableDebtToken.sol";
import {VariableDebtToken} from "../src/VariableDebtToken.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

/// @title Deploy - deploys the full P2P lending stack and wires it together
/// @notice Run a local dry-run:   forge script script/Deploy.s.sol
///         Deploy to a testnet:   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
contract Deploy is Script {
    // Initial mock ETH price ($2000, scaled to 1e18). Swap MockPriceOracle for
    // ChainlinkPriceOracle (with a real feed address) for a production deploy.
    uint256 public constant INITIAL_ETH_PRICE = 2000e18;

    function run() external {
        vm.startBroadcast();
        address owner = msg.sender;

        MockPriceOracle oracle = new MockPriceOracle(INITIAL_ETH_PRICE);
        aToken at = new aToken(owner);
        StableDebtToken sdt = new StableDebtToken(owner);
        VariableDebtToken vdt = new VariableDebtToken(owner);
        InterestRateModel irm = new InterestRateModel();
        ProtocolFeeVault vault = new ProtocolFeeVault();

        LendingPool pool = new LendingPool(
            address(oracle), address(at), address(sdt), address(vdt), address(irm), payable(address(vault))
        );

        // Only the pool may mint/burn the deposit + debt tokens
        at.setPool(address(pool));
        sdt.setPool(address(pool));
        vdt.setPool(address(pool));

        vm.stopBroadcast();

        console.log("LendingPool      :", address(pool));
        console.log("MockPriceOracle  :", address(oracle));
        console.log("aToken           :", address(at));
        console.log("StableDebtToken  :", address(sdt));
        console.log("VariableDebtToken:", address(vdt));
        console.log("InterestRateModel:", address(irm));
        console.log("ProtocolFeeVault :", address(vault));
        console.log("Chain id         :", block.chainid);
    }
}
