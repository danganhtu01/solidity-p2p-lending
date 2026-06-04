// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LoanManager.sol";
import "./Utils.sol";
import "./MockPriceOracle.sol";  // Thay Chainlink bằng Mock
import "./aToken.sol";
import "./StableDebtToken.sol";
import "./VariableDebtToken.sol";
import "./CollateralManager.sol";
import "./InterestRateModel.sol";
import "./ProtocolFeeVault.sol";

contract LendingPool is LoanManager {
    MockPriceOracle public oracle;  // Thay ChainlinkPriceOracle bằng MockPriceOracle
    aToken public atoken;
    StableDebtToken public stableDebtToken;
    VariableDebtToken public variableDebtToken;
    InterestRateModel public interestModel;
    address payable public protocolFeeVault;

    uint256 public constant COLLATERAL_RATIO = 200;
    uint256 public constant FIXED_INTEREST = 6e16; // 6% annual
    uint256 public constant PROTOCOL_FEE = 5e15;   // 0.5%
    uint256 public constant LATE_PENALTY_PER_DAY = 2e16; // 2% per day
    uint256 public constant LATE_PENALTY_TO_PROTOCOL = 75; // 75% of 2%
    uint256 public constant LATE_PENALTY_TO_LENDER = 25;   // 25% of 2%

    event LoanLiquidated(address indexed borrower, uint256 indexed loanIndex, address indexed liquidator, uint256 collateralSeized);

    constructor(
        address _oracle,
        address _atoken,
        address _stableDebtToken,
        address _variableDebtToken,
        address _interestModel,
        address payable _protocolFeeVault
    ) {
        oracle = MockPriceOracle(_oracle);  // Dùng MockPriceOracle
        atoken = aToken(_atoken);
        stableDebtToken = StableDebtToken(_stableDebtToken);
        variableDebtToken = VariableDebtToken(_variableDebtToken);
        interestModel = InterestRateModel(_interestModel);
        protocolFeeVault = _protocolFeeVault;
    }



    // ---------------------
    // ✅ LENDER SIDE
    // ---------------------

    function deposit() external payable {
        require(msg.value > 0, "Amount must be > 0");
        atoken.mint(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external {
        require(atoken.balanceOf(msg.sender) >= _amount, "Not enough aToken");
        atoken.burn(msg.sender, _amount);

        uint256 liquidityIndex = atoken.getLiquidityIndex();
        uint256 ethAmount = (_amount * liquidityIndex) / 1e27;

        payable(msg.sender).transfer(ethAmount);
    }

    // ---------------------
    // ✅ BORROWER SIDE
    // ---------------------

    function borrow(uint256 _amount, RateMode _rateMode, uint256 _days) external payable {
        require(_amount > 0, "Invalid amount");
        require(_days >= 3 && _days <= 180, "Loan duration must be 3-180 days");

        uint256 ethPrice = oracle.getLatestEthPrice();
        require(
            (msg.value * ethPrice) / 1e18 >= (_amount * COLLATERAL_RATIO) / 100,
            "Not enough collateral in USD"
        );
        require(address(this).balance >= _amount, "No liquidity");

        uint256 interestRate = _rateMode == RateMode.Stable
            ? FIXED_INTEREST
            : interestModel.getInterestRate(address(this).balance, totalOutstandingDebt());

        Loan memory newLoan = Loan({
            amountBorrowed: _amount,
            collateralAmount: msg.value,
            dueDate: block.timestamp + (_days * 1 days),
            isRepaid: false,
            isLiquidated: false, // ✅ thêm dòng này để khớp struct mới
            interestRate: interestRate,
            rateMode: _rateMode,
            durationDays: _days
        });

        userLoans[msg.sender].push(newLoan);

        if (_rateMode == RateMode.Stable) {
            stableDebtToken.mint(msg.sender, _amount);
        } else {
            variableDebtToken.mint(msg.sender, _amount);
        }

        payable(msg.sender).transfer(_amount);
    }

    function repayLoan(uint256 index) external payable {
        Loan storage loan = userLoans[msg.sender][index];
        require(!loan.isRepaid, "Already repaid");
        require(!loan.isLiquidated, "Loan was liquidated");

        uint256 startTime = loan.dueDate - (loan.durationDays * 1 days);
        uint256 baseDuration = loan.durationDays * 1 days;
        uint256 actualDuration = block.timestamp > loan.dueDate
            ? baseDuration
            : block.timestamp - startTime;

        uint256 interest = (loan.amountBorrowed * loan.interestRate * actualDuration) / (365 days * 1e18);
        uint256 totalOwed = loan.amountBorrowed + interest;

        // ✅ Tính phí phạt nếu trễ hạn
        uint256 penalty = 0;
        if (block.timestamp > loan.dueDate) {
            uint256 daysLate = (block.timestamp - loan.dueDate) / 1 days;
            penalty = (loan.amountBorrowed * LATE_PENALTY_PER_DAY * daysLate) / 1e18;
            totalOwed += penalty;
        }

        require(msg.value >= totalOwed, "Insufficient repay");
        loan.isRepaid = true;

        // Burn Debt Token
        if (loan.rateMode == RateMode.Stable) {
            stableDebtToken.burn(msg.sender, loan.amountBorrowed);
        } else {
            variableDebtToken.burn(msg.sender, loan.amountBorrowed);
        }

        // ✅ Chia phần interest
        uint256 protocolFee = (interest * PROTOCOL_FEE) / 1e18;
        uint256 lenderInterest = interest - protocolFee;

        // ✅ Gửi lãi cho protocol
        (bool ok1, ) = protocolFeeVault.call{value: protocolFee}("");
        require(ok1, "Fee transfer failed");

        // ✅ Gửi phần còn lại về pool
        (bool ok2, ) = payable(address(this)).call{value: lenderInterest}("");
        require(ok2, "Lender interest failed");

        // ✅ Gửi penalty nếu có
        if (penalty > 0) {
            uint256 protocolPenalty = (penalty * LATE_PENALTY_TO_PROTOCOL) / 100;
            uint256 lenderPenalty = penalty - protocolPenalty;

            (bool ok3, ) = protocolFeeVault.call{value: protocolPenalty}("");
            require(ok3, "Penalty protocol failed");

            (bool ok4, ) = payable(address(this)).call{value: lenderPenalty}("");
            require(ok4, "Penalty lender failed");
        }

        // ✅ Trả lại tài sản thế chấp
        payable(msg.sender).transfer(loan.collateralAmount);
    }

    // ---------------------
    // 🧨 LIQUIDATION (UPDATED)
    // ---------------------

    function liquidate(address borrower, uint256 index) external {
        Loan storage loan = userLoans[borrower][index];
        require(!loan.isRepaid, "Already repaid");
        require(!loan.isLiquidated, "Already liquidated");

        uint256 ethPrice = oracle.getLatestEthPrice();

        bool overdue = Utils.isOverdue(loan.dueDate);
        bool underCollateralized = Utils.isUnderCollateralized(
            loan.collateralAmount,
            loan.amountBorrowed,
            ethPrice
        );

        require(overdue || underCollateralized, "Not eligible for liquidation");

        loan.isRepaid = true;
        loan.isLiquidated = true; // ✅ đánh dấu bị thanh lý

        uint256 collateral = loan.collateralAmount;
        loan.collateralAmount = 0;

        (bool sent, ) = payable(msg.sender).call{value: collateral}("");
        require(sent, "Collateral transfer failed");

        emit LoanLiquidated(borrower, index, msg.sender, collateral);
    }

    // ---------------------
    // 📊 UTILITY
    // ---------------------

    function getLoanCount(address user) external view returns (uint256) {
        return userLoans[user].length;
    }

    function totalOutstandingDebt() public view returns (uint256 total) {
        for (uint256 i = 0; i < userLoans[msg.sender].length; i++) {
            Loan memory loan = userLoans[msg.sender][i];
            if (!loan.isRepaid && !loan.isLiquidated) {
                total += loan.amountBorrowed;
            }
        }
    }
}
