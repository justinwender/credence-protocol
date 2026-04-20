# Credence Protocol -- Technical Architecture

## System Overview

Credence is a four-layer system. Data flows left to right, from raw blockchain history to user-facing lending decisions.

```
                          LAYER 1                    LAYER 2                    LAYER 3                 LAYER 4
                    Data & Feature Eng.          Smart Contracts           Scoring Pipeline            Frontend

                    +------------------+
                    | Allium Explorer  |
                    | SQL Warehouse    |
                    |                  |
  BSC (Venus)  --> | Query A: BSC     |--+
  Ethereum     --> |   lending +      |  |    +-------------------+    +------------------+    +------------------+
  Arbitrum     --> |   balances +     |  +--> |                   |    |                  |    |                  |
  Polygon      --> |   activity       |  |    | CreditOracle      |    | FastAPI          |    | React + Vite     |
  Optimism     --> |                  |  |    |   onchain scores  |    |   POST /score    |    |   wallet search  |
                   | Query B: cross-  |--+    |   composite math  |<---|   model infer.   |    |   score gauge    |
                   |   chain tx +     |       |   historical IDs  |    |   push to chain  |--->|   factor table   |
                   |   DEX + bridge   |       |                   |    |                  |    |   attestation    |
                   +------------------+       +--------+----------+    +------------------+    |   lending        |
                                                       |                                      |                  |
                   +------------------+       +--------v----------+                           +--------+---------+
                   | Logistic Regr.   |       | Attestation       |                                    |
                   |   10 features    |       |   Registry        |<------- admin sets FICO ----------+
                   |   24 one-hot     |       |   identity hash   |         attestations       (MetaMask tx)
                   |   AUC 0.8182     |       |   Sybil resist.   |
                   +------------------+       +-------------------+
                                              |                   |
                                              | LendingPool       |<------- deposit/borrow/repay -----+
                                              |   collateral      |         (ethers.js v6)      (MetaMask tx)
                                              |   curve 75-150%   |
                                              +-------------------+

                                              All on BSC Testnet (chain ID 97)
```

Data flows:
1. Allium SQL warehouse provides raw blockchain data from 5 chains
2. The scoring pipeline runs two concurrent SQL queries, extracts 10 features, runs the frozen model, and pushes the resulting score to CreditOracle via web3.py
3. CreditOracle reads attestation status from OffchainAttestationRegistry and computes a composite score on-read
4. LendingPool calls CreditOracle to determine collateral requirements for each borrower
5. The frontend reads composite scores and collateral ratios from the contracts, and displays factor breakdowns from the API response


## Layer 1: Data and Feature Engineering

The model was trained on 115,687 Venus Protocol borrowers on BSC, labeled by a binary question: has this wallet ever been liquidated on Venus? Venus was the only label source. Other BNB lending protocols (Radiant, Alpaca) use different liquidation mechanics, and mixing them would have introduced label noise.

Features come from BSC and four crosschain networks (Ethereum, Arbitrum, Polygon, Optimism), spanning five categories:

| Category | Features | Source |
|---|---|---|
| Lending behavior | Borrowing protocol activity (days), Repayment consistency ratio, Loan repayment count, Distinct assets borrowed | `bsc.lending.loans`, `bsc.lending.repayments` |
| Financial profile | Portfolio value (USD), Stablecoin allocation, Recent accumulation trend | `bsc.assets.fungible_balances_latest`, `crosschain.assets.transfers` |
| Crosschain breadth | Cross-chain transaction volume, Cross-chain DEX activity, Blockchain networks used, Cross-chain bridge experience | `crosschain.dex.trades`, `crosschain.bridges.transfers`, `<chain>.raw.transactions` |

The model is a FICO-style scorecard built on L2-regularized logistic regression (C=1.0, balanced class weights, 5-fold stratified CV). Each continuous feature is binned into 3-5 discrete buckets, then one-hot encoded with the lowest-risk reference bin dropped. This produces 24 binary columns from 10 raw features. The output is P(not liquidated), scaled to a 0-100 credit score.

Performance: AUC 0.8182, precision 0.9508, recall 0.7208.

The dominant feature is Borrowing protocol activity (days), measuring how many days a wallet has had any Venus lending activity. Its coefficients are the largest in the model: -0.80 for 2-4 days, -1.05 for 5-14 days, -1.23 for 15+ days. The reference bin (1 day, the safest) captures wallets with minimal lending exposure. This creates the thin-file dynamic discussed in the composite score section below.

