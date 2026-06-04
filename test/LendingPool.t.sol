// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {aToken} from "../src/aToken.sol";
import {StableDebtToken} from "../src/StableDebtToken.sol";
import {VariableDebtToken} from "../src/VariableDebtToken.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

/// @title LendingPool test suite (post-fix)
/// @notice Covers the full lifecycle now that the known bugs are fixed: repay works and credits
///         lender yield, liquidation requires repaying the debt, and setters are access-controlled.
contract LendingPoolTest is Test {
    LendingPool internal pool;
    aToken internal atoken;
    StableDebtToken internal sdt;
    VariableDebtToken internal vdt;
    InterestRateModel internal irm;
    MockPriceOracle internal oracle;
    ProtocolFeeVault internal vault;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant START_PRICE = 2000e18; // $2000 / ETH, scaled 1e18

    function setUp() public {
        oracle = new MockPriceOracle(START_PRICE);
        atoken = new aToken(address(this)); // this test contract is the owner
        sdt = new StableDebtToken(address(this));
        vdt = new VariableDebtToken(address(this));
        irm = new InterestRateModel();
        vault = new ProtocolFeeVault();

        pool = new LendingPool(
            address(oracle), address(atoken), address(sdt), address(vdt), address(irm), payable(address(vault))
        );

        atoken.setPool(address(pool));
        sdt.setPool(address(pool));
        vdt.setPool(address(pool));
    }

    // --- helpers ---------------------------------------------------------

    function _depositAsLender(uint256 amount) internal {
        vm.deal(lender, amount);
        vm.prank(lender);
        pool.deposit{value: amount}();
    }

    function _borrowVariable(uint256 amount, uint256 collateral, uint256 daysDur) internal {
        vm.deal(borrower, collateral);
        vm.prank(borrower);
        pool.borrow{value: collateral}(amount, LoanManager.RateMode.Variable, daysDur);
    }

    // --- lender side -----------------------------------------------------

    function test_Deposit_MintsAToken() public {
        _depositAsLender(5 ether);
        assertEq(atoken.balanceOf(lender), 5 ether, "aToken minted 1:1 at start");
        assertEq(address(pool).balance, 5 ether, "pool holds the ETH");
    }

    function test_Withdraw_ReturnsEth() public {
        _depositAsLender(5 ether);
        vm.prank(lender);
        pool.withdraw(5 ether);
        assertEq(lender.balance, 5 ether, "lender got ETH back");
        assertEq(atoken.balanceOf(lender), 0, "aToken burned");
    }

    // --- borrower side ---------------------------------------------------

    function test_Borrow_Variable_MintsDebtAndSendsEth() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

        assertEq(vdt.balanceOf(borrower), 1 ether, "variable debt token minted");
        assertEq(pool.getLoanCount(borrower), 1, "one loan recorded");
        assertEq(pool.totalOutstandingDebt(), 1 ether, "pool-wide debt tracked");
        assertEq(borrower.balance, 1 ether, "borrower received the borrowed ETH");
    }

    function test_Borrow_RevertsWhenCollateralTooLow() public {
        _depositAsLender(5 ether);
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vm.expectRevert("Not enough collateral");
        pool.borrow{value: 1e14}(1 ether, LoanManager.RateMode.Variable, 30); // far below 200%
    }

    function test_Borrow_RevertsOnBadDuration() public {
        vm.deal(borrower, 5 ether);
        vm.prank(borrower);
        vm.expectRevert("Loan duration must be 3-180 days");
        pool.borrow{value: 2 ether}(1 ether, LoanManager.RateMode.Variable, 1);
    }

    // --- repay (FIXED: was always reverting) ----------------------------

    function test_Repay_BurnsDebtAndReturnsCollateral() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

        vm.warp(block.timestamp + 15 days); // accrue some interest

        vm.deal(borrower, 2 ether); // top up to cover principal + interest
        uint256 indexBefore = atoken.getLiquidityIndex();

        vm.prank(borrower);
        pool.repayLoan{value: 1.05 ether}(0);

        (,,, bool isRepaid,,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isRepaid, "loan marked repaid");
        assertEq(vdt.balanceOf(borrower), 0, "debt token burned");
        assertEq(pool.totalOutstandingDebt(), 0, "pool debt cleared");
        assertGt(vault.getBalance(), 0, "protocol fee captured");
        assertGt(atoken.getLiquidityIndex(), indexBefore, "lenders earned real yield via the index");
    }

    function test_Repay_RefundsOverpayment() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

        // repay immediately => interest ~ 0, owed ~ 1 ETH principal
        vm.deal(borrower, 5 ether);
        vm.prank(borrower);
        pool.repayLoan{value: 3 ether}(0); // big overpay

        // principal (1) stays in the pool; collateral (2) + overpayment (2) come back => 5 - 3 + 2 + 2 = 6
        assertEq(borrower.balance, 6 ether, "overpayment refunded, only principal retained");
    }

    // --- liquidation (FIXED: liquidator must repay the debt) -------------

    function test_Liquidate_WhenOverdue() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30); // 2x collateral, healthy until overdue

        vm.warp(block.timestamp + 31 days); // now overdue

        vm.deal(liquidator, 1 ether);
        uint256 before = liquidator.balance;
        vm.prank(liquidator);
        pool.liquidate{value: 1 ether}(borrower, 0); // repay 1 principal, seize 2 collateral

        assertEq(liquidator.balance, before + 1 ether, "profit = collateral(2) - principal(1)");
        assertEq(vdt.balanceOf(borrower), 0, "borrower debt burned");
        assertEq(pool.totalOutstandingDebt(), 0, "pool debt cleared");
        (,,,, bool isLiquidated,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isLiquidated, "loan marked liquidated");
    }

    function test_Liquidate_RevertsWithoutRepayingDebt() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);
        vm.warp(block.timestamp + 31 days);

        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        vm.expectRevert("Must repay debt to liquidate");
        pool.liquidate{value: 0.5 ether}(borrower, 0); // less than the 1 ETH principal
    }

    function test_Liquidate_RevertsWhenHealthy() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30); // 2x collateral, not overdue

        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        vm.expectRevert("Not eligible for liquidation");
        pool.liquidate{value: 1 ether}(borrower, 0);
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
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

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
        oracle.setEthPrice(1500e18);
    }

    function test_Owner_CanSetOraclePrice() public {
        oracle.setEthPrice(1500e18); // test contract is the owner
        assertEq(oracle.getLatestEthPrice(), 1500e18);
    }

    receive() external payable {}
}
