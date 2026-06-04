// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LoanManager.sol";
import "./Utils.sol";
import "./MockPriceOracle.sol";
import "./VNDStablecoin.sol";
import "./aToken.sol";
import "./StableDebtToken.sol";
import "./VariableDebtToken.sol";
import "./InterestRateModel.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LendingPool - core of the P2P over-collateralized lending protocol
/// @notice The **loan asset is VNDD** (a VND-pegged stablecoin): lenders supply VNDD and earn yield,
///         borrowers lock ETH collateral and borrow VNDD, and everyone repays/liquidates in VNDD.
///         ETH is collateral only — it is never lent out.
/// @dev Fixes carried over from the ETH version (see README "What was fixed"):
///   #1 repayLoan no longer calls itself; lender interest stays in the pool (as VNDD).
///   #2 liquidate() requires the liquidator to repay the debt and burns the debt token.
///   #3 utilization uses a pool-wide `totalBorrowed` instead of only msg.sender's loans.
///   #4 repaid interest is credited to lenders through aToken.accrueToLenders (real yield).
///   #6 the collateral check values ETH collateral in VND against VND debt (the price no longer
///      cancels, so under-collateralization is a reachable liquidation trigger).
///   #7 ETH collateral sends use .call + success check; ERC20 moves check their return value;
///      state-changing entrypoints are nonReentrant and follow checks-effects-interactions.
contract LendingPool is LoanManager, ReentrancyGuard {
    VNDStablecoin public vnd;
    MockPriceOracle public oracle;
    aToken public atoken;
    StableDebtToken public stableDebtToken;
    VariableDebtToken public variableDebtToken;
    InterestRateModel public interestModel;
    address public protocolFeeVault;

    /// @notice Pool-wide outstanding VNDD principal (fix #3)
    uint256 public totalBorrowed;

    uint256 public constant COLLATERAL_RATIO = 200; // 200% over-collateralization
    uint256 public constant FIXED_INTEREST = 6e16; // 6% annual (stable rate)
    uint256 public constant PROTOCOL_FEE = 5e15; // 0.5% of interest
    uint256 public constant LATE_PENALTY_PER_DAY = 2e16; // 2% per day
    uint256 public constant LATE_PENALTY_TO_PROTOCOL = 75; // 75% of the penalty
    uint256 public constant LATE_PENALTY_TO_LENDER = 25; // 25% of the penalty

    event Deposit(address indexed lender, uint256 vndAmount);
    event Withdraw(address indexed lender, uint256 scaledAmount, uint256 vndAmount);
    event Borrow(address indexed borrower, uint256 indexed loanIndex, uint256 vndAmount, RateMode rateMode);
    event Repay(address indexed borrower, uint256 indexed loanIndex, uint256 vndPaid);
    event LoanLiquidated(
        address indexed borrower,
        uint256 indexed loanIndex,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 debtRepaid
    );

    constructor(
        address _vnd,
        address _oracle,
        address _atoken,
        address _stableDebtToken,
        address _variableDebtToken,
        address _interestModel,
        address _protocolFeeVault
    ) {
        vnd = VNDStablecoin(_vnd);
        oracle = MockPriceOracle(_oracle);
        atoken = aToken(_atoken);
        stableDebtToken = StableDebtToken(_stableDebtToken);
        variableDebtToken = VariableDebtToken(_variableDebtToken);
        interestModel = InterestRateModel(_interestModel);
        protocolFeeVault = _protocolFeeVault;
    }

    /// @notice VNDD currently sitting in the pool, available to borrow or withdraw.
    function availableLiquidity() public view returns (uint256) {
        return vnd.balanceOf(address(this));
    }

    // ---------------------
    // LENDER SIDE
    // ---------------------

    /// @notice Supply VNDD to the pool (requires a prior `vnd.approve(pool, amount)`).
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        atoken.mint(msg.sender, amount); // effects (scaled mint) before the external pull
        require(vnd.transferFrom(msg.sender, address(this), amount), "VND transfer failed");
        emit Deposit(msg.sender, amount);
    }

    /// @param _amount amount of (scaled) aToken to redeem
    function withdraw(uint256 _amount) external nonReentrant {
        require(atoken.balanceOf(msg.sender) >= _amount, "Not enough aToken");

        uint256 liquidityIndex = atoken.getLiquidityIndex();
        uint256 vndAmount = (_amount * liquidityIndex) / 1e27;
        require(availableLiquidity() >= vndAmount, "Insufficient pool liquidity");

        atoken.burn(msg.sender, _amount); // effects before interaction

        require(vnd.transfer(msg.sender, vndAmount), "VND transfer failed");
        emit Withdraw(msg.sender, _amount, vndAmount);
    }

    // ---------------------
    // BORROWER SIDE
    // ---------------------

    /// @notice Borrow VNDD against ETH collateral. Send the ETH collateral as msg.value.
    /// @param _amount VNDD to borrow (1e18-scaled)
    function borrow(uint256 _amount, RateMode _rateMode, uint256 _days) external payable nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(_days >= 3 && _days <= 180, "Loan duration must be 3-180 days");
        require(availableLiquidity() >= _amount, "No liquidity");

        // FIX #6: value the ETH collateral in VND and compare against the VND debt. The two assets
        // differ now, so the ETH→VND price genuinely matters (it no longer cancels).
        uint256 ethPriceVnd = oracle.getLatestEthPrice();
        uint256 collateralVnd = (msg.value * ethPriceVnd) / 1e18;
        require(collateralVnd * 100 >= _amount * COLLATERAL_RATIO, "Not enough collateral");

        // FIX #3: pool-wide debt drives the variable rate, not just the caller's loans.
        uint256 interestRate = _rateMode == RateMode.Stable
            ? FIXED_INTEREST
            : interestModel.getInterestRate(availableLiquidity(), totalBorrowed);

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

        require(vnd.transfer(msg.sender, _amount), "VND transfer failed");
        emit Borrow(msg.sender, loanIndex, _amount, _rateMode);
    }

    /// @notice Repay a loan in VNDD (requires a prior `vnd.approve(pool, totalOwed)`), get ETH back.
    function repayLoan(uint256 index) external nonReentrant {
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

        // --- interactions ---
        // Pull the full amount owed in VNDD. Principal + lenderShare stay in the pool; the protocol
        // cut is forwarded to the vault. No overpayment/refund path is needed — we pull the exact sum.
        require(vnd.transferFrom(msg.sender, address(this), totalOwed), "VND transfer failed");

        // FIX #1/#4: lenders' share is credited to the liquidity index (real yield); the VNDD itself
        // stays in the pool, redeemable on withdraw. Principal also replenishes pool liquidity.
        atoken.accrueToLenders(lenderShare);

        if (protocolCut > 0) {
            require(vnd.transfer(protocolFeeVault, protocolCut), "Fee transfer failed");
        }

        // Return the ETH collateral to the borrower.
        (bool okCol,) = payable(msg.sender).call{value: collateral}("");
        require(okCol, "Collateral transfer failed");

        emit Repay(msg.sender, index, totalOwed);
    }

    // ---------------------
    // LIQUIDATION
    // ---------------------

    /// @notice Liquidate an overdue or under-collateralized loan. FIX #2: the liquidator repays the
    ///         outstanding VNDD principal and in return seizes the ETH collateral (profit = collateral
    ///         value − principal). The debt token is burned and the principal replenishes pool VNDD.
    /// @dev With ETH collateral and VND debt, `isUnderCollateralized` is now price-sensitive: a large
    ///      enough drop in the ETH/VND price makes a once-healthy loan liquidatable even before it is
    ///      overdue. (Requires a prior `vnd.approve(pool, principal)`.)
    function liquidate(address borrower, uint256 index) external nonReentrant {
        Loan storage loan = userLoans[borrower][index];
        require(!loan.isRepaid, "Already repaid");
        require(!loan.isLiquidated, "Already liquidated");

        uint256 ethPriceVnd = oracle.getLatestEthPrice();
        bool overdue = Utils.isOverdue(loan.dueDate);
        bool underCollateralized = Utils.isUnderCollateralized(loan.collateralAmount, loan.amountBorrowed, ethPriceVnd);
        require(overdue || underCollateralized, "Not eligible for liquidation");

        uint256 principal = loan.amountBorrowed;

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
        // Liquidator repays the debt in VNDD, then seizes the ETH collateral.
        require(vnd.transferFrom(msg.sender, address(this), principal), "VND transfer failed");

        (bool sent,) = payable(msg.sender).call{value: collateral}("");
        require(sent, "Collateral transfer failed");

        emit LoanLiquidated(borrower, index, msg.sender, collateral, principal);
    }

    // ---------------------
    // VIEWS
    // ---------------------

    function getLoanCount(address user) external view returns (uint256) {
        return userLoans[user].length;
    }

    /// @notice Pool-wide outstanding VNDD principal (fix #3: was per-caller and wrong before)
    function totalOutstandingDebt() external view returns (uint256) {
        return totalBorrowed;
    }
}
