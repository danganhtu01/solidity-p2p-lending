# solidity-p2p-lending

An **Aave-style, over-collateralized peer-to-pool ETH lending protocol**, written in Solidity as a
learning project and ported to **Foundry**. Lenders deposit ETH and receive an interest-bearing
receipt token (`aETH`); borrowers post ETH collateral, take an ETH loan at a fixed or floating rate,
receive a non-transferable debt token, and repay with interest. Overdue or under-collateralized
loans can be liquidated.

> ⚠️ **Educational code — do NOT deploy with real funds.** It contains several known, intentional-to-
> study bugs (see [Known issues](#known-issues)). The most severe: **`repayLoan()` always reverts**,
> so in the current code no borrower can ever repay or recover collateral. These are preserved on
> purpose; the test suite documents them.

## Architecture

| Contract | Responsibility |
|---|---|
| `LendingPool.sol` | Core entry point: `deposit / withdraw / borrow / repayLoan / liquidate`. Inherits `LoanManager`. |
| `LoanManager.sol` | Loan storage: the `Loan` struct, `RateMode` enum, and `userLoans` mapping. |
| `InterestRateModel.sol` | Aave-style kinked utilization curve for variable-rate loans. |
| `CollateralManager.sol` | Alternative/standalone liquidation handler (not wired into `LendingPool`). |
| `Utils.sol` | Library: `isOverdue`, `isUnderCollateralized` (120% liquidation threshold). |
| `aToken.sol` | Lender deposit receipt (`aETH`); Aave RAY (1e27) liquidity index for interest accrual. |
| `DebtToken.sol` | Base non-transferable debt token (mint on borrow, burn on repay). |
| `StableDebtToken.sol` / `VariableDebtToken.sol` | Fixed-rate (`sdETH`) and floating-rate (`vdETH`) debt tokens. |
| `IPriceOracle.sol` | Oracle interface (`getLatestEthPrice`). |
| `MockPriceOracle.sol` | Manually-settable price, used by `LendingPool` for testing. |
| `ChainlinkPriceOracle.sol` | Production oracle reading a Chainlink ETH/USD feed. |
| `PriceOracle.sol` | Older hard-coded mock (superseded by `MockPriceOracle`). |
| `ProtocolFeeVault.sol` | Collects the protocol's fee + late-penalty share; owner can withdraw. |

### Lifecycle

```
Lender   deposit() ──► aToken minted ──► withdraw() burns aToken, pays principal + index interest
Borrower borrow()  ──► collateral locked, debt token minted, ETH sent
         repayLoan()──► debt burned, interest split (protocol vs pool), collateral returned
Anyone   liquidate()─► if overdue OR under-collateralized: seize collateral
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`).

```bash
# Clone with submodules (forge-std + OpenZeppelin live in lib/ as git submodules)
git clone --recursive <repo-url>
cd solidity-p2p-lending

forge build      # compile
forge test       # run the test suite (13 tests)
forge test -vvv  # with traces
forge fmt        # format
```

### Deploy

```bash
# Local: start a node, then deploy against it
anvil
forge script script/Deploy.s.sol --fork-url http://localhost:8545 --broadcast

# Testnet (e.g. Holesky): set an RPC + a funded key
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
```

`Deploy.s.sol` deploys the full stack (Mock oracle, both debt tokens, aToken, interest model, fee
vault, then `LendingPool`) and wires `setPool(...)` on each token. Swap `MockPriceOracle` for
`ChainlinkPriceOracle` (with a real feed address) before any non-test deployment.

## Project layout

```
src/            the 14 protocol contracts (+ src/interfaces/AggregatorV3Interface.sol, vendored)
test/           LendingPool.t.sol — full lifecycle tests using vm.deal/prank/warp/expectRevert
script/         Deploy.s.sol — deploy + wire the whole stack
lib/            forge-std, openzeppelin-contracts (v5.0.2) — git submodules
foundry.toml    solc 0.8.28, remappings, optimizer
```

OpenZeppelin imports use the real `@openzeppelin/contracts` package (remapped to `lib/`), and the
single Chainlink interface is vendored under `src/interfaces/` so the project is self-contained.

## Known issues

These are real defects in the contracts, kept for study. The test suite encodes each as a spec.

1. **`repayLoan()` always reverts (critical).** It does `payable(address(this)).call{value:...}("")`
   — calling the pool itself with empty calldata — but `LendingPool` has no `receive()`/`fallback()`,
   so the call returns `false` and `require(ok2, "Lender interest failed")` reverts. Borrowers can
   never repay or get collateral back. Fix: delete the self-call (the ETH is already in the pool) or
   add `receive() external payable {}`.
2. **`liquidate()` gives all collateral away for free.** The liquidator never repays the debt and the
   debt token is never burned — unlike a real protocol where the liquidator repays debt for collateral + bonus.
3. **`totalOutstandingDebt()` reads `userLoans[msg.sender]`.** Called inside `borrow()`, so it only
   sums the borrower's own debt, not pool-wide utilization — the variable rate is computed on wrong input.
4. **Lender interest is never credited to the index.** Even ignoring bug #1, repaid interest would
   stay as raw pool ETH, disconnected from the `aToken` liquidity index that represents lender yield.
5. **Missing access control.** `MockPriceOracle.setEthPrice`, `PriceOracle.setPrice`, and
   `CollateralManager.setPool` (set-once only) have no owner check.
6. **Unit mismatch in the collateral check** and **price-independent** under-collateralization
   (`ethPrice` cancels out in `Utils.isUnderCollateralized`).
7. **Inconsistent ETH transfers** (`.transfer` in `withdraw`, `.call` elsewhere) and no `ReentrancyGuard`.

## Original Holesky deployment

The source project was deployed to the **Holesky testnet (chainId 17000)** from Remix. Addresses
(per the original deploy records — not redeployed by this Foundry repo):

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

Ported from a Remix IDE workspace export (contracts authored with Vietnamese inline comments, kept
verbatim). MIT licensed (see SPDX headers).
