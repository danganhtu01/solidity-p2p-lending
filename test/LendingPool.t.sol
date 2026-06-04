// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {VNDStablecoin} from "../src/VNDStablecoin.sol";
import {aToken} from "../src/aToken.sol";
import {StableDebtToken} from "../src/StableDebtToken.sol";
import {VariableDebtToken} from "../src/VariableDebtToken.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

/// @title LendingPool test suite (VND-stablecoin version)
/// @notice The loan asset is VNDD: lenders supply VNDD, borrowers lock ETH collateral and borrow VNDD,
///         repay/liquidate in VNDD. Covers the full lifecycle plus the now-reachable
///         under-collateralization liquidation that the old single-asset ETH design could not trip.
contract LendingPoolTest is Test {
    LendingPool internal pool;
    VNDStablecoin internal vnd;
    aToken internal atoken;
    StableDebtToken internal sdt;
    VariableDebtToken internal vdt;
    InterestRateModel internal irm;
    MockPriceOracle internal oracle;
    ProtocolFeeVault internal vault;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant START_PRICE = 70_000_000e18; // 70,000,000 VND / ETH, scaled 1e18
    uint256 internal constant LEND = 1_000_000_000e18; // 1,000,000,000 VND of lender liquidity
    uint256 internal constant BORROW = 30_000_000e18; //    30,000,000 VND borrowed
    uint256 internal constant COLLAT = 1 ether; // collateral worth 70,000,000 VND (~233% of debt)

    function setUp() public {
        vnd = new VNDStablecoin(address(this)); // this test contract is the owner/minter
        oracle = new MockPriceOracle(START_PRICE);
        atoken = new aToken(address(this));
        sdt = new StableDebtToken(address(this));
        vdt = new VariableDebtToken(address(this));
        irm = new InterestRateModel();
        vault = new ProtocolFeeVault(address(vnd));

        pool = new LendingPool(
            address(vnd), address(oracle), address(atoken), address(sdt), address(vdt), address(irm), address(vault)
        );

        atoken.setPool(address(pool));
        sdt.setPool(address(pool));
        vdt.setPool(address(pool));
    }

    // --- helpers ---------------------------------------------------------

    function _giveVnd(address to, uint256 amount) internal {
        vnd.mint(to, amount);
    }

    function _depositAsLender(uint256 amount) internal {
        _giveVnd(lender, amount);
        vm.startPrank(lender);
        vnd.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _borrowVariable(uint256 amount, uint256 collateral, uint256 daysDur) internal {
        vm.deal(borrower, collateral);
        vm.prank(borrower);
        pool.borrow{value: collateral}(amount, LoanManager.RateMode.Variable, daysDur);
    }

    // --- VND stablecoin --------------------------------------------------

    function test_Faucet_MintsVnd() public {
        vm.prank(borrower);
        vnd.faucet();
        assertEq(vnd.balanceOf(borrower), vnd.FAUCET_AMOUNT(), "faucet mints the fixed amount");
    }

    function test_OnlyOwner_CanMintVnd() public {
        vm.prank(borrower); // not the owner
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        vnd.mint(borrower, 1e18);
    }

    // --- lender side -----------------------------------------------------

    function test_Deposit_MintsAToken() public {
        _depositAsLender(LEND);
        assertEq(atoken.balanceOf(lender), LEND, "aToken minted 1:1 at start");
        assertEq(vnd.balanceOf(address(pool)), LEND, "pool holds the VNDD");
    }

    function test_Deposit_RequiresApproval() public {
        _giveVnd(lender, LEND);
        vm.prank(lender); // no approve()
        vm.expectRevert(); // OZ ERC20: ERC20InsufficientAllowance
        pool.deposit(LEND);
    }

    function test_Withdraw_ReturnsVnd() public {
        _depositAsLender(LEND);
        vm.prank(lender);
        pool.withdraw(LEND);
        assertEq(vnd.balanceOf(lender), LEND, "lender got VNDD back");
        assertEq(atoken.balanceOf(lender), 0, "aToken burned");
    }

    // --- borrower side ---------------------------------------------------

    function test_Borrow_Variable_MintsDebtAndSendsVnd() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30);

        assertEq(vdt.balanceOf(borrower), BORROW, "variable debt token minted");
        assertEq(pool.getLoanCount(borrower), 1, "one loan recorded");
        assertEq(pool.totalOutstandingDebt(), BORROW, "pool-wide debt tracked");
        assertEq(vnd.balanceOf(borrower), BORROW, "borrower received the borrowed VNDD");
        assertEq(address(pool).balance, COLLAT, "pool holds the ETH collateral");
    }

    function test_Borrow_RevertsWhenCollateralTooLow() public {
        _depositAsLender(LEND);
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vm.expectRevert("Not enough collateral");
        pool.borrow{value: 0.1 ether}(BORROW, LoanManager.RateMode.Variable, 30); // 7M VND < 60M needed
    }

    function test_Borrow_RevertsOnBadDuration() public {
        _depositAsLender(LEND);
        vm.deal(borrower, COLLAT);
        vm.prank(borrower);
        vm.expectRevert("Loan duration must be 3-180 days");
        pool.borrow{value: COLLAT}(BORROW, LoanManager.RateMode.Variable, 1);
    }

    function test_Borrow_RevertsWhenNoLiquidity() public {
        // no lender deposit => pool has no VNDD to lend
        vm.deal(borrower, COLLAT);
        vm.prank(borrower);
        vm.expectRevert("No liquidity");
        pool.borrow{value: COLLAT}(BORROW, LoanManager.RateMode.Variable, 30);
    }

    // --- repay -----------------------------------------------------------

    function test_Repay_BurnsDebtAndCreditsYield() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30);

        vm.warp(block.timestamp + 15 days); // accrue some interest

        _giveVnd(borrower, 1_000_000e18); // top up so borrower can cover principal + interest
        uint256 indexBefore = atoken.getLiquidityIndex();

        vm.startPrank(borrower);
        vnd.approve(address(pool), type(uint256).max);
        pool.repayLoan(0);
        vm.stopPrank();

        (,,, bool isRepaid,,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isRepaid, "loan marked repaid");
        assertEq(vdt.balanceOf(borrower), 0, "debt token burned");
        assertEq(pool.totalOutstandingDebt(), 0, "pool debt cleared");
        assertGt(vault.getBalance(), 0, "protocol fee captured (in VNDD)");
        assertGt(atoken.getLiquidityIndex(), indexBefore, "lenders earned real yield via the index");
        assertEq(borrower.balance, COLLAT, "ETH collateral returned");
    }

    function test_Repay_ExactPull_NoOverpayment() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30);

        // Repay immediately => interest ~ 0, owed ~ principal. The pool pulls EXACTLY what is owed.
        vm.startPrank(borrower);
        vnd.approve(address(pool), type(uint256).max); // approve more than owed on purpose
        pool.repayLoan(0);
        vm.stopPrank();

        assertEq(vnd.balanceOf(borrower), 0, "only the principal was pulled (no overpayment)");
        assertEq(vnd.balanceOf(address(pool)), LEND, "pool liquidity restored to the seeded amount");
        assertEq(borrower.balance, COLLAT, "collateral returned");
    }

    // --- liquidation -----------------------------------------------------

    function test_Liquidate_WhenOverdue() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30); // healthy until overdue

        vm.warp(block.timestamp + 31 days); // now overdue

        _giveVnd(liquidator, BORROW);
        uint256 ethBefore = liquidator.balance;
        vm.startPrank(liquidator);
        vnd.approve(address(pool), BORROW);
        pool.liquidate(borrower, 0); // repay 30M VND, seize 1 ETH collateral
        vm.stopPrank();

        assertEq(liquidator.balance, ethBefore + COLLAT, "liquidator seized the ETH collateral");
        assertEq(vnd.balanceOf(liquidator), 0, "liquidator paid the VND principal");
        assertEq(vdt.balanceOf(borrower), 0, "borrower debt burned");
        assertEq(pool.totalOutstandingDebt(), 0, "pool debt cleared");
        (,,,, bool isLiquidated,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isLiquidated, "loan marked liquidated");
    }

    /// @notice The headline improvement over the ETH/ETH design: a price drop alone can make a loan
    ///         liquidatable, BEFORE it is overdue, because ETH collateral and VND debt no longer cancel.
    function test_Liquidate_WhenUnderCollateralizedByPriceDrop() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30); // 70M collateral vs 30M debt = 233%, healthy and not overdue

        // ETH crashes from 70,000,000 to 30,000,000 VND => collateral now 30M < 120% * 30M = 36M.
        oracle.setEthPrice(30_000_000e18);

        _giveVnd(liquidator, BORROW);
        vm.startPrank(liquidator);
        vnd.approve(address(pool), BORROW);
        pool.liquidate(borrower, 0); // succeeds via under-collateralization, not overdue
        vm.stopPrank();

        (,,,, bool isLiquidated,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isLiquidated, "under-collateralized loan was liquidated before its due date");
        assertEq(vdt.balanceOf(borrower), 0, "debt burned");
    }

    function test_Liquidate_RevertsWhenHealthy() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30); // 233% collateral, not overdue, price unchanged

        _giveVnd(liquidator, BORROW);
        vm.startPrank(liquidator);
        vnd.approve(address(pool), BORROW);
        vm.expectRevert("Not eligible for liquidation");
        pool.liquidate(borrower, 0);
        vm.stopPrank();
    }

    function test_Liquidate_RevertsWithoutVndApproval() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30);
        vm.warp(block.timestamp + 31 days); // eligible (overdue)

        _giveVnd(liquidator, BORROW);
        vm.prank(liquidator); // no approve()
        vm.expectRevert(); // OZ ERC20: ERC20InsufficientAllowance
        pool.liquidate(borrower, 0);
    }

    // --- interest rate model (pure math) --------------------------------

    function test_InterestRateModel_Curve() public view {
        assertEq(irm.getInterestRate(0, 0), 30e15, "base+fee at empty pool");
        assertEq(irm.getInterestRate(100 ether, 0), 30e15, "0% utilization");
        assertEq(irm.getInterestRate(100 ether, 80 ether), 60e15, "optimal utilization");
        assertEq(irm.getInterestRate(100 ether, 90 ether), 105e15, "above optimal");
    }

    // --- access control --------------------------------------------------

    function test_DebtToken_IsNonTransferable() public {
        _depositAsLender(LEND);
        _borrowVariable(BORROW, COLLAT, 30);

        vm.prank(borrower);
        vm.expectRevert("DebtToken: non-transferable");
        vdt.transfer(liquidator, 1);
    }

    function test_OnlyPool_CanMintDebt() public {
        vm.expectRevert("Only pool can mint");
        vdt.mint(borrower, 1 ether);
    }

    function test_OnlyPool_CanMintAToken() public {
        vm.expectRevert("Only pool can call");
        atoken.mint(lender, 1 ether);
    }

    function test_OnlyOwner_CanSetOraclePrice() public {
        vm.prank(borrower); // not the owner
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        oracle.setEthPrice(50_000_000e18);
    }

    function test_Owner_CanSetOraclePrice() public {
        oracle.setEthPrice(50_000_000e18); // test contract is the owner
        assertEq(oracle.getLatestEthPrice(), 50_000_000e18);
    }

    receive() external payable {}
}
