# Off-chain USD/VND rate updater

No decentralized oracle carries the Vietnamese Dong (VND is state-managed and capital-controlled, with
no deep arbitraged market for an oracle to track). So the v2 protocol's USD→VND conversion is an
**admin-set rate** on `PriceOracleRouter`, and this keeper is the bridge: it reads the live mid-market
rate from **Google Finance** and writes it on-chain via `setUsdVndRate()`.

> In production you'd replace this trusted keeper with a **DIA custom feed** or a **Chainlink Functions**
> job (decentralized off-chain compute). The on-chain interface (`setUsdVndRate`) stays the same.

## Run

```bash
cd offchain
npm install

# configure (env vars or an offchain/.env loaded by your shell)
export RPC_URL=https://sepolia.drpc.org
export ORACLE_ADDRESS=0x...            # the deployed PriceOracleRouter
export UPDATER_PRIVATE_KEY=0x...       # must be the router's `updater` (or owner); use a testnet key

node update-vnd-rate.mjs               # update once
node update-vnd-rate.mjs --watch 300   # update every 5 minutes
```

Schedule it with cron (Linux/macOS) or Task Scheduler (Windows) for periodic updates, or run `--watch`.

## How it gets the "Google" rate

1. Fetches `https://www.google.com/finance/quote/USD-VND` and parses the embedded `data-last-price`.
2. Falls back to the free `open.er-api.com` mid-market rate if Google's page shape changes.

The rate (VND per 1 USD, e.g. 25,400) is scaled to 1e18 and stored as `usdVndRate`.
