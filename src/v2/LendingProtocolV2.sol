// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PriceOracleRouter.sol";
import "./tokens/VNDStablecoinV2.sol";

/// @title LendingProtocolV2 - multi-collateral, multi-debt lending with a DAI-style VNDD vault
/// @notice Two collateral assets (WETH, wSOL) × two debt assets (VNDD, USDC) = the four pairs
///         ETH/VNDD, ETH/USDC, SOL/VNDD, SOL/USDC. Each loan is an **isolated position** (one collateral,
///         one debt). Health is measured in USD via the PriceOracleRouter.
///   - VNDD debt is **minted** against collateral and **burned** on repay (MakerDAO/CDP style): this is
///     what makes VNDD a real over-collateralized stablecoin. Its stability fee goes to the treasury.
///   - USDC debt is **borrowed from a supplied pool** (Aave style): USDC suppliers earn the borrow
///     interest through a rising liquidity index.
/// @dev Educational/testnet. Supports partial repay, borrow-more, and liquidation with a bonus +
///      partial collateral seizure (the borrower keeps the residual). Interest is simple/linear and
///      capitalizes into principal on borrow-more.
contract LendingProtocolV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant RAY = 1e27;
    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;

    enum DebtKind {
        None,
        Mint, // VNDD: minted/burned by this contract
        Pool // USDC: lent from a supplied pool

    }

    struct CollateralConfig {
        bool allowed;
        uint8 decimals;
        uint256 minRatioBps; // required at borrow/withdraw, e.g. 15000 = 150%
        uint256 liqThresholdBps; // liquidatable below this, e.g. 13000 = 130%
        uint256 liqBonusBps; // liquidator's discount/bonus, e.g. 1000 = 10%
    }

    struct DebtConfig {
        bool allowed;
        DebtKind kind;
        uint8 decimals;
        uint256 rateBps; // annual interest / stability fee, e.g. 500 = 5%
    }

    struct Position {
        address collToken;
        address debtToken;
        uint256 collAmount; // in collToken decimals
        uint256 principal; // in debtToken decimals
        uint256 rateBps; // snapshot of the rate at open / last capitalization
        uint256 openedAt; // for linear interest accrual
        bool active;
    }

    PriceOracleRouter public oracle;
    VNDStablecoinV2 public vndd;
    address public treasury; // receives VNDD stability fees + protocol cut

    mapping(address => CollateralConfig) public collateralConfig;
    mapping(address => DebtConfig) public debtConfig;
    mapping(address => Position[]) public positions; // user => positions

    // Aave-style supply pool, per Pool-kind debt asset (USDC)
    mapping(address => uint256) public supplyIndex; // asset => RAY index
    mapping(address => uint256) public totalScaledSupply; // asset => sum of scaled balances
    mapping(address => mapping(address => uint256)) public scaledSupply; // asset => user => scaled

    event CollateralConfigured(address indexed token, uint256 minRatioBps, uint256 liqThresholdBps);
    event DebtConfigured(address indexed token, DebtKind kind, uint256 rateBps);
    event Supply(address indexed asset, address indexed user, uint256 amount);
    event WithdrawSupply(address indexed asset, address indexed user, uint256 amount);
    event PositionOpened(
        address indexed user, uint256 indexed id, address collToken, address debtToken, uint256 coll, uint256 debt
    );
    event Borrowed(address indexed user, uint256 indexed id, uint256 amount);
    event CollateralAdded(address indexed user, uint256 indexed id, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 indexed id, uint256 amount);
    event Repaid(address indexed user, uint256 indexed id, uint256 amountPaid, bool closed);
    event Liquidated(
        address indexed user, uint256 indexed id, address indexed liquidator, uint256 collateralSeized, uint256 debtRepaid
    );

    constructor(address _oracle, address _vndd, address _treasury) Ownable(msg.sender) {
        oracle = PriceOracleRouter(_oracle);
        vndd = VNDStablecoinV2(_vndd);
        treasury = _treasury;
    }

    // --- configuration (owner) ------------------------------------------

    function configureCollateral(
        address token,
        uint8 decimals,
        uint256 minRatioBps,
        uint256 liqThresholdBps,
        uint256 liqBonusBps
    ) external onlyOwner {
        require(liqThresholdBps < minRatioBps, "liq < min");
        require(liqThresholdBps >= BPS, "ratio < 100%"); // must stay over-collateralized
        require(liqBonusBps < 5000, "bonus too high");
        collateralConfig[token] = CollateralConfig(true, decimals, minRatioBps, liqThresholdBps, liqBonusBps);
        emit CollateralConfigured(token, minRatioBps, liqThresholdBps);
    }

    function configureDebt(address token, DebtKind kind, uint8 decimals, uint256 rateBps) external onlyOwner {
        require(kind != DebtKind.None, "bad kind");
        debtConfig[token] = DebtConfig(true, kind, decimals, rateBps);
        if (kind == DebtKind.Pool && supplyIndex[token] == 0) supplyIndex[token] = RAY;
        emit DebtConfigured(token, kind, rateBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    // --- USDC supply side (Aave-style lenders) --------------------------

    /// @notice Supply a Pool-kind asset (USDC) to earn borrow interest. Requires prior approve.
    function supply(address asset, uint256 amount) external nonReentrant {
        DebtConfig memory dc = debtConfig[asset];
        require(dc.allowed && dc.kind == DebtKind.Pool, "not a pool asset");
        require(amount > 0, "zero");
        uint256 scaled = amount * RAY / supplyIndex[asset];
        scaledSupply[asset][msg.sender] += scaled;
        totalScaledSupply[asset] += scaled;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Supply(asset, msg.sender, amount);
    }

    /// @notice Withdraw supplied USDC + earned interest. `scaled` is the scaled-balance amount to redeem.
    function withdrawSupply(address asset, uint256 scaled) external nonReentrant {
        require(scaledSupply[asset][msg.sender] >= scaled, "insufficient balance");
        uint256 amount = scaled * supplyIndex[asset] / RAY;
        require(IERC20(asset).balanceOf(address(this)) >= amount, "insufficient liquidity");
        scaledSupply[asset][msg.sender] -= scaled;
        totalScaledSupply[asset] -= scaled;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit WithdrawSupply(asset, msg.sender, amount);
    }

    // --- borrower side --------------------------------------------------

    /// @notice Open a position: lock `collAmount` of `collToken`, take `debtAmount` of `debtToken`.
    /// @dev Requires a prior approve of `collToken`.
    function openPosition(address collToken, uint256 collAmount, address debtToken, uint256 debtAmount)
        external
        nonReentrant
        returns (uint256 id)
    {
        CollateralConfig memory cc = collateralConfig[collToken];
        DebtConfig memory dc = debtConfig[debtToken];
        require(cc.allowed, "collateral not allowed");
        require(dc.allowed, "debt not allowed");
        require(collAmount > 0 && debtAmount > 0, "zero amount");

        uint256 collUsd = _collateralUsd(collToken, collAmount, cc.decimals);
        uint256 debtUsd = _debtUsd(debtToken, debtAmount, dc);
        require(collUsd * BPS >= debtUsd * cc.minRatioBps, "insufficient collateral");

        IERC20(collToken).safeTransferFrom(msg.sender, address(this), collAmount);

        positions[msg.sender].push(
            Position({
                collToken: collToken,
                debtToken: debtToken,
                collAmount: collAmount,
                principal: debtAmount,
                rateBps: dc.rateBps,
                openedAt: block.timestamp,
                active: true
            })
        );
        id = positions[msg.sender].length - 1;

        _disburse(dc, debtToken, msg.sender, debtAmount);
        emit PositionOpened(msg.sender, id, collToken, debtToken, collAmount, debtAmount);
    }

    /// @notice Borrow more against an existing position (if it stays healthy). Accrued interest is
    ///         capitalized into principal first, so the new total accrues from now.
    function borrow(uint256 id, uint256 moreDebt) external nonReentrant {
        Position storage p = positions[msg.sender][id];
        require(p.active, "inactive");
        require(moreDebt > 0, "zero");
        CollateralConfig memory cc = collateralConfig[p.collToken];
        DebtConfig memory dc = debtConfig[p.debtToken];

        uint256 newPrincipal = _currentDebt(p) + moreDebt; // capitalize interest, then add
        uint256 collUsd = _collateralUsd(p.collToken, p.collAmount, cc.decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, newPrincipal, dc);
        require(collUsd * BPS >= debtUsd * cc.minRatioBps, "insufficient collateral");

        p.principal = newPrincipal;
        p.rateBps = dc.rateBps;
        p.openedAt = block.timestamp;

        _disburse(dc, p.debtToken, msg.sender, moreDebt);
        emit Borrowed(msg.sender, id, moreDebt);
    }

    function addCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender][id];
        require(p.active, "inactive");
        require(amount > 0, "zero");
        p.collAmount += amount;
        IERC20(p.collToken).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralAdded(msg.sender, id, amount);
    }

    /// @notice Withdraw some collateral while keeping the position healthy (>= minRatio).
    function withdrawCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender][id];
        require(p.active, "inactive");
        require(amount > 0 && amount <= p.collAmount, "bad amount");
        CollateralConfig memory cc = collateralConfig[p.collToken];

        uint256 newColl = p.collAmount - amount;
        uint256 collUsd = _collateralUsd(p.collToken, newColl, cc.decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, _currentDebt(p), debtConfig[p.debtToken]);
        require(collUsd * BPS >= debtUsd * cc.minRatioBps, "would be undercollateralized");

        p.collAmount = newColl;
        IERC20(p.collToken).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, id, amount);
    }

    /// @notice Repay up to `amount` of the debt. Repaying the full amount owed closes the position and
    ///         returns all collateral; a partial repay reduces the principal (collateral stays locked).
    ///         Any repay must at least cover the accrued interest. Requires a prior approve.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender][id];
        require(p.active, "inactive");
        require(amount > 0, "zero");

        uint256 principal = p.principal;
        uint256 owed = _currentDebt(p);
        uint256 interest = owed - principal;
        uint256 pay = amount >= owed ? owed : amount;
        require(pay >= interest, "must cover accrued interest");
        uint256 principalPaid = pay - interest;

        if (pay == owed) {
            uint256 coll = p.collAmount;
            p.active = false;
            p.principal = 0;
            p.collAmount = 0;
            _settleDebt(p.debtToken, msg.sender, principal, interest);
            IERC20(p.collToken).safeTransfer(msg.sender, coll);
            emit Repaid(msg.sender, id, pay, true);
        } else {
            p.principal = principal - principalPaid;
            p.openedAt = block.timestamp;
            _settleDebt(p.debtToken, msg.sender, principalPaid, interest);
            emit Repaid(msg.sender, id, pay, false);
        }
    }

    /// @notice Liquidate an under-collateralized position. The liquidator repays the debt and seizes
    ///         collateral worth `debt × (1 + liqBonus)`; the borrower keeps any residual collateral.
    /// @dev Requires a prior approve of the debt token for the amount owed.
    function liquidate(address user, uint256 id) external nonReentrant {
        Position storage p = positions[user][id];
        require(p.active, "inactive");

        CollateralConfig memory cc = collateralConfig[p.collToken];
        uint256 owed = _currentDebt(p);
        uint256 collUsd = _collateralUsd(p.collToken, p.collAmount, cc.decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, owed, debtConfig[p.debtToken]);
        require(collUsd * BPS < debtUsd * cc.liqThresholdBps, "position is healthy");

        uint256 principal = p.principal;
        uint256 interest = owed - principal;
        uint256 totalColl = p.collAmount;

        // collateral to seize = debt value × (1 + bonus), converted to collateral units, capped.
        uint256 collPrice = oracle.getUsdPrice(p.collToken); // USD per whole coll token (1e18)
        uint256 seize = (debtUsd * (BPS + cc.liqBonusBps) / BPS) * (10 ** cc.decimals) / collPrice;
        if (seize > totalColl) seize = totalColl;
        uint256 residual = totalColl - seize;

        // effects
        p.active = false;
        p.principal = 0;
        p.collAmount = 0;

        // liquidator repays the debt, seizes `seize`; borrower keeps `residual`
        _settleDebt(p.debtToken, msg.sender, principal, interest);
        IERC20(p.collToken).safeTransfer(msg.sender, seize);
        if (residual > 0) IERC20(p.collToken).safeTransfer(user, residual);
        emit Liquidated(user, id, msg.sender, seize, owed);
    }

    // --- internal -------------------------------------------------------

    /// @dev Hand out `amount` of `debtToken`: mint VNDD, or transfer USDC from the pool.
    function _disburse(DebtConfig memory dc, address debtToken, address to, uint256 amount) internal {
        if (dc.kind == DebtKind.Mint) {
            vndd.mint(to, amount);
        } else {
            require(IERC20(debtToken).balanceOf(address(this)) >= amount, "insufficient pool liquidity");
            IERC20(debtToken).safeTransfer(to, amount);
        }
    }

    /// @dev Pull `principal + interest` of the debt token from `payer` and route it:
    ///   - Mint (VNDD): burn the principal, send interest to the treasury.
    ///   - Pool (USDC): principal replenishes pool liquidity, interest accrues to suppliers via the index.
    function _settleDebt(address debtToken, address payer, uint256 principal, uint256 interest) internal {
        DebtConfig memory dc = debtConfig[debtToken];
        uint256 owed = principal + interest;
        IERC20(debtToken).safeTransferFrom(payer, address(this), owed);
        if (dc.kind == DebtKind.Mint) {
            if (principal > 0) vndd.burn(address(this), principal);
            if (interest > 0) IERC20(debtToken).safeTransfer(treasury, interest);
        } else {
            if (interest > 0 && totalScaledSupply[debtToken] > 0) {
                supplyIndex[debtToken] += interest * RAY / totalScaledSupply[debtToken];
            } else if (interest > 0) {
                IERC20(debtToken).safeTransfer(treasury, interest);
            }
        }
    }

    function _currentDebt(Position memory p) internal view returns (uint256) {
        uint256 interest = p.principal * p.rateBps * (block.timestamp - p.openedAt) / (YEAR * BPS);
        return p.principal + interest;
    }

    function _collateralUsd(address token, uint256 amount, uint8 decimals) internal view returns (uint256) {
        return oracle.getUsdPrice(token) * amount / (10 ** decimals);
    }

    function _debtUsd(address token, uint256 amount, DebtConfig memory dc) internal view returns (uint256) {
        if (dc.kind == DebtKind.Mint) {
            return oracle.vndToUsd(amount); // VNDD is 18-dec, 1 VNDD = 1 VND
        } else {
            return oracle.getUsdPrice(token) * amount / (10 ** dc.decimals);
        }
    }

    // --- views ----------------------------------------------------------

    function getPositionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getPosition(address user, uint256 id)
        external
        view
        returns (
            address collToken,
            address debtToken,
            uint256 collAmount,
            uint256 principal,
            uint256 rateBps,
            uint256 openedAt,
            bool active
        )
    {
        Position memory p = positions[user][id];
        return (p.collToken, p.debtToken, p.collAmount, p.principal, p.rateBps, p.openedAt, p.active);
    }

    /// @notice Full amount owed right now (principal + accrued interest) in debt-token units.
    function currentDebt(address user, uint256 id) external view returns (uint256) {
        return _currentDebt(positions[user][id]);
    }

    /// @notice Collateralization ratio in bps (collateralUSD / debtUSD), or max uint if no debt.
    function collateralRatioBps(address user, uint256 id) external view returns (uint256) {
        Position memory p = positions[user][id];
        if (!p.active) return 0;
        uint256 owed = _currentDebt(p);
        if (owed == 0) return type(uint256).max;
        uint256 collUsd = _collateralUsd(p.collToken, p.collAmount, collateralConfig[p.collToken].decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, owed, debtConfig[p.debtToken]);
        return collUsd * BPS / debtUsd;
    }

    /// @notice Health factor (1e18-scaled): >= 1e18 is safe, < 1e18 is liquidatable. Max if no debt.
    function healthFactor(address user, uint256 id) external view returns (uint256) {
        Position memory p = positions[user][id];
        if (!p.active) return 0;
        uint256 owed = _currentDebt(p);
        if (owed == 0) return type(uint256).max;
        CollateralConfig memory cc = collateralConfig[p.collToken];
        uint256 collUsd = _collateralUsd(p.collToken, p.collAmount, cc.decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, owed, debtConfig[p.debtToken]);
        return collUsd * BPS * 1e18 / (debtUsd * cc.liqThresholdBps);
    }

    /// @notice True if the position can be liquidated right now.
    function isLiquidatable(address user, uint256 id) external view returns (bool) {
        Position memory p = positions[user][id];
        if (!p.active) return false;
        CollateralConfig memory cc = collateralConfig[p.collToken];
        uint256 owed = _currentDebt(p);
        uint256 collUsd = _collateralUsd(p.collToken, p.collAmount, cc.decimals);
        uint256 debtUsd = _debtUsd(p.debtToken, owed, debtConfig[p.debtToken]);
        return collUsd * BPS < debtUsd * cc.liqThresholdBps;
    }

    /// @notice USDC (pool asset) available to borrow / withdraw right now.
    function availableLiquidity(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice A supplier's redeemable balance of a pool asset (principal + interest).
    function suppliedBalance(address asset, address user) external view returns (uint256) {
        return scaledSupply[asset][user] * supplyIndex[asset] / RAY;
    }
}
