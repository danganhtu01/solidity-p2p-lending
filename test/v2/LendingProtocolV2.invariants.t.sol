// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {PriceOracleRouter} from "../../src/v2/PriceOracleRouter.sol";
import {LendingProtocolV2} from "../../src/v2/LendingProtocolV2.sol";
import {VNDStablecoinV2} from "../../src/v2/tokens/VNDStablecoinV2.sol";
import {MockERC20} from "../../src/v2/tokens/MockERC20.sol";
import {MockWETH9} from "../../src/v2/tokens/MockWETH9.sol";
import {MockAggregator, MockPyth} from "./Mocks.sol";

/// @notice Drives random sequences of protocol actions across several actors. Foundry calls these
///         public methods with fuzzed inputs; the invariants below must hold after every call.
contract Handler is Test {
    LendingProtocolV2 public proto;
    PriceOracleRouter public oracle;
    VNDStablecoinV2 public vndd;
    MockWETH9 public weth;
    MockERC20 public wsol;
    MockERC20 public usdc;
    MockAggregator public ethFeed;

    address[] public actors;
    struct Ref {
        address actor;
        uint256 id;
    }
    Ref[] public refs;

    constructor(
        LendingProtocolV2 _proto,
        PriceOracleRouter _oracle,
        VNDStablecoinV2 _vndd,
        MockWETH9 _weth,
        MockERC20 _wsol,
        MockERC20 _usdc,
        MockAggregator _ethFeed
    ) {
        proto = _proto;
        oracle = _oracle;
        vndd = _vndd;
        weth = _weth;
        wsol = _wsol;
        usdc = _usdc;
        ethFeed = _ethFeed;
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
    }

    function refCount() external view returns (uint256) {
        return refs.length;
    }

    function _fundColl(address actor, address token, uint256 amount) internal {
        if (token == address(weth)) {
            vm.deal(actor, amount);
            vm.prank(actor);
            weth.deposit{value: amount}();
        } else {
            wsol.mint(actor, amount); // handler owns wsol
        }
    }

    // open a VNDD-debt position with a safe (~2x the minimum) collateralization
    function openVndd(uint256 seed, uint256 collSeed, uint256 amtSeed) public {
        address actor = actors[seed % actors.length];
        address coll = (collSeed % 2 == 0) ? address(weth) : address(wsol);
        uint256 collAmt = bound(amtSeed, 1e16, 30e18);
        (, uint8 cdec, uint256 minRatio,,) = proto.collateralConfig(coll);
        uint256 collUsd = oracle.getUsdPrice(coll) * collAmt / (10 ** cdec);
        uint256 maxVndUsd = collUsd * 10_000 / minRatio;
        uint256 debtVnd = oracle.usdToVnd(maxVndUsd / 2); // half of max => ~2x safe
        if (debtVnd == 0) return;

        _fundColl(actor, coll, collAmt);
        vm.startPrank(actor);
        _approveColl(actor, coll, collAmt);
        uint256 id = proto.openPosition(coll, collAmt, address(vndd), debtVnd);
        vm.stopPrank();
        refs.push(Ref(actor, id));
    }

    // open a USDC-debt position (bounded by available pool liquidity)
    function openUsdc(uint256 seed, uint256 collSeed, uint256 amtSeed) public {
        address actor = actors[seed % actors.length];
        address coll = (collSeed % 2 == 0) ? address(weth) : address(wsol);
        uint256 collAmt = bound(amtSeed, 1e16, 30e18);
        (, uint8 cdec, uint256 minRatio,,) = proto.collateralConfig(coll);
        uint256 collUsd = oracle.getUsdPrice(coll) * collAmt / (10 ** cdec);
        uint256 maxUsdcUsd = collUsd * 10_000 / minRatio;
        uint256 debtUsdc = (maxUsdcUsd / 2) / 1e12; // USD(1e18) -> USDC(6dec), USDC ~ $1
        uint256 avail = usdc.balanceOf(address(proto));
        if (debtUsdc == 0 || debtUsdc > avail) return;

        _fundColl(actor, coll, collAmt);
        vm.startPrank(actor);
        _approveColl(actor, coll, collAmt);
        uint256 id = proto.openPosition(coll, collAmt, address(usdc), debtUsdc);
        vm.stopPrank();
        refs.push(Ref(actor, id));
    }

    function _approveColl(address, address coll, uint256 amt) internal {
        if (coll == address(weth)) weth.approve(address(proto), amt);
        else wsol.approve(address(proto), amt);
    }

    function repayRandom(uint256 seed) public {
        if (refs.length == 0) return;
        Ref memory r = refs[seed % refs.length];
        (, address debtToken,, uint256 principal,,, bool active) = proto.getPosition(r.actor, r.id);
        if (!active || principal == 0) return;
        uint256 owed = proto.currentDebt(r.actor, r.id);
        // give the actor enough of the debt token to repay in full
        if (debtToken == address(vndd)) vndd.mint(r.actor, owed);
        else usdc.mint(r.actor, owed);
        vm.startPrank(r.actor);
        if (debtToken == address(vndd)) vndd.approve(address(proto), owed);
        else usdc.approve(address(proto), owed);
        proto.repay(r.id, type(uint256).max);
        vm.stopPrank();
    }

    function addColl(uint256 seed, uint256 amtSeed) public {
        if (refs.length == 0) return;
        Ref memory r = refs[seed % refs.length];
        (address collToken,,, uint256 principal,,, bool active) = proto.getPosition(r.actor, r.id);
        if (!active || principal == 0) return;
        uint256 amt = bound(amtSeed, 1e15, 5e18);
        _fundColl(r.actor, collToken, amt);
        vm.startPrank(r.actor);
        _approveColl(r.actor, collToken, amt);
        proto.addCollateral(r.id, amt);
        vm.stopPrank();
    }

    function supplyUsdc(uint256 seed, uint256 amtSeed) public {
        address actor = actors[seed % actors.length];
        uint256 amt = bound(amtSeed, 1e6, 50_000e6);
        usdc.mint(actor, amt);
        vm.startPrank(actor);
        usdc.approve(address(proto), amt);
        proto.supply(address(usdc), amt);
        vm.stopPrank();
    }

    function movePrice(uint256 priceSeed) public {
        // ETH price between $500 and $5000 — exercises liquidation paths
        int256 p = int256(bound(priceSeed, 500e8, 5000e8));
        ethFeed.set(p);
    }

    function liquidateRandom(uint256 seed) public {
        if (refs.length == 0) return;
        Ref memory r = refs[seed % refs.length];
        if (!proto.isLiquidatable(r.actor, r.id)) return;
        (, address debtToken,, uint256 principal,,, bool active) = proto.getPosition(r.actor, r.id);
        if (!active || principal == 0) return;
        address liq = actors[(seed + 1) % actors.length];
        uint256 owed = proto.currentDebt(r.actor, r.id);
        if (debtToken == address(vndd)) vndd.mint(liq, owed);
        else usdc.mint(liq, owed);
        vm.startPrank(liq);
        if (debtToken == address(vndd)) vndd.approve(address(proto), owed);
        else usdc.approve(address(proto), owed);
        proto.liquidate(r.actor, r.id);
        vm.stopPrank();
    }
}