The model was frozen on 4/16 and will not be retrained prior to hackathon submission.


## Layer 2: Smart Contracts

Three Solidity contracts deployed on BSC Testnet (chain ID 97), built with Foundry, verified on BscScan.

| Contract | Address | Purpose |
|---|---|---|
| OffchainAttestationRegistry | `0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0` | Stores FICO attestations, manages persistent credit identity |
| CreditOracle | `0x16253605BEef191024C950E00D829E0D410637B7` | Stores onchain scores, computes composite scores on-read |
| LendingPool | `0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA` | Deposit/borrow/repay with score-based collateral requirements |

### OffchainAttestationRegistry

Simulates a ZK attestation layer. In the demo, an admin wallet sets attestations directly. In production, a ZK verifier contract (Brevis or Primus) would call `setAttestation` after validating proofs derived from offchain credit bureau data.

Each attestation carries a `bytes32 identityHash`. This hash is deterministically derived from the ZK proof, meaning the same offchain identity always produces the same hash regardless of which wallet submits it. The registry tracks three mappings for Sybil resistance:

- `_historicalOnchainScores[identityHash]`: the persistent onchain score for this identity, surviving wallet rebinding
- `_identityToCurrentWallet[identityHash]`: which wallet currently holds this identity
- `_walletToIdentity[address]`: reverse lookup

When an attestation is set with an identityHash already bound to a different wallet, the registry performs a rebind: clears the old wallet's attestation, preserves the historical score, and binds the identity to the new wallet. This prevents users from escaping their credit history by creating fresh wallets.

The CreditOracle (not the owner) is the only address authorized to call `updateHistoricalScore`, keeping the persistent record in sync. The oracle address is set once via `setCreditOracle` and is immutable after that.

### CreditOracle

Stores per-wallet onchain scores pushed by the scoring pipeline and computes composite scores on-read by combining the onchain score with attestation data from the registry.

The composite uses asymmetric math reflecting the protocol's core thesis:

**Without attestation** (onchain only, thin-file cap):
```
compositeScore = (onchainScore * onchainOnlyMultiplier) / 100
```
Default `onchainOnlyMultiplier = 50`. Maximum composite = 50, which maps to roughly 120% collateral. A high onchain score from minimal activity (the thin-file problem) cannot unlock undercollateralized terms on its own.

**With attestation** (offchain baseline + onchain boost):
```
baseline = (offchainScore * offchainBaselineMultiplier) / 100
boost = (onchainScore * onchainBoostMultiplier) / 100
compositeScore = min(100, baseline + boost)
```
Defaults: `offchainBaselineMultiplier = 70`, `onchainBoostMultiplier = 40`.

All four multipliers are configurable `uint8` state variables, admin-settable.

The FICO-to-0-100 mapping is linear: `mapFicoToZero100` maps FICO 300-850 to 0-100. FICO 575 maps to 50, FICO 850 maps to 100.

When a wallet has an attestation but no onchain score of its own (e.g., a fresh wallet), the oracle checks whether the registry has a non-zero historical score for that identity and uses it. This is the mechanism that makes wallet rebinding carry forward credit history rather than granting a clean slate.

### LendingPool

Accepts tBNB deposits, allows borrowing against deposited collateral, and enforces a piecewise-linear collateral curve based on the borrower's composite score from the oracle:

| Composite Score | Collateral Ratio |
|---|---|
| 0-20 | 150% (flat) |
| 20-50 | 150% to 120% (linear) |
| 50-70 | 120% to 100% (linear) |
| 70-85 | 100% to 85% (linear) |
| 85-100 | 85% to 75% (linear) |

Protected by `ReentrancyGuard` on borrow/repay and `onlyOwner` on admin functions. The pool reads composite scores via `oracle.getCompositeScore(wallet)` and has no awareness of identity persistence, attestations, or the scoring model.


## Layer 3: Scoring Pipeline

A FastAPI server (`pipeline/api.py`) exposing one endpoint: `POST /score`.

The request body is `{"address": "0x..."}`. The response includes the credit score (0-100), factor breakdown with display names and coefficients, composite score from the oracle, collateral ratio from the lending pool, the push transaction hash, data source indicator, and chain count.

