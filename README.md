# solidity-p2p-lending

An **Aave-style, over-collateralized peer-to-pool ETH lending protocol**, written in Solidity as a
learning project and ported to **Foundry**. Lenders deposit ETH and receive an interest-bearing
receipt token (`aETH`); borrowers post ETH collateral, take an ETH loan at a fixed or floating rate,
receive a non-transferable debt token, and repay with interest. Overdue loans can be liquidated.

> ⚠️ **Educational code — not audited, do NOT use with real funds.** It started from a Remix export
> with several serious bugs; those have been fixed on the `fix/known-issues` line (see
> [What was fixed](#what-was-fixed)). Some intentional simplifications remain (see [Design notes](#design-notes--remaining-simplifications)).

## Architecture

| Contract | Responsibility |
|---|---|
| `LendingPool.sol` | Core entry point: `deposit / withdraw / borrow / repayLoan / liquidate`. Inherits `LoanManager` + `ReentrancyGuard`. Tracks pool-wide `totalBorrowed`. |
| `LoanManager.sol` | Loan storage: the `Loan` struct, `RateMode` enum, and `userLoans` mapping. |
| `InterestRateModel.sol` | Aave-style kinked utilization curve for variable-rate loans. |
| `Utils.sol` | Library: `isOverdue`, `isUnderCollateralized` (120% threshold). |
| `aToken.sol` | Lender receipt (`aETH`); scaled-balance model. Liquidity index rises only on real interest (`accrueToLenders`). |
| `DebtToken.sol` | Base non-transferable debt token (mint on borrow, burn on repay/liquidate). |
| `StableDebtToken.sol` / `VariableDebtToken.sol` | Fixed-rate (`sdETH`) and floating-rate (`vdETH`) debt tokens. |
| `IPriceOracle.sol` | Oracle interface (`getLatestEthPrice`). |
| `MockPriceOracle.sol` | Owner-settable price, used by `LendingPool` for testing. |
| `ChainlinkPriceOracle.sol` | Production oracle reading a Chainlink ETH/USD feed. |
| `PriceOracle.sol` | Older owner-settable mock (superseded by `MockPriceOracle`). |
| `ProtocolFeeVault.sol` | Collects the protocol's fee + late-penalty share; owner can withdraw. |

### Lifecycle

```
Lender   deposit() ──► aToken minted ──► withdraw() burns aToken, redeems principal + accrued yield
Borrower borrow()  ──► collateral locked (≥200%), debt token minted, ETH sent
         repayLoan()──► debt burned, interest split (protocol vs lenders), collateral returned, overpay refunded
Liquidator liquidate() ──► if overdue: repay borrower's principal, seize collateral, burn the debt
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`).

```bash
git clone --recursive <repo-url>   # submodules: forge-std + OpenZeppelin
cd solidity-p2p-lending

forge build      # compile
forge test       # run the suite (16 tests)
forge test -vvv  # with traces
```

### Deploy

```bash
# Local
anvil
forge script script/Deploy.s.sol --fork-url http://localhost:8545 --broadcast

# Testnet (e.g. Holesky)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
```

`Deploy.s.sol` deploys the full stack and wires `setPool(...)` on each token. Swap `MockPriceOracle`
for `ChainlinkPriceOracle` (with a real feed address) before any non-test deployment.

## What was fixed

The original Remix export had seven documented issues. All are addressed:

1. **`repayLoan()` always reverted (critical).** It called the pool itself with empty calldata
   (`address(this).call{...}("")`) with no `receive()`/`fallback()`. **Fix:** removed the self-call —
   the lender's ETH simply stays in the pool and is credited via the liquidity index.
2. **`liquidate()` gave collateral away for free.** **Fix:** the liquidator must now repay the
   outstanding principal (`msg.value >= principal`); the debt token is burned and the repaid
   principal replenishes pool liquidity. Profit = collateral − principal.
3. **`totalOutstandingDebt()` only saw `msg.sender`'s loans.** **Fix:** a pool-wide `totalBorrowed`
   state variable, updated on borrow/repay/liquidate, now drives utilization.
4. **Lender interest was never credited.** **Fix:** `aToken.accrueToLenders()` raises the liquidity
   index from *real* repaid interest, and the time-based (unbacked) accrual was removed.
5. **Open setters.** **Fix:** `MockPriceOracle.setEthPrice` and `PriceOracle.setPrice` are now
   `onlyOwner` (OpenZeppelin `Ownable`).
6. **Unit mismatch in the collateral check.** **Fix:** the borrow check now compares USD-to-USD
   consistently and enforces a true 200% ratio.
7. **Inconsistent ETH transfers / no reentrancy guard.** **Fix:** all sends use `.call` + a success
   check, entrypoints are `nonReentrant`, and follow checks-effects-interactions.

The dead, duplicated `CollateralManager.sol` (a buggy parallel copy of `liquidate` that couldn't be
made correct in isolation) was removed; `LendingPool.liquidate` is the single canonical path.

## Design notes & remaining simplifications

- **Single-asset market:** collateral and debt are both ETH, so the USD price *cancels* in the
  collateralization math. `isUnderCollateralized` is therefore price-invariant and can't trip for a
  200%-collateralized loan — **overdue** is the operative liquidation trigger. The oracle and the
  under-collateralization check are kept for a future multi-asset generalization.
- **Liquidation forgives accrued interest** (liquidator repays principal only) for simplicity.
- **Lender yield is real-only:** lenders earn solely from borrower interest paid into the pool, not
  from the passage of time.

## Original Holesky deployment

The source project (with the bugs above) was deployed to **Holesky (chainId 17000)** from Remix:

| Contract | Address |
|---|---|
| LendingPool | `0x02424067998ec11ce0db7cef7ce97247700394ef` |
| aToken | `0xc1a9a892c606901941f22b8df6677f497ec6ff60` |
| MockPriceOracle | `0x923A912115932908a6975A9704894E41a6AC0f22` |
| StableDebtToken | `0x286060717de9479eee01e2d672ae395b4dbba1ea` |
| VariableDebtToken | `0xb7f80b56ff55dced56c831d59dc54a0f63749f00` |
| InterestRateModel | `0x0ce7285bacbd7070d0c3d178013c78463b5492d7` |
| ProtocolFeeVault | `0x7f8a694cd1fa86bcf8e894aa7a77fd49b6645455` |

## Origin & license

Ported from a Remix IDE workspace export (Vietnamese inline comments kept verbatim). MIT licensed.
