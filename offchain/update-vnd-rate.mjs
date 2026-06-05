// update-vnd-rate.mjs — route the live USD/VND rate (Google Finance) on-chain.
//
// WHY THIS EXISTS: no decentralized oracle (Chainlink, Pyth, DIA, RedStone) carries the Vietnamese
// Dong, because VND is a state-managed, capital-controlled currency with no deep arbitraged market.
// So the protocol's USD->VND leg is an admin-set value, and THIS script is the bridge: it reads the
// real mid-market rate from Google Finance and writes it to PriceOracleRouter.setUsdVndRate().
// In production you'd replace this trusted keeper with a DIA custom feed or a Chainlink Functions job.
//
// USAGE:
//   cd offchain && npm install
//   set RPC_URL, UPDATER_PRIVATE_KEY, ORACLE_ADDRESS (env vars or offchain/.env), then:
//   node update-vnd-rate.mjs            # update once
//   node update-vnd-rate.mjs --watch 300   # update every 300s
//
// The updater key must be the router's `updater` (or owner). Use a dedicated testnet key.

import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL || "https://sepolia.drpc.org";
const ORACLE_ADDRESS = process.env.ORACLE_ADDRESS;
const PK = process.env.UPDATER_PRIVATE_KEY || process.env.PRIVATE_KEY;

const ORACLE_ABI = [
  "function setUsdVndRate(uint256 rate)",
  "function usdVndRate() view returns (uint256)",
];

/** Fetch USD->VND from Google Finance, falling back to a free FX API. Returns a Number (VND per USD). */
async function fetchUsdVnd() {
  // 1) Google Finance — the page embeds the latest price as data-last-price="25400.0"
  try {
    const res = await fetch("https://www.google.com/finance/quote/USD-VND", {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; vnd-rate-bot/1.0)" },
    });
    const html = await res.text();
    const m = html.match(/data-last-price="([0-9.]+)"/);
    if (m) {
      const rate = parseFloat(m[1]);
      if (rate > 1000) return { rate, source: "Google Finance" };
    }
  } catch (e) {
    console.warn("Google Finance fetch failed, falling back:", e.message);
  }
  // 2) Fallback — open.er-api.com (free, no key), mid-market rate
  const res = await fetch("https://open.er-api.com/v6/latest/USD");
  const json = await res.json();
  const rate = json?.rates?.VND;
  if (!rate || rate < 1000) throw new Error("Could not obtain a USD/VND rate from any source");
  return { rate, source: "open.er-api.com" };
}

async function updateOnce(oracle) {
  const { rate, source } = await fetchUsdVnd();
  // Scale to 1e18: usdVndRate = VND per 1 USD, 1e18-scaled.
  const scaled = ethers.parseUnits(rate.toFixed(6), 18);
  const current = await oracle.usdVndRate();
  console.log(`[${new Date().toISOString()}] ${source}: 1 USD = ${rate} VND  (on-chain now: ${ethers.formatUnits(current, 18)})`);
  const tx = await oracle.setUsdVndRate(scaled);
  console.log("  setUsdVndRate tx:", tx.hash);
  await tx.wait();
  console.log("  ✓ updated to", ethers.formatUnits(scaled, 18), "VND/USD");
}

async function main() {
  if (!ORACLE_ADDRESS) throw new Error("Set ORACLE_ADDRESS (the PriceOracleRouter address)");
  if (!PK) throw new Error("Set UPDATER_PRIVATE_KEY");
  const provider = new ethers.JsonRpcProvider(RPC_URL, undefined, { batchMaxCount: 1, staticNetwork: true });
  const wallet = new ethers.Wallet(PK, provider);
  const oracle = new ethers.Contract(ORACLE_ADDRESS, ORACLE_ABI, wallet);

  const watchIdx = process.argv.indexOf("--watch");
  if (watchIdx !== -1) {
    const secs = parseInt(process.argv[watchIdx + 1] || "300", 10);
    console.log(`Watching: updating USD/VND every ${secs}s. Ctrl+C to stop.`);
    for (;;) {
      try { await updateOnce(oracle); } catch (e) { console.error("update failed:", e.message); }
      await new Promise((r) => setTimeout(r, secs * 1000));
    }
  } else {
    await updateOnce(oracle);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