### Tiered Data Sources

The pipeline degrades gracefully across three tiers:

| Tier | Source | Latency | When Used |
|---|---|---|---|
| 0 (Live) | Allium Explorer SQL API | ~90 seconds | `ALLIUM_API_KEY` is set, queries succeed |
| 1 (Cached) | `demo_wallets.json` (real wallet features captured during development) | Instant | API key missing or query fails, wallet is in cache |
| 2 (Synthetic) | Deterministic features generated from SHA-256 of the address | Instant | Fallback for any unknown wallet |

The model runs on every request regardless of data source. The `data_source` field in the response ("live", "cached", or "synthetic") tells the frontend exactly what happened. The pipeline never silently degrades.

### Query Architecture

Two SQL queries run concurrently via `ThreadPoolExecutor`:

- Query A (BSC lending): Venus borrow/repay events, lending active days, borrow-repay ratio, unique borrow tokens, current balances, stablecoin ratio, 90-day net flow. This query must succeed for a live score.
- Query B (crosschain): Transaction counts, DEX trades, bridge usage, and chain count across Ethereum, Arbitrum, Polygon, and Optimism. If this query fails, crosschain features default to zero and the response shows "BNB Chain only (crosschain data unavailable)".

Query B starts with a 3-second delay to avoid back-to-back Allium rate limit hits.

### Contract Interaction

After model inference, the pipeline pushes the score to `CreditOracle.setOnchainScore(address, score, chainsUsed)` using web3.py with the deployer's private key. It then reads back the composite score and queries the lending pool for the collateral ratio.

### Activity Tier Adjustments

After model inference and before pushing to the CreditOracle, the pipeline classifies the wallet's activity level and applies a score adjustment. The model produces high scores for wallets with no lending history (zero exposure = zero liquidation risk), but this is misleading as a creditworthiness signal. The adjustment corrects for the gap between "safe because never exposed" and "safe because responsibly managed":

- No onchain activity: score = 0, no contract push
- No lending history (onchain activity but no Venus events): score scaled by 0.6x
- Thin lending history (< 2 active days): score scaled by 0.8x
- Full history (2+ active days): no adjustment

### Pre-Scored Demo Wallets

Five wallets from the training data are pre-scored with full cached API responses in `pipeline/demo_wallets.json`. The backend checks this cache before running the live pipeline. Demo wallet chips on the frontend homepage load these cached results instantly, enabling judges to compare diverse credit profiles (liquidated borrower, thin-file wallet, crosschain power user, strong lending history) without waiting for live queries. Any address typed into the search bar bypasses the cache and runs the full live pipeline.

### Real-Time Progress via SSE

The `/score/stream` endpoint returns server-sent events as each pipeline stage completes. The frontend renders a live network map showing five blockchain nodes (BSC, Ethereum, Arbitrum, Polygon, Optimism) that light up with their brand colors as data arrives. Progress events are real backend milestones (bsc_done, crosschain_done, model_done, push_done), not simulated timers.

### Rate Limiting

In-memory rate limiting (hackathon-grade): 20 requests per hour per IP, 100 requests per day globally.


## Layer 4: Frontend

React + Vite + Tailwind CSS, with ethers.js v6 for contract reads and Web3Modal for wallet connection. Supports MetaMask, WalletConnect, Coinbase Wallet, and any EIP-6963 compatible wallet.

### User Flow

1. Wallet search: enter an address (or ENS name, resolved via ethers.js) and submit. A 4-step progress indicator runs during scoring: "Querying blockchains" then "Running credit model" then "Pushing to oracle" then "Complete".
2. Score dashboard: the composite score gauge is the hero element. Below it: onchain score, attestation status, collateral ratio, and a credit tier badge (Subprime / Standard / Improved / Prime / Premium).
3. Factor breakdown: a table listing each of the 10 features with its display name (from `feature_config.json`), the wallet's bin, the coefficient, and whether it's the reference bin.
4. Attestation simulator: admin-only panel to submit a FICO attestation with an identity hash label. Sends a transaction via MetaMask to `OffchainAttestationRegistry.setAttestation`.
5. Lending interface: deposit tBNB, borrow against collateral at the score-determined ratio, repay loans. Requires wallet connection.


## Collateral Curve Calibration

The value proposition verification matrix. Each cell shows the composite score and the resulting collateral ratio.

