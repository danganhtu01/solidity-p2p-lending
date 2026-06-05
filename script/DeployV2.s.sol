// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {PriceOracleRouter} from "../src/v2/PriceOracleRouter.sol";
import {LendingProtocolV2} from "../src/v2/LendingProtocolV2.sol";
import {VNDStablecoinV2} from "../src/v2/tokens/VNDStablecoinV2.sol";
import {MockERC20} from "../src/v2/tokens/MockERC20.sol";
import {MockWETH9} from "../src/v2/tokens/MockWETH9.sol";

/// @title DeployV2 - deploys the multi-asset (ETH/SOL × VNDD/USDC) v2 stack to Sepolia
/// @notice Wires REAL oracles: Chainlink ETH/USD + USDC/USD, Pyth SOL/USD. USD/VND is admin-set
///         (fed by the off-chain Google updater). Run:
///         forge script script/DeployV2.s.sol --rpc-url sepolia --broadcast --private-key $PRIVATE_KEY --slow
contract DeployV2 is Script {
    // --- Sepolia (chainId 11155111) oracle wiring (verified live) ---
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Chainlink
    address constant USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E; // Chainlink
    address constant PYTH = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21; // Pyth on Sepolia
    bytes32 constant SOL_USD_ID = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d; // Pyth SOL/USD

    uint256 constant INIT_USD_VND = 25_400e18; // VND per USD (admin-set; updated off-chain)
    uint256 constant SEED_USDC = 100_000e6; // seed the USDC borrow pool

    function run() external {
        vm.startBroadcast();
        address owner = msg.sender;

        // tokens
        VNDStablecoinV2 vndd = new VNDStablecoinV2(owner);
        MockWETH9 weth = new MockWETH9();
        MockERC20 wsol = new MockERC20("Wrapped SOL (test)", "wSOL", 18, 1000e18);
        MockERC20 usdc = new MockERC20("USD Coin (test)", "USDC", 6, 10_000e6);

        // oracle router with real feeds
        PriceOracleRouter oracle = new PriceOracleRouter(PYTH, INIT_USD_VND);
        oracle.setChainlinkSource(address(weth), ETH_USD_FEED);
        oracle.setChainlinkSource(address(usdc), USDC_USD_FEED);
        oracle.setPythSource(address(wsol), SOL_USD_ID);
        oracle.setMaxStaleSeconds(1 days); // testnet: Pyth updates are sporadic; tighten in production

        // protocol
        LendingProtocolV2 proto = new LendingProtocolV2(address(oracle), address(vndd), owner);
        vndd.setMinter(address(proto), true);
        proto.configureCollateral(address(weth), 18, 15000, 12000); // ETH: borrow at 150%, liquidate <120%
        proto.configureCollateral(address(wsol), 18, 20000, 15000); // SOL: borrow at 200%, liquidate <150%
        proto.configureDebt(address(vndd), LendingProtocolV2.DebtKind.Mint, 18, 200); // VNDD: 2% stability fee
        proto.configureDebt(address(usdc), LendingProtocolV2.DebtKind.Pool, 6, 500); // USDC: 5% borrow rate

        // seed the USDC borrow pool so USDC is borrowable immediately
        usdc.mint(owner, SEED_USDC);
        usdc.approve(address(proto), SEED_USDC);
        proto.supply(address(usdc), SEED_USDC);

        vm.stopBroadcast();

        console.log("PriceOracleRouter :", address(oracle));
        console.log("LendingProtocolV2 :", address(proto));
        console.log("VNDStablecoinV2   :", address(vndd));
        console.log("MockWETH9 (WETH)  :", address(weth));
        console.log("wSOL              :", address(wsol));
        console.log("USDC (test)       :", address(usdc));
        console.log("Pyth              :", PYTH);
        console.log("Seeded USDC pool  :", SEED_USDC);
        console.log("Chain id          :", block.chainid);
    }
}
