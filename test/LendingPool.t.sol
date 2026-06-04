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

/// @title LendingPool test suite
/// @notice Demonstrates the full lender/borrower/liquidator lifecycle with Foundry cheatcodes
///         (vm.deal, vm.prank, vm.warp, vm.expectRevert). Where the original contracts contain
///         bugs, the test asserts the ACTUAL behavior and the comment flags it as a known issue.
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

        // Wire the tokens so only the pool can mint/burn them
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
        // liquidityIndex starts at 1 RAY, so 1 ETH deposited == 1 aETH (scaled)
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
        // borrower posted 2 collateral, received 1 borrowed => net -1 from the 2 they funded
        assertEq(borrower.balance, 1 ether, "borrower received the borrowed ETH");
    }

    function test_Borrow_RevertsWhenCollateralTooLow() public {
        _depositAsLender(5 ether);
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vm.expectRevert("Not enough collateral in USD");
        pool.borrow{value: 1e14}(1 ether, LoanManager.RateMode.Variable, 30);
    }

    function test_Borrow_RevertsOnBadDuration() public {
        vm.deal(borrower, 5 ether);
        vm.prank(borrower);
        vm.expectRevert("Loan duration must be 3-180 days");
        pool.borrow{value: 2 ether}(1 ether, LoanManager.RateMode.Variable, 1);
    }

    /// @notice KNOWN BUG, documented as a passing test: repayLoan() can NEVER succeed.
    /// After splitting the interest, repayLoan does:
    ///     (bool ok2, ) = payable(address(this)).call{value: lenderInterest}("");
    ///     require(ok2, "Lender interest failed");
    /// It calls the pool *itself* with empty calldata. LendingPool defines no receive()/fallback(),
    /// so that call returns false and the entire repayment reverts. Consequence: no borrower can
    /// ever repay or recover their collateral. Fix: drop the self-call (the ETH is already in the
    /// pool from msg.value), or add `receive() external payable {}` to LendingPool.
    function test_Repay_RevertsDueToSelfCallBug() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

        // let ~15 days of interest accrue
        vm.warp(block.timestamp + 15 days);

        vm.deal(borrower, 2 ether); // top up so borrower can cover principal + interest
        vm.prank(borrower);
        vm.expectRevert("Lender interest failed");
        pool.repayLoan{value: 1.01 ether}(0);
    }

    // --- liquidation -----------------------------------------------------

    function test_Liquidate_WhenOverdue() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30); // healthy collateral (2x)

        vm.warp(block.timestamp + 31 days); // now overdue

        uint256 before = liquidator.balance;
        vm.prank(liquidator);
        pool.liquidate(borrower, 0);

        assertEq(liquidator.balance, before + 2 ether, "liquidator seized collateral");
        (,,,, bool isLiquidated,,,) = pool.getUserLoan(borrower, 0);
        assertTrue(isLiquidated, "loan marked liquidated");
    }

    function test_Liquidate_WhenUnderCollateralized() public {
        _depositAsLender(5 ether);
        // collateral == borrowed => below the 120% threshold immediately
        _borrowVariable(1 ether, 1 ether, 30);

        uint256 before = liquidator.balance;
        vm.prank(liquidator);
        pool.liquidate(borrower, 0); // not overdue, but under-collateralized

        assertEq(liquidator.balance, before + 1 ether, "liquidator seized collateral");
    }

    function test_Liquidate_RevertsWhenHealthy() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30); // 2x collateral, not overdue

        vm.prank(liquidator);
        vm.expectRevert("Not eligible for liquidation");
        pool.liquidate(borrower, 0);
    }

    // --- interest rate model (pure math) --------------------------------

    function test_InterestRateModel_Curve() public view {
        // zero liquidity => base + protocol fee
        assertEq(irm.getInterestRate(0, 0), 30e15, "base+fee at empty pool");
        // 0% utilization => base + fee = 2.5% + 0.5% = 3%
        assertEq(irm.getInterestRate(100 ether, 0), 30e15, "0% utilization");
        // 80% (optimal) => base + slope1 + fee = 2.5% + 3% + 0.5% = 6%
        assertEq(irm.getInterestRate(100 ether, 80 ether), 60e15, "optimal utilization");
        // 90% (above optimal) => base + slope1 + half of slope2 + fee = 10.5%
        assertEq(irm.getInterestRate(100 ether, 90 ether), 105e15, "above optimal");
    }

    // --- token access control -------------------------------------------

    function test_DebtToken_IsNonTransferable() public {
        _depositAsLender(5 ether);
        _borrowVariable(1 ether, 2 ether, 30);

        vm.prank(borrower);
        vm.expectRevert("DebtToken: non-transferable");
        vdt.transfer(liquidator, 1);
    }

    function test_OnlyPool_CanMintDebt() public {
        vm.expectRevert("Only pool can mint");
        vdt.mint(borrower, 1 ether); // called by the test contract, not the pool
    }

    function test_OnlyPool_CanMintAToken() public {
        vm.expectRevert("Only pool can call");
        atoken.mint(lender, 1 ether);
    }

    receive() external payable {}
}