Onchain scores are the raw model output before the composite cap. FICO scores are mapped linearly to 0-100 (FICO 300 = 0, FICO 850 = 100).

| | No FICO | FICO 500 (36) | FICO 650 (64) | FICO 780 (87) | FICO 850 (100) |
|---|---|---|---|---|---|
| No history (0) | 0, 150% | 25, 148% | 45, 125% | 61, 110% | 70, 100% |
| Weak onchain (20) | 10, 150% | 35, 140% | 53, 117% | 69, 101% | 78, 95% |
| Median onchain (50) | 25, 148% | 45, 125% | 65, 108% | 81, 93% | 90, 82% |
| Strong onchain (80) | 40, 130% | 57, 115% | 77, 95% | 93, 81% | 100, 75% |
| Max onchain (100) | 50, 120% | 65, 108% | 85, 85% | 100, 75% | 100, 75% |

Reading the matrix:
- Top-left (no data at all): 150% collateral, standard overcollateralized DeFi
- Bottom-left column (onchain only): the cap at 50 keeps collateral at or above 120%, even for a perfect onchain score
- Top-right (FICO 850, no onchain): 70 composite, 100% collateral, competitive with bank lending
- Bottom-right (strong both): 100 composite, 75% collateral, genuinely undercollateralized, better than a bank can offer

The thesis in one row: a wallet with onchain score 80 goes from 130% collateral (no FICO) to 95% (FICO 650) to 75% (FICO 850). The offchain attestation is what unlocks sub-100% terms.


## Data Flow: Scoring a Single Wallet

A step-by-step trace from user action to dashboard update.

1. User enters `0xd60b920cdf6a46a2643753322ada8fdbad0f0157` in the frontend search bar and clicks Score.

2. Frontend sends `POST http://localhost:8000/score` with body `{"address": "0xd60b..."}`.

3. The API validates the address format, checks rate limits, and determines the data source tier.

4. If Tier 0 (live): two SQL queries are submitted to Allium Explorer API concurrently.
   - Query A extracts BSC lending features: 7 columns (lending_active_days, borrow_repay_ratio, repay_count, unique_borrow_tokens, current_total_usd, stablecoin_ratio, net_flow_usd_90d).
   - Query B extracts crosschain features: 4 columns (crosschain_total_tx_count, crosschain_dex_trade_count, chains_active_on, has_used_bridge).
   - Each query goes through create, run-async, poll loop (checking every 5 seconds, timeout 120 seconds), and fetch results.

5. The 10 raw features (or 11 including net_flow_usd_90d, which is converted to the boolean net_flow_direction) are passed to `model/score.py`.

6. `score.py` bins each continuous feature according to the edges in `feature_config.json`, one-hot encodes, drops reference bins, standardizes using stored scaler parameters, and runs the frozen logistic regression. Output: P(not liquidated) scaled to 0-100 integer credit score. For this wallet: score 44.

7. The pipeline calls `CreditOracle.setOnchainScore("0xd60b...", 44, 5)` via web3.py. This stores the score and, if the wallet has an attestation, also updates the historical score in the registry.

8. The pipeline reads back the composite score via `CreditOracle.getCompositeScore("0xd60b...")`. With no attestation: composite = 44 * 50 / 100 = 22.

9. The pipeline reads the collateral ratio from `LendingPool.getBorrowerCollateralRatioBps("0xd60b...")`. Composite 22 falls in the 20-50 band: collateral = 150% - (22-20)/(50-20) * (150%-120%) = 148%.

10. The API returns a JSON response containing: credit_score 44, composite_score 22, collateral_ratio_bps 14800, chains_used 5, data_source "live", factor_breakdown (10 items with display names and coefficients), and the transaction hash.

11. The frontend receives the response, animates the score gauge to 44 (amber), displays composite 22 with "Improved" badge, shows 148% collateral ratio, and renders the factor breakdown table with display names like "Borrowing protocol activity (days)" instead of internal variable names.

12. If the user then submits a FICO 780 attestation via the attestation simulator, the frontend sends a MetaMask transaction to `OffchainAttestationRegistry.setAttestation`. On confirmation, the frontend re-reads the composite score from the oracle: composite = min(100, 87*70/100 + 44*40/100) = min(100, 60+17) = 77. The gauge jumps to green, collateral drops to about 95%, and the badge updates to "Prime".
