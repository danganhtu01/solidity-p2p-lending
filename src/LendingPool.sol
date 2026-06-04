// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LoanManager.sol";
import "./Utils.sol";
import "./MockPriceOracle.sol";
import "./aToken.sol";
import "./StableDebtToken.sol";
import "./VariableDebtToken.sol";
import "./InterestRateModel.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LendingPool - core of the P2P over-collateralized ETH lending protocol
/// @notice Fixes applied vs the original (see README "Known issues"):
///   #1 repayLoan no longer calls itself (which always reverted); lender interest stays in the pool.
///   #2 liquidate() now requires the liquidator to repay the debt and burns the debt token.
///   #3 utilization uses a pool-wide `totalBorrowed` instead of only msg.sender's loans.
///   #4 repaid interest is credited to lenders through aToken.accrueToLenders (real yield).
///   #6 the collateral check is unit-consistent (USD vs USD).
///   #7 all ETH sends use .call + success check; state-changing entrypoints are nonReentrant (CEI).
contract LendingPool is LoanManager, ReentrancyGuard {
    MockPriceOracle public oracle;
    aToken public atoken;
    StableDebtToken public stableDebtToken;
    VariableDebtToken public variableDebtToken;
    InterestRateModel public interestModel;
    address payable public protocolFeeVault;

    /// @notice Pool-wide outstanding principal (fix #3)
    uint256 public totalBorrowed;

    uint256 public constant COLLATERAL_RATIO = 200; // 200% over-collateralization
    uint256 public constant FIXED_INTEREST = 6e16; // 6% annual (stable rate)
    uint256 public constant PROTOCOL_FEE = 5e15; // 0.5% of interest
    uint256 public constant LATE_PENALTY_PER_DAY = 2e16; // 2% per day
    uint256 public constant LATE_PENALTY_TO_PROTOCOL = 75; // 75% of the penalty
    uint256 public constant LATE_PENALTY_TO_LENDER = 25; // 25% of the penalty

    event Deposit(address indexed lender, uint256 amount);
    event Withdraw(address indexed lender, uint256 scaledAmount, uint256 ethAmount);
    event Borrow(address indexed borrower, uint256 indexed loanIndex, uint256 amount, RateMode rateMode);
    event Repay(address indexed borrower, uint256 indexed loanIndex, uint256 amountPaid);
    event LoanLiquidated(
        address indexed borrower,
        uint256 indexed loanIndex,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 debtRepaid
    );

    constructor(
        address _oracle,
        address _atoken,
        address _stableDebtToken,
        address _variableDebtToken,
        address _interestModel,
        address payable _protocolFeeVault
    ) {
        oracle = MockPriceOracle(_oracle);
        atoken = aToken(_atoken);
        stableDebtToken = StableDebtToken(_stableDebtToken);
        variableDebtToken = VariableDebtToken(_variableDebtToken);
        interestModel = InterestRateModel(_interestModel);
        protocolFeeVault = _protocolFeeVault;
    }

    // ---------------------
    // LENDER SIDE
    // ---------------------

    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Amount must be > 0");
        atoken.mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @param _amount amount of (scaled) aToken to redeem
    function withdraw(uint256 _amount) external nonReentrant {
        require(atoken.balanceOf(msg.sender) >= _amount, "Not enough aToken");

        uint256 liquidityIndex = atoken.getLiquidityIndex();
        uint256 ethAmount = (_amount * liquidityIndex) / 1e27;
        require(address(this).balance >= ethAmount, "Insufficient pool liquidity");

        atoken.burn(msg.sender, _amount); // effects before interaction

        (bool sent,) = payable(msg.sender).call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
        emit Withdraw(msg.sender, _amount, ethAmount);
    }

    // ---------------------
    // BORROWER SIDE
    // ---------------------

    function borrow(uint256 _amount, RateMode _rateMode, uint256 _days) external payable nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(_days >= 3 && _days <= 180, "Loan duration must be 3-180 days");
        require(address(this).balance >= _amount, "No liquidity");

        // FIX #6: compare like units (USD value vs USD value). Both collateral and debt are ETH, so
        // the price cancels here; it would only matter for a multi-asset market.
        uint256 ethPrice = oracle.getLatestEthPrice();
        uint256 collateralUSD = (msg.value * ethPrice) / 1e18;
        uint256 borrowedUSD = (_amount * ethPrice) / 1e18;
        require(collateralUSD * 100 >= borrowedUSD * COLLATERAL_RATIO, "Not enough collateral");

        // FIX #3: pool-wide debt drives the variable rate, not just the caller's loans.
        uint256 interestRate = _rateMode == RateMode.Stable
            ? FIXED_INTEREST
            : interestModel.getInterestRate(address(this).balance, totalBorrowed);

        userLoans[msg.sender].push(
            Loan({
                amountBorrowed: _amount,
                collateralAmount: msg.value,
                dueDate: block.timestamp + (_days * 1 days),
                isRepaid: false,
                isLiquidated: false,
                interestRate: interestRate,
                rateMode: _rateMode,
                durationDays: _days
            })
        );
        uint256 loanIndex = userLoans[msg.sender].length - 1;
        totalBorrowed += _amount;

        if (_rateMode == RateMode.Stable) {
            stableDebtToken.mint(msg.sender, _amount);
        } else {
            variableDebtToken.mint(msg.sender, _amount);
        }

        (bool sent,) = payable(msg.sender).call{value: _amount}("");
        require(sent, "ETH transfer failed");
        emit Borrow(msg.sender, loanIndex, _amount, _rateMode);
    }

    function repayLoan(uint256 index) external payable nonReentrant {
        Loan storage loan = userLoans[msg.sender][index];
        require(!loan.isRepaid, "Already repaid");
        require(!loan.isLiquidated, "Loan was liquidated");

        uint256 principal = loan.amountBorrowed;
        uint256 startTime = loan.dueDate - (loan.durationDays * 1 days);
        uint256 baseDuration = loan.durationDays * 1 days;
        uint256 actualDuration = block.timestamp > loan.dueDate ? baseDuration : block.timestamp - startTime;

        uint256 interest = (principal * loan.interestRate * actualDuration) / (365 days * 1e18);
        uint256 totalOwed = principal + interest;

        uint256 penalty = 0;
        if (block.timestamp > loan.dueDate) {
            uint256 daysLate = (block.timestamp - loan.dueDate) / 1 days;
            penalty = (principal * LATE_PENALTY_PER_DAY * daysLate) / 1e18;
            totalOwed += penalty;
        }

        require(msg.value >= totalOwed, "Insufficient repay");

        // --- effects (CEI) ---
        loan.isRepaid = true;
        totalBorrowed -= principal;
        uint256 collateral = loan.collateralAmount;
        loan.collateralAmount = 0;

        if (loan.rateMode == RateMode.Stable) {
            stableDebtToken.burn(msg.sender, principal);
        } else {
            variableDebtToken.burn(msg.sender, principal);
        }

        // Split interest + late penalty between protocol and lenders
        uint256 protocolCut = (interest * PROTOCOL_FEE) / 1e18;
        uint256 lenderShare = interest - protocolCut;
        if (penalty > 0) {
            uint256 protocolPenalty = (penalty * LATE_PENALTY_TO_PROTOCOL) / 100;
            protocolCut += protocolPenalty;
            lenderShare += penalty - protocolPenalty;
        }

        // FIX #1/#4: no self-call. Lenders' share stays in the pool as ETH and is credited to the
        // liquidity index, so it is redeemable on withdraw (real yield). Principal also stays.
        atoken.accrueToLenders(lenderShare);

        // --- interactions ---
        if (protocolCut > 0) {
            (bool okFee,) = protocolFeeVault.call{value: protocolCut}("");
            require(okFee, "Fee transfer failed");
        }
        (bool okCol,) = payable(msg.sender).call{value: collateral}("");
        require(okCol, "Collateral transfer failed");

        uint256 refund = msg.value - totalOwed;
        if (refund > 0) {
            (bool okRef,) = payable(msg.sender).call{value: refund}("");
            require(okRef, "Refund failed");
        }

        emit Repay(msg.sender, index, totalOwed);
    }

    // ---------------------
    // LIQUIDATION
    // ---------------------

    /// @notice Liquidate an overdue or under-collateralized loan. FIX #2: the liquidator must repay
    ///         the outstanding principal and in return seizes the collateral (profit = collateral -
    ///         principal). The debt token is burned and the principal replenishes pool liquidity.
    /// @dev Because collateral and debt are both ETH, `isUnderCollateralized` is price-invariant and
    ///      can't trip for a 200%-collateralized loan — in this single-asset design "overdue" is the
    ///      operative trigger. The check is kept for the multi-asset generalization.
    function liquidate(address borrower, uint256 index) external payable nonReentrant {
        Loan storage loan = userLoans[borrower][index];
        require(!loan.isRepaid, "Already repaid");
        require(!loan.isLiquidated, "Already liquidated");

        uint256 ethPrice = oracle.getLatestEthPrice();
        bool overdue = Utils.isOverdue(loan.dueDate);
        bool underCollateralized = Utils.isUnderCollateralized(loan.collateralAmount, loan.amountBorrowed, ethPrice);
        require(overdue || underCollateralized, "Not eligible for liquidation");

        uint256 principal = loan.amountBorrowed;
        require(msg.value >= principal, "Must repay debt to liquidate");

        // --- effects (CEI) ---
        loan.isRepaid = true;
        loan.isLiquidated = true;
        totalBorrowed -= principal;
        uint256 collateral = loan.collateralAmount;
        loan.collateralAmount = 0;

        if (loan.rateMode == RateMode.Stable) {
            stableDebtToken.burn(borrower, principal);
        } else {
            variableDebtToken.burn(borrower, principal);
        }

        // --- interactions ---
        (bool sent,) = payable(msg.sender).call{value: collateral}("");
        require(sent, "Collateral transfer failed");

        uint256 refund = msg.value - principal;
        if (refund > 0) {
            (bool okRef,) = payable(msg.sender).call{value: refund}("");
            require(okRef, "Refund failed");
        }

        emit LoanLiquidated(borrower, index, msg.sender, collateral, principal);
    }

    // ---------------------
    // VIEWS
    // ---------------------

    function getLoanCount(address user) external view returns (uint256) {
        return userLoans[user].length;
    }

    /// @notice Pool-wide outstanding principal (fix #3: was per-caller and wrong before)
    function totalOutstandingDebt() external view returns (uint256) {
        return totalBorrowed;
    }
}