contract LendingProtocolV2Invariants is Test {
    PriceOracleRouter internal oracle;
    LendingProtocolV2 internal proto;
    VNDStablecoinV2 internal vndd;
    MockWETH9 internal weth;
    MockERC20 internal wsol;
    MockERC20 internal usdc;
    MockPyth internal pyth;
    MockAggregator internal ethFeed;
    MockAggregator internal usdcFeed;
    Handler internal handler;

    bytes32 internal constant SOL_ID = bytes32(uint256(0x5021));

    function setUp() public {
        vndd = new VNDStablecoinV2(address(this));
        weth = new MockWETH9();
        wsol = new MockERC20("Wrapped SOL", "wSOL", 18, 1000e18);
        usdc = new MockERC20("USD Coin", "USDC", 6, 1_000_000e6);

        pyth = new MockPyth();
        oracle = new PriceOracleRouter(address(pyth), 25_400e18);
        ethFeed = new MockAggregator(3000e8, 8);
        usdcFeed = new MockAggregator(1e8, 8);
        oracle.setChainlinkSource(address(weth), address(ethFeed));
        oracle.setChainlinkSource(address(usdc), address(usdcFeed));
        oracle.setPythSource(address(wsol), SOL_ID);
        pyth.setPrice(SOL_ID, 150e8, -8);

        proto = new LendingProtocolV2(address(oracle), address(vndd), address(this));
        vndd.setMinter(address(proto), true);
        proto.configureCollateral(address(weth), 18, 15000, 12000, 1000);
        proto.configureCollateral(address(wsol), 18, 20000, 15000, 1500);
        proto.configureDebt(address(vndd), LendingProtocolV2.DebtKind.Mint, 18, 200);
        proto.configureDebt(address(usdc), LendingProtocolV2.DebtKind.Pool, 6, 500);

        // seed the USDC pool
        usdc.mint(address(this), 200_000e6);
        usdc.approve(address(proto), 200_000e6);
        proto.supply(address(usdc), 200_000e6);

        handler = new Handler(proto, oracle, vndd, weth, wsol, usdc, ethFeed);
        // let the handler mint test tokens to its actors
        wsol.transferOwnership(address(handler));
        usdc.transferOwnership(address(handler));
        vndd.setMinter(address(handler), true);

        targetContract(address(handler));
    }

    /// @dev Sum the collateral of all active positions for a given token.
    function _activeCollateral(address token) internal view returns (uint256 sum) {
        uint256 n = handler.refCount();
        for (uint256 i = 0; i < n; i++) {
            (address actor, uint256 id) = handler.refs(i);
            (address collToken,, uint256 collAmount,,,, bool active) = proto.getPosition(actor, id);
            if (active && collToken == token) sum += collAmount;
        }
    }

    function _activeUsdcPrincipal() internal view returns (uint256 sum) {
        uint256 n = handler.refCount();
        for (uint256 i = 0; i < n; i++) {
            (address actor, uint256 id) = handler.refs(i);
            (, address debtToken,, uint256 principal,,, bool active) = proto.getPosition(actor, id);
            if (active && debtToken == address(usdc)) sum += principal;
        }
    }

    /// INVARIANT: the protocol always custodies at least the collateral it owes back to borrowers.
    function invariant_collateralCustody() public view {
        assertGe(weth.balanceOf(address(proto)), _activeCollateral(address(weth)), "WETH custody");
        assertGe(wsol.balanceOf(address(proto)), _activeCollateral(address(wsol)), "wSOL custody");
    }

    /// INVARIANT: USDC suppliers' claims are always backed by cash on hand + outstanding loans.
    function invariant_usdcSolvency() public view {
        uint256 claims = proto.suppliedBalance(address(usdc), address(this));
        // include any actor supply via the handler
        uint256 n = handler.refCount();
        // suppliers are actors + this; sum claims over the 3 actors too
        address[3] memory actors =
            [handler.actors(0), handler.actors(1), handler.actors(2)];
        for (uint256 i = 0; i < 3; i++) {
            claims += proto.suppliedBalance(address(usdc), actors[i]);
        }
        n; // silence unused
        uint256 backing = usdc.balanceOf(address(proto)) + _activeUsdcPrincipal();
        assertGe(backing, claims, "USDC suppliers backed by cash + loans");
    }
}
