# Allium Explorer SQL Queries — Credence Protocol

## How to Use

1. Open [Allium Explorer](https://app.allium.so) and log in.
2. Run each query **in order** (01 through 06). Query 01 must run first — the others depend on its wallet population.
3. Export each result as CSV.
4. Save each CSV in `data/raw/` with the filename matching the query number:
   - `01_venus_borrower_labels.csv`
   - `02_bsc_activity_features.csv`
   - `03_bsc_lending_features.csv`
   - `04_bsc_defi_features.csv`
   - `05_bsc_financial_features.csv`
   - `06_crosschain_activity_features.csv`
5. Do NOT modify the CSVs. The training pipeline (`model/train.py`) will pick them up from `data/raw/`.

## Query Summary

| # | File | Purpose | Key Tables | Est. Rows | Est. Runtime |
|---|------|---------|------------|-----------|-------------|
| 01 | `01_venus_borrower_labels.sql` | Build labeled dataset: all Venus borrowers + liquidation flag | `bsc.lending.loans`, `bsc.lending.repayments`, `bsc.lending.liquidations` | 10K–100K | < 1 min |
| 02 | `02_bsc_activity_features.sql` | BSC on-chain activity (tx count, wallet age, active days) | `bsc.raw.transactions` | Same as Q01 | 1–10 min |
| 03 | `03_bsc_lending_features.sql` | Venus lending behavior (borrow/repay counts, ratios, duration) | `bsc.lending.loans`, `bsc.lending.repayments` | Same as Q01 | < 1 min |
| 04 | `04_bsc_defi_features.sql` | DeFi sophistication (DEX, bridge, protocol diversity) | `crosschain.dex.trades`, `crosschain.bridges.transfers` | Same as Q01 | 1–5 min |
| 05 | `05_bsc_financial_features.sql` | Financial profile (balances, stablecoin ratio, net flow) | `bsc.assets.fungible_balances_latest`, `crosschain.assets.transfers` | Same as Q01 | 1–5 min |
| 06 | `06_crosschain_activity_features.sql` | Crosschain activity (tx counts on ETH/ARB/POLY/OP, DEX trades) | `ethereum.raw.transactions`, `arbitrum.raw.transactions`, `polygon.raw.transactions`, `optimism.raw.transactions`, `crosschain.dex.trades` | Same as Q01 | 5–30 min |

## Output Schema Reference

### Query 01 — Venus Borrower Labels
| Column | Type | Description |
|--------|------|-------------|
| `borrower_address` | VARCHAR | Wallet address (join key for all other queries) |
| `total_borrows` | INT | Lifetime Venus borrow events |
| `total_repays` | INT | Lifetime Venus repay events |
| `total_liquidations` | INT | Lifetime liquidation count (0 = never liquidated) |
| `was_liquidated` | BOOLEAN | **TARGET LABEL** — TRUE if ever liquidated |
| `first_borrow_ts` | TIMESTAMP | Earliest borrow |
| `last_borrow_ts` | TIMESTAMP | Most recent borrow |
| `total_borrowed_usd` | FLOAT | Lifetime borrowed USD |
| `total_repaid_usd` | FLOAT | Lifetime repaid USD |
| `total_liquidated_usd` | FLOAT | Lifetime liquidated collateral USD |

### Query 02 — BSC Activity Features
| Column | Type | Description |
|--------|------|-------------|
| `wallet_address` | VARCHAR | Join key |
| `bsc_total_tx_count` | INT | Total sent transactions on BSC |
| `bsc_unique_active_days` | INT | Distinct days with >= 1 tx |
| `bsc_avg_tx_per_active_day` | FLOAT | Avg transactions per active day |
| `bsc_wallet_age_days` | INT | Days between first and last tx |
| `bsc_first_tx_ts` | TIMESTAMP | First BSC transaction |
| `bsc_last_tx_ts` | TIMESTAMP | Most recent BSC transaction |
| `bsc_unique_to_addresses` | INT | Distinct addresses interacted with |

### Query 03 — BSC Lending Features
| Column | Type | Description |
|--------|------|-------------|
| `wallet_address` | VARCHAR | Join key |
| `borrow_count` | INT | Total Venus borrow events |
| `repay_count` | INT | Total Venus repay events |
| `borrow_repay_ratio` | FLOAT | repay_count / borrow_count (>1 = positive) |
| `total_borrowed_usd` | FLOAT | Lifetime borrowed USD |
| `total_repaid_usd` | FLOAT | Lifetime repaid USD |
| `avg_borrow_usd` | FLOAT | Average borrow size |
| `max_borrow_usd` | FLOAT | Largest single borrow |
| `unique_borrow_tokens` | INT | Distinct tokens borrowed |
| `unique_markets` | INT | Distinct Venus markets used |
| `avg_loan_duration_days` | FLOAT | Approximate avg loan duration |
| `lending_active_days` | INT | Days with any lending activity |
| `first_lending_ts` | TIMESTAMP | First lending interaction |
| `last_lending_ts` | TIMESTAMP | Most recent lending interaction |

### Query 04 — BSC DeFi Features
| Column | Type | Description |
|--------|------|-------------|
| `wallet_address` | VARCHAR | Join key |
| `has_used_dex` | BOOLEAN | Any DEX trade on BSC |
| `bsc_dex_trade_count` | INT | Total BSC DEX trades |
| `bsc_dex_volume_usd` | FLOAT | Total BSC DEX volume USD |
| `bsc_unique_dex_projects` | INT | Distinct DEX projects used |
| `has_used_bridge` | BOOLEAN | Any bridge transfer |
| `bsc_bridge_tx_count` | INT | Bridge transfer count |
| `protocol_diversity_score` | INT | DeFi categories used (1–3) |

### Query 05 — BSC Financial Features
| Column | Type | Description |
|--------|------|-------------|
| `wallet_address` | VARCHAR | Join key |
| `current_total_usd` | FLOAT | Current portfolio value |
| `current_native_usd` | FLOAT | Current BNB balance USD |
| `current_stablecoin_usd` | FLOAT | Current stablecoin holdings USD |
| `stablecoin_ratio` | FLOAT | Stablecoins as fraction of portfolio |
| `token_diversity` | INT | Distinct tokens held (balance > 0) |
| `net_flow_usd_90d` | FLOAT | Net token flow over 90 days (+ = accumulating) |

### Query 06 — Crosschain Activity Features
| Column | Type | Description |
|--------|------|-------------|
| `wallet_address` | VARCHAR | Join key |
| `chains_active_on` | INT | Non-BSC chains with activity (0–4) |
| `eth_tx_count` | INT | Ethereum tx count |
| `eth_active_days` | INT | Ethereum active days |
| `arbitrum_tx_count` | INT | Arbitrum tx count |
| `arbitrum_active_days` | INT | Arbitrum active days |
| `polygon_tx_count` | INT | Polygon tx count |
| `polygon_active_days` | INT | Polygon active days |
| `optimism_tx_count` | INT | Optimism tx count |
| `optimism_active_days` | INT | Optimism active days |
| `crosschain_total_tx_count` | INT | Sum of all non-BSC tx counts |
| `crosschain_total_active_days` | INT | Sum of all non-BSC active days |
| `crosschain_dex_trade_count` | INT | DEX trades on non-BSC chains |
| `crosschain_dex_volume_usd` | FLOAT | DEX volume on non-BSC chains |

## Troubleshooting

**Query times out:** Queries 02 and 06 scan large raw transaction tables. If they time out:
- Try running during off-peak hours
- For Q06: split into 4 separate queries (one per chain) and merge the CSVs manually
- For Q02: if the Venus borrower set is very large (>50K), we can add a `LIMIT` or sample

**Column name mismatch:** If Allium returns an error about a column name, paste the exact error. The schema was verified from docs as of April 2026 but may have changed.

**Zero rows returned:** The confirmed project name is `venus_finance` (not `venus` or `Venus`). Verified via `SELECT DISTINCT project FROM bsc.lending.loans LIMIT 20`.

**Bridge table schema:** The `crosschain.bridges.transfers` table was documented as a "legacy" table. If it errors, try `crosschain.bridges.bridge_transfers_outbound` instead and flag the issue.
