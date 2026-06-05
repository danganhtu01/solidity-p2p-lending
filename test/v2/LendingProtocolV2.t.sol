// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {PriceOracleRouter} from "../../src/v2/PriceOracleRouter.sol";
import {LendingProtocolV2} from "../../src/v2/LendingProtocolV2.sol";
import {VNDStablecoinV2} from "../../src/v2/tokens/VNDStablecoinV2.sol";
import {MockERC20} from "../../src/v2/tokens/MockERC20.sol";
import {MockWETH9} from "../../src/v2/tokens/MockWETH9.sol";
import {MockAggregator, MockPyth} from "./Mocks.sol";

contract LendingProtocolV2Test is Test {
    PriceOracleRouter internal oracle;
    LendingProtocolV2 internal proto;
    VNDStablecoinV2 internal vndd;
    MockWETH9 internal weth;
    MockERC20 internal wsol;
    MockERC20 internal usdc;
    MockPyth internal pyth;
    MockAggregator internal ethFeed;
    MockAggregator internal usdcFeed;

    address internal lender = makeAddr("lender"); // USDC supplier
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal treasury = makeAddr("treasury");

    bytes32 internal constant SOL_ID = bytes32(uint256(0x5021));

    uint256 internal constant USD_VND = 25_400e18; // 25,400 VND per USD

    function setUp() public {
        // tokens
        vndd = new VNDStablecoinV2(address(this));
        weth = new MockWETH9();
        wsol = new MockERC20("Wrapped SOL", "wSOL", 18, 1000e18);
        usdc = new MockERC20("USD Coin", "USDC", 6, 1_000_000e6);

        // oracle + feeds
        pyth = new MockPyth();
        oracle = new PriceOracleRouter(address(pyth), USD_VND);
        ethFeed = new MockAggregator(3000e8, 8); // ETH/USD = $3000
        usdcFeed = new MockAggregator(1e8, 8); // USDC/USD = $1
        oracle.setChainlinkSource(address(weth), address(ethFeed));
        oracle.setChainlinkSource(address(usdc), address(usdcFeed));
        oracle.setPythSource(address(wsol), SOL_ID);
        pyth.setPrice(SOL_ID, 150e8, -8); // SOL/USD = $150

        // protocol
        proto = new LendingProtocolV2(address(oracle), address(vndd), treasury);
        vndd.setMinter(address(proto), true);
        proto.configureCollateral(address(weth), 18, 15000, 12000); // ETH: min 150%, liq 120%
        proto.configureCollateral(address(wsol), 18, 20000, 15000); // SOL: min 200%, liq 150%
        proto.configureDebt(address(vndd), LendingProtocolV2.DebtKind.Mint, 18, 200); // 2% stability fee
        proto.configureDebt(address(usdc), LendingProtocolV2.DebtKind.Pool, 6, 500); // 5% borrow rate

        // seed the USDC pool with a supplier
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(proto), type(uint256).max);
        proto.supply(address(usdc), 100_000e6);
        vm.stopPrank();
    }

    // --- helpers ---------------------------------------------------------

    function _wrapWeth(address who, uint256 amt) internal {
        vm.deal(who, amt);
        vm.prank(who);
        weth.deposit{value: amt}();
    }

    // open an ETH-collateral / VNDD-debt position for `borrower`
    function _openEthVndd(uint256 wethAmt, uint256 vnddAmt) internal returns (uint256 id) {
        _wrapWeth(borrower, wethAmt);
        vm.startPrank(borrower);
        weth.approve(address(proto), wethAmt);
        id = proto.openPosition(address(weth), wethAmt, address(vndd), vnddAmt);
        vm.stopPrank();
    }

    // --- oracle ----------------------------------------------------------

    function test_Oracle_UsdAndVndPrices() public view {
        assertEq(oracle.getUsdPrice(address(weth)), 3000e18, "ETH/USD");
        assertEq(oracle.getUsdPrice(address(usdc)), 1e18, "USDC/USD");
        assertEq(oracle.getUsdPrice(address(wsol)), 150e18, "SOL/USD via Pyth");
        assertEq(oracle.getVndPrice(address(weth)), 76_200_000e18, "ETH in VND = 3000 x 25,400");
    }

    function test_Oracle_OnlyUpdaterSetsRate() public {
        vm.prank(borrower);
        vm.expectRevert("Not updater");
        oracle.setUsdVndRate(26_000e18);

        oracle.setUsdVndRate(26_000e18); // owner is updater by default
        assertEq(oracle.usdVndRate(), 26_000e18);
    }

    // --- pair 1: ETH collateral -> mint VNDD (DAI-style) -----------------

    function test_EthVndd_OpenMintsVndd() public {
        _openEthVndd(1e18, 30_000_000e18); // 1 ETH ($3000 = 76.2M VND) -> mint 30M VNDD (~254%)
        assertEq(vndd.balanceOf(borrower), 30_000_000e18, "VNDD minted to borrower");
        assertEq(weth.balanceOf(address(proto)), 1e18, "protocol holds the WETH collateral");
        assertEq(proto.getPositionCount(borrower), 1, "position recorded");
    }

    function test_EthVndd_RevertsWhenUndercollateralized() public {
        _wrapWeth(borrower, 1e18);
        vm.startPrank(borrower);
        weth.approve(address(proto), 1e18);
        // 1 ETH = 76.2M VND; at 150% the max is ~50.8M. 60M must revert.
        vm.expectRevert("insufficient collateral");
        proto.openPosition(address(weth), 1e18, address(vndd), 60_000_000e18);
        vm.stopPrank();
    }

    function test_EthVndd_RepayBurnsVnddReturnsCollateral() public {
        uint256 id = _openEthVndd(1e18, 30_000_000e18);
        vm.warp(block.timestamp + 30 days); // accrue stability fee

        uint256 owed = proto.currentDebt(borrower, id);
        assertGt(owed, 30_000_000e18, "interest accrued");
        vndd.ownerMint(borrower, owed - 30_000_000e18); // top up for the interest

        uint256 supplyBefore = vndd.totalSupply();
        vm.startPrank(borrower);
        vndd.approve(address(proto), owed);
        proto.repay(id);
        vm.stopPrank();

        (,,, uint256 principal,,, bool active) = proto.getPosition(borrower, id);
        assertEq(principal, 0, "debt cleared");
        assertFalse(active, "position closed");
        assertEq(weth.balanceOf(borrower), 1e18, "collateral returned");
        assertEq(vndd.balanceOf(treasury), owed - 30_000_000e18, "stability fee to treasury");
        assertEq(vndd.totalSupply(), supplyBefore - 30_000_000e18, "principal burned (only fee remains)");
    }

    function test_EthVndd_LiquidateOnPriceDrop() public {
        uint256 id = _openEthVndd(1e18, 30_000_000e18); // healthy at $3000
        assertFalse(proto.isLiquidatable(borrower, id), "healthy at open");

        ethFeed.set(1200e8); // ETH crashes to $1200 -> ratio falls below 120%
        assertTrue(proto.isLiquidatable(borrower, id), "now liquidatable");

        uint256 owed = proto.currentDebt(borrower, id);
        vndd.ownerMint(liquidator, owed);
        vm.startPrank(liquidator);
        vndd.approve(address(proto), owed);
        proto.liquidate(borrower, id);
        vm.stopPrank();

        assertEq(weth.balanceOf(liquidator), 1e18, "liquidator seized the collateral");
        (,,,,,, bool active) = proto.getPosition(borrower, id);
        assertFalse(active, "position closed by liquidation");
    }

    function test_EthVndd_RevertsLiquidateWhenHealthy() public {
        uint256 id = _openEthVndd(1e18, 30_000_000e18);
        vndd.ownerMint(liquidator, 31_000_000e18);
        vm.startPrank(liquidator);
        vndd.approve(address(proto), 31_000_000e18);
        vm.expectRevert("position is healthy");
        proto.liquidate(borrower, id);
        vm.stopPrank();
    }

    // --- pair 4: SOL collateral -> borrow USDC (Aave-style pool) ---------

    function test_SolUsdc_BorrowFromPool() public {
        wsol.mint(borrower, 10e18); // 10 SOL = $1500
        vm.startPrank(borrower);
        wsol.approve(address(proto), 10e18);
        // at 200% min, max USDC = $750 = 750e6; borrow 500e6
        uint256 id = proto.openPosition(address(wsol), 10e18, address(usdc), 500e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(borrower), 500e6, "borrower received USDC from the pool");
        assertEq(proto.availableLiquidity(address(usdc)), 100_000e6 - 500e6, "pool liquidity reduced");
        assertEq(wsol.balanceOf(address(proto)), 10e18, "protocol holds the SOL collateral");
        assertTrue(id == 0);
    }

    function test_SolUsdc_RepayAccruesInterestToSuppliers() public {
        wsol.mint(borrower, 10e18);
        vm.startPrank(borrower);
        wsol.approve(address(proto), 10e18);
        uint256 id = proto.openPosition(address(wsol), 10e18, address(usdc), 500e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days); // 1 year => 5% interest = 25 USDC
        uint256 owed = proto.currentDebt(borrower, id);
        assertEq(owed, 525e6, "principal 500 + 5% = 525 USDC");

        usdc.mint(borrower, owed - 500e6); // top up for interest
        uint256 supplierBefore = proto.suppliedBalance(address(usdc), lender);

        vm.startPrank(borrower);
        usdc.approve(address(proto), owed);
        proto.repay(id);
        vm.stopPrank();

        assertGt(proto.suppliedBalance(address(usdc), lender), supplierBefore, "supplier earned interest");
        assertEq(wsol.balanceOf(borrower), 10e18, "SOL collateral returned");
    }

    // --- pair 3: SOL collateral -> mint VNDD -----------------------------

    function test_SolVndd_Open() public {
        wsol.mint(borrower, 10e18); // $1500 = 38,100,000 VND
        vm.startPrank(borrower);
        wsol.approve(address(proto), 10e18);
        // 200% min => max ~19,050,000 VNDD; mint 15,000,000
        proto.openPosition(address(wsol), 10e18, address(vndd), 15_000_000e18);
        vm.stopPrank();
        assertEq(vndd.balanceOf(borrower), 15_000_000e18, "VNDD minted against SOL");
    }

    // --- USDC supply side ------------------------------------------------

    function test_Usdc_SupplyAndWithdraw() public {
        // lender already supplied 100,000 in setUp; withdraw it all back (no borrows yet here)
        uint256 scaled = proto.scaledSupply(address(usdc), lender);
        vm.prank(lender);
        proto.withdrawSupply(address(usdc), scaled);
        assertEq(usdc.balanceOf(lender), 100_000e6, "supplier withdrew principal");
    }

    // --- collateral management ------------------------------------------

    function test_WithdrawCollateral_RevertsWhenWouldBreach() public {
        uint256 id = _openEthVndd(1e18, 30_000_000e18); // ratio ~254%, min 150%
        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        proto.withdrawCollateral(id, 0.7e18); // leaving 0.3 ETH can't back 30M VNDD
    }

    function test_AddCollateral_ImprovesRatio() public {
        uint256 id = _openEthVndd(1e18, 30_000_000e18);
        uint256 before = proto.collateralRatioBps(borrower, id);
        _wrapWeth(borrower, 1e18);
        vm.startPrank(borrower);
        weth.approve(address(proto), 1e18);
        proto.addCollateral(id, 1e18);
        vm.stopPrank();
        assertGt(proto.collateralRatioBps(borrower, id), before, "ratio improved");
    }

    // --- access control --------------------------------------------------

    function test_OnlyOwner_ConfiguresCollateral() public {
        vm.prank(borrower);
        vm.expectRevert();
        proto.configureCollateral(address(weth), 18, 15000, 12000);
    }

    function test_OnlyMinter_CanMintVndd() public {
        vm.prank(borrower);
        vm.expectRevert("VNDD: not a minter");
        vndd.mint(borrower, 1e18);
    }
}
