# solidity-p2p-lending

An **Aave-style, over-collateralized peer-to-pool lending protocol**, written in Solidity as a learning
project and ported to **Foundry**. The **loan asset is VNDD**, a stablecoin pegged to the Vietnamese
Dong (VND): lenders supply VNDD and receive an interest-bearing receipt token (`aVND`); borrowers post
**ETH collateral**, borrow **VNDD** at a fixed or floating rate, receive a non-transferable debt token,
and repay with interest. Loans can be liquidated when overdue **or** when the ETH/VND price falls far
enough that the collateral no longer covers the debt.

> ⚠️ **Educational code — not audited, do NOT use with real funds.** It started from a Remix export
> with several serious bugs; those have been fixed (see [What was fixed](#what-was-fixed)). The VNDD
> "peg" is purely nominal (no reserves/redemption) — see [Design notes](#design-notes--remaining-simplifications).

## Architecture

| Contract | Responsibility |
|---|---|
| `LendingPool.sol` | Core entry point: `deposit / withdraw / borrow / repayLoan / liquidate`. Inherits `LoanManager` + `ReentrancyGuard`. Tracks pool-wide `totalBorrowed`. |
| `VNDStablecoin.sol` | The loan asset — a VND-pegged ERC-20 (`VNDD`, 18 decimals). Owner `mint` + open `faucet()` for test funds. |
| `LoanManager.sol` | Loan storage: the `Loan` struct, `RateMode` enum, and `userLoans` mapping. |
| `InterestRateModel.sol` | Aave-style kinked utilization curve for variable-rate loans. |
| `Utils.sol` | Library: `isOverdue`, `isUnderCollateralized` (120% threshold; values ETH collateral against VND debt). |
| `aToken.sol` | Lender receipt (`aVND`); scaled-balance model. Liquidity index rises only on real interest (`accrueToLenders`). |
| `DebtToken.sol` | Base non-transferable debt token (mint on borrow, burn on repay/liquidate). |
| `StableDebtToken.sol` / `VariableDebtToken.sol` | Fixed-rate (`sdVND`) and floating-rate (`vdVND`) debt tokens. |
| `IPriceOracle.sol` | Oracle interface (`getLatestEthPrice`). |
| `MockPriceOracle.sol` | Owner-settable ETH price **in VND**, used by `LendingPool` for testing. |
| `ChainlinkPriceOracle.sol` | Production oracle reading a Chainlink feed (would need an ETH/VND source). |
| `PriceOracle.sol` | Older owner-settable mock (superseded by `MockPriceOracle`). |
| `ProtocolFeeVault.sol` | Collects the protocol's fee + late-penalty share **in VNDD**; owner can withdraw. |

### Lifecycle

```
Lender   approve(VNDD) + deposit(amount) ─► aVND minted ─► withdraw() burns aVND, redeems VNDD + accrued yield
Borrower borrow(amount, mode, days){value: ETH} ─► ETH collateral locked (≥200% in VND), debt token minted, VNDD sent
         approve(VNDD) + repayLoan(i) ─► debt burned, interest split (protocol vs lenders), ETH collateral returned
Liquidator approve(VNDD) + liquidate() ─► if overdue OR under-collateralized: repay VNDD principal, seize ETH, burn debt
```

ETH is **collateral only** — it is never lent out. VNDD is the unit of account for liquidity, debt,
interest, and fees.

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`).

```bash
git clone --recursive <repo-url>   # submodules: forge-std + OpenZeppelin
cd solidity-p2p-lending

forge build      # compile
forge test       # run the suite (21 tests)
forge test -vvv  # with traces
```

## Deploying & where to host

A smart contract is "hosted" by **deploying it to a blockchain**. Network config lives in
`foundry.toml` (`[rpc_endpoints]` + `[etherscan]`) and reads secrets from `.env` (see `.env.example`).
`Deploy.s.sol` deploys the full stack, wires `setPool(...)` on each token, mints the deployer some
VNDD, and seeds the pool with starting liquidity so borrowing works immediately.

```bash
cp .env.example .env    # fill in an RPC URL, a funded deployer key, an Etherscan key

# 1) Local (free, instant, throwaway) — anvil prints 10 funded test accounts + keys
anvil
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast \
  --private-key <a key anvil printed>

# 2) Public testnet — Sepolia (recommended for this project). Verifies on Etherscan.
cast wallet import deployer --interactive            # store your key encrypted (once)
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify --account deployer
```

**Swap `MockPriceOracle`** for a real ETH/VND price source before any non-test deployment.

### Where to host — recommendation (mid-2026)

| Target | Use for | Notes |
|---|---|---|
| **anvil** (local) | dev + tests | instant, free |
| **Sepolia** ✅ | testing this build publicly | best tooling + faucets + Etherscan. ⚠️ EOL ~30 Sep 2026 |
| **Hoodi** | a longer-lived testnet | open validator set; lives to ~2028 |
| **Base / Arbitrum** (L2 mainnet) | a *real* product | cheap gas vs L1 — **only after a professional audit** |
| **Ethereum L1 mainnet** | — | avoid: costly, and this code is unaudited |

> ⚠️ This is unaudited learning code — **deploy to a testnet, never mainnet with real value.** Get test
> ETH from a faucet (Alchemy / PoW for Sepolia), and test VNDD from `VNDStablecoin.faucet()`. The
> **frontend** dApp (`frontend/index.html`) is hosted on **GitHub Pages**; it only needs the deployed
> address + ABI.

## What was fixed

The original Remix export had seven documented issues. All are addressed:

1. **`repayLoan()` always reverted (critical).** It called the pool itself with empty calldata with no
   `receive()`/`fallback()`. **Fix:** removed the self-call — the lender's funds stay in the pool and
   are credited via the liquidity index.
2. **`liquidate()` gave collateral away for free.** **Fix:** the liquidator must repay the outstanding
   principal (now in VNDD); the debt token is burned and the principal replenishes pool liquidity.
3. **`totalOutstandingDebt()` only saw `msg.sender`'s loans.** **Fix:** a pool-wide `totalBorrowed`
   state variable, updated on borrow/repay/liquidate, now drives utilization.
4. **Lender interest was never credited.** **Fix:** `aToken.accrueToLenders()` raises the liquidity
   index from *real* repaid interest, and the time-based (unbacked) accrual was removed.
5. **Open setters.** **Fix:** `MockPriceOracle.setEthPrice` and `PriceOracle.setPrice` are `onlyOwner`.
6. **Unit mismatch in the collateral check.** **Fix:** the borrow check values the ETH collateral in
   VND against the VND debt and enforces a true 200% ratio.
7. **Inconsistent transfers / no reentrancy guard.** **Fix:** ETH sends use `.call` + a success check,
   ERC-20 moves check their return value, entrypoints are `nonReentrant` and follow
   checks-effects-interactions.

The dead, duplicated `CollateralManager.sol` was removed; `LendingPool.liquidate` is the canonical path.

## VND stablecoin version — what changed vs the ETH build

This branch makes the **loan asset a VND-pegged stablecoin** instead of native ETH:

- **VNDD is the loan unit.** Lenders `approve` + `deposit` VNDD (no longer `payable`); borrowers receive
  VNDD; repay and liquidation are paid in VNDD via `transferFrom` (so the borrower/liquidator `approve`
  the pool first). Because repay pulls the *exact* amount owed, the old overpayment-refund path is gone.
- **ETH is collateral only.** It is sent as `msg.value` on `borrow` and returned on repay/liquidate.
- **The oracle now matters.** Collateral (ETH) and debt (VND) are different assets, so the ETH/VND
  price no longer cancels in the math. A large enough price drop pushes a loan under water and makes it
  **liquidatable before its due date** — see `test_Liquidate_WhenUnderCollateralizedByPriceDrop`. In the
  old ETH/ETH design this check was price-invariant and could never trip; *overdue* was the only trigger.

## Design notes & remaining simplifications

- **The VNDD peg is nominal.** `VNDStablecoin` is a plain mintable ERC-20 with an open faucet — there is
  no reserve, redemption, or peg-defence mechanism. A real VND stablecoin would need off-chain fiat
  backing or on-chain over-collateralization (à la DAI). The "1 VNDD = 1 VND" peg here lives only in the
  oracle price.
- **Liquidation forgives accrued interest** (liquidator repays principal only) for simplicity.
- **Lender yield is real-only:** lenders earn solely from borrower interest paid into the pool, not from
  the passage of time.
- **Utilization uses available (not total) liquidity** as the denominator, mirroring the original model.

## Live deployment (Sepolia · chainId 11155111)

🔗 **Live dApp:** https://danganhtu01.github.io/solidity-p2p-lending/

| Contract | Address |
|---|---|
| **LendingPool** | [`0x6F190e133FcCD29777ee85E39a7104109561F28D`](https://sepolia.etherscan.io/address/0x6F190e133FcCD29777ee85E39a7104109561F28D) |
| **VNDStablecoin (VNDD)** | [`0xb30FD05657919A083b4bfE059689EE3120C0b940`](https://sepolia.etherscan.io/address/0xb30FD05657919A083b4bfE059689EE3120C0b940) |
| aToken (aVND) | [`0xC57f573A34E9D28652B3f789e5bBa48ec2A21b70`](https://sepolia.etherscan.io/address/0xC57f573A34E9D28652B3f789e5bBa48ec2A21b70) |
| MockPriceOracle | [`0x70f31EC1A40C4dAC118512Edb5023B9eeCC17b99`](https://sepolia.etherscan.io/address/0x70f31EC1A40C4dAC118512Edb5023B9eeCC17b99) |
| StableDebtToken (sdVND) | [`0xff633c37e59E71fA1b6dFa74c0e646556D284f2B`](https://sepolia.etherscan.io/address/0xff633c37e59E71fA1b6dFa74c0e646556D284f2B) |
| VariableDebtToken (vdVND) | [`0x704094249E4A0401e67695b4E035741A28eA427C`](https://sepolia.etherscan.io/address/0x704094249E4A0401e67695b4E035741A28eA427C) |
| InterestRateModel | [`0xDa607da91f5EA397DA14ACB27D56074dd7431BCF`](https://sepolia.etherscan.io/address/0xDa607da91f5EA397DA14ACB27D56074dd7431BCF) |
| ProtocolFeeVault | [`0xaD8cF6Dc87D6300d879B5001F5E1bBb3eDfdce93`](https://sepolia.etherscan.io/address/0xaD8cF6Dc87D6300d879B5001F5E1bBb3eDfdce93) |

The pool launched with **1,000,000,000 VNDD** of seeded liquidity and the oracle at **70,000,000 VND/ETH**.
To try it: grab Sepolia ETH from a faucet, click **Get test VNDD** in the dApp, then lend or borrow.

## v2 — multi-asset protocol (`src/v2/`)

v2 generalizes the single-pair v1 into a **multi-collateral, multi-debt** protocol and makes VNDD a
**real over-collateralized stablecoin (DAI-style)**. It runs alongside v1.

**Four pairs** — two collaterals × two debt assets, as isolated positions:

| | borrow **VNDD** (minted, DAI-style) | borrow **USDC** (from a supplied pool, Aave-style) |
|---|---|---|
| lock **ETH** (WETH) | ETH → VNDD | ETH → USDC |
| lock **SOL** (wSOL) | SOL → VNDD | SOL → USDC |

- **VNDD** is **minted** against collateral and **burned** on repay — every VNDD is backed by a
  live collateralized position (`VNDStablecoinV2` grants the protocol a minter role).
- **USDC** can't be minted (it's Circle's), so it's **borrowed from a pool** that USDC suppliers fund
  and earn interest on.
- Positions support **partial repay**, **borrow-more**, a **health factor**, and **liquidation with a
  bonus + partial seizure** (the borrower keeps any residual collateral).

**Real oracles** (`PriceOracleRouter`): Chainlink **ETH/USD** + **USDC/USD** (push), Pyth **SOL/USD**
(pull — the frontend posts a signed Hermes update before SOL actions), and an admin **USD→VND** rate
fed on-chain by an off-chain **Google Finance** keeper (`offchain/update-vnd-rate.mjs`), because no
decentralized oracle carries the Vietnamese Dong.

| Contract | Responsibility |
|---|---|
| `v2/LendingProtocolV2.sol` | Core: open/borrow/repay/withdraw/liquidate, USDC supply pool, USD health factor. |
| `v2/PriceOracleRouter.sol` | Per-asset price source (Chainlink / Pyth / manual) + USD↔VND. |
| `v2/tokens/VNDStablecoinV2.sol` | VNDD with role-based mint/burn (the vault is a minter). |
| `v2/tokens/MockWETH9.sol` | Wrap real test ETH into WETH collateral. |
| `v2/tokens/MockERC20.sol` | Faucet wSOL (18-dec) + test USDC (6-dec). |
| `v2/interfaces/IPyth.sol` | Minimal vendored Pyth pull-oracle interface. |

Tested by `test/v2/` — **20 unit tests** (all four pairs, liquidation, supplier interest, partial repay,
borrow-more, health factor) **plus a fuzz/invariant suite** asserting the protocol always custodies the
collateral it owes and that USDC supplier claims stay backed by cash + outstanding loans.

Deploy: `forge script script/DeployV2.s.sol --rpc-url sepolia --broadcast --private-key $PRIVATE_KEY --slow`.
Frontend: `frontend/v2.html`. *(v2 Sepolia addresses are added here after deployment.)*

## Original Holesky deployment

The source project (with the bugs above) was deployed to **Holesky (chainId 17000)** from Remix.
⚠️ **Holesky was shut down in September 2025**, so those addresses are historical/dead and have been
superseded by the Sepolia deployment above.

## Origin & license

Ported from a Remix IDE workspace export (Vietnamese inline comments kept). MIT licensed.
