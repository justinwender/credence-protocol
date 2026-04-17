# Credence Protocol

Onchain credit scoring + undercollateralized lending protocol on BNB Chain. Hackathon project for **BNB Chain US College Edition** — deadline **April 19, 2026** (DeFi track).

## Elevator Pitch

Credence blends two independent credit signals — onchain wallet behavior (crosschain) and offchain credit attestations (simulated ZKredit) — into a composite credit score that determines collateral requirements on a continuous curve in a BSC-deployed lending pool. The thesis: two independent positive signals reduce risk uncertainty more than either alone, enabling undercollateralized lending without exposing personal data.

## Architecture — 4 Layers

### Layer 1 — Data & Feature Engineering (Python)
- **Training data**: human-executed Allium Explorer SQL queries. Claude writes `.sql` files in `data/queries/`; the user runs them in Explorer, exports CSV, drops into `data/raw/`. Claude never runs bulk Allium SQL.
- **Labels**: liquidation events from Venus Protocol only. Label = "has this wallet ever been liquidated on Venus?" Other BNB lending protocols (Radiant, Alpaca) were considered but walked back — different liquidation mechanics would contaminate label semantics. Revisit only if Venus dataset is too small.
- **Features**: computed from BSC + crosschain (ETH, Arbitrum, Polygon, Optimism). Categories: activity, DeFi sophistication, lending behavior (strongest signal), financial profile, crosschain breadth.
- **Model**: logistic regression. Interpretable coefficients, matches FICO/VantageScore methodology. Output: probability(not liquidated) → scaled 0–100 credit score.
- **Optional refinement**: scorecard-style binned logit — only if base model is frozen first.
- **Freeze after training.** No iteration mid-hackathon.

### Layer 2 — Smart Contracts (Solidity, Foundry, BSC Testnet chainId 97)
Three contracts:
1. **`OffchainAttestationRegistry.sol`** — simulates ZKredit attestation layer. Admin sets attestations for demo; in production, a ZK verifier contract would call `setAttestation` after validating Brevis/Primus proofs.
2. **`CreditOracle.sol`** — stores onchain scores (pushed by scoring pipeline), reads attestations from registry, exposes composite score on-read. Weighting params are configurable state vars (tuned after model trains).
3. **`LendingPool.sol`** — deposit/borrow/repay. Collateral ratio is a continuous function of composite score:
   - Score 0–20 → 150% · 20–50 → 150→120% · 50–70 → 120→100% · 70–85 → 100→85% · 85–100 → 85→75%
   - **These are pre-calibration defaults.** Recalibrate from model output in Phase 3. Contracts store them as configurable params with comments marking them provisional.

**Security scope (hackathon):** Solidity 0.8+, `onlyOwner` on admin functions, `ReentrancyGuard` on borrow/repay, basic input validation. Do NOT spend time on: formal verification, gas optimization, upgradeable proxies, multisig, timelocks. Document these as "production-only" in the hackathon report.

### Layer 3 — Scoring Pipeline (Python, FastAPI)
Live single-wallet scoring. Takes address (or ENS), queries Allium, runs frozen model, pushes score to `CreditOracle`. Endpoint: `POST /score`.

Graceful degradation: BSC query must succeed; crosschain queries are best-effort. Track `chains_used` and surface "BNB only" vs "N-chain history" in the response. **Never silently degrade.**

**Open decision:** Use per-chain Allium Explorer API calls (original plan) vs. new "Allium for Wallets" unified API. Decide during schema discovery by verifying (a) field coverage, (b) doc completeness, (c) plan access. Ask user before committing.

### Layer 4 — Frontend (React + Vite + Tailwind + ethers.js v6)
Single-page app. Design direction: Bloomberg-terminal-meets-fintech. Dark, data-dense, monospaced numerics. Credit score gauge is the hero.

Flow:
1. **Wallet search** (ENS or address) → read-only score dashboard
2. **Connect wallet** → switches to interactive mode
3. **Credit score dashboard**: gauge, factor breakdown, data-completeness indicator, offchain attestation status, composite score, collateral ratio
4. **Attestation simulator**: admin inputs FICO-equivalent attestation → contract call → dashboard live-updates
5. **Lending interface** (connected mode only): borrow/repay against pool

## Project Structure

```
credence-protocol/
├── CLAUDE.md                       # this file
├── README.md
├── .env.example
├── data/
│   ├── queries/                    # .sql files + README
│   ├── raw/                        # Explorer CSV exports (gitignored)
│   └── processed/                  # Cleaned feature matrices (gitignored)
├── model/
│   ├── train.py
│   ├── score.py
│   ├── model.pkl
│   ├── feature_config.json
│   └── validation_report.md
├── contracts/                      # Foundry project
│   ├── src/
│   ├── test/
│   ├── script/Deploy.s.sol
│   └── foundry.toml
├── pipeline/
│   ├── push_score.py
│   ├── api.py                      # FastAPI POST /score
│   ├── config.py
│   └── requirements.txt
├── frontend/                       # Vite + React
│   ├── src/
│   └── package.json
└── docs/
    ├── architecture.md
    ├── pitch_narrative.md
    ├── demo_script.md
    └── hackathon_report.md         # written LAST
```

## Working Methodology — Non-Negotiable Rules

1. **Plan before each layer.** Before data queries, model training, contracts, pipeline, or frontend: write a brief plan, wait for user confirmation.
2. **Checkpoint after each major component.** Present summary; user verifies before proceeding.
3. **No silent assumptions.** When something is ambiguous (schema, parameter, scope), STOP and ask. Never pick a default and push forward.
4. **SQL queries are human-executed.** Claude writes `.sql` files + README; user runs in Explorer; user drops CSVs in `data/raw/`. Claude never executes bulk Allium SQL. The single-wallet scoring pipeline is the only live Allium interaction.
5. **Schema verification before SQL.** Verify exact table paths + column names via Allium docs/MCP before writing queries. No guessing.
6. **Freeze the model after training.** No mid-hackathon iteration.
7. **Graceful degradation on crosschain failures.** BNB data is required; other chains are best-effort with visible degradation indicators.

## Tech Decisions — Locked

- **Smart contracts**: Foundry
- **Target chain**: BSC Testnet (chainId 97), public RPC `https://data-seed-prebsc-1-s1.binance.org:8545/`, fallback QuickNode
- **Contract verification**: BscScan (API key in `.env`)
- **Python**: 3.11+, sklearn/statsmodels for logit, pandas/pyarrow for data, FastAPI for scoring service, web3.py for contract writes
- **Frontend**: Vite + React + Tailwind + ethers.js v6 + recharts
- **Label source**: Venus Protocol liquidations on BSC only (other BNB lending protocols excluded to avoid label contamination)
- **Feature sources**: BSC + Ethereum + Arbitrum + Polygon + Optimism

## Phased Build Plan

Each phase ends at a checkpoint where the user confirms before the next phase starts.

- **Phase 0** ✅ — Setup: CLAUDE.md, initial structure, tech decisions locked.
- **Phase 1** ✅ — Allium schema discovery (via Claude-in-Chrome docs browsing). Confirmed table paths below.
- **Phase 2** ✅ — SQL queries written + executed via Allium Explorer API. All 6 CSVs in `data/raw/` with 115,687 rows each. Venus project name = `venus_finance`.
- **Phase 3** ✅ — FICO-style scorecard model trained and frozen. Final: L2 logit, 10 features → 24 one-hot columns, AUC 0.8182, 0 serious sign flags. Artifacts: `model/model.pkl`, `model/feature_config.json` (includes bin edges, coefficients, display names, scaler params), `model/score.py` (inference), `model/validation_report.md` (coefficient table with display names). DO NOT RETRAIN.
- **Phase 4** ✅ — Smart contracts + tests in Foundry (79 tests, 99.5% line coverage). Deployed + verified on BSC testnet. Demo tx confirmed on-chain (composite 49→99, collateral 121%→75.7%). Addresses in `.env`.
  - **Phase 4 design note — `CreditOracle` composite math (asymmetric: offchain-baseline + onchain-boost)**:
    - The composite uses different logic in each case, reflecting the protocol's value proposition.
    - **Onchain-only (no attestation)** — thin-file cap:
      `compositeScore = (onchainScore * onchainOnlyMultiplier) / 100`
      Default `onchainOnlyMultiplier = 50`. Max composite in this case = 50, maps to ~120% collateral. Onchain alone cannot unlock undercollateralized terms.
    - **With attestation** — offchain baseline, onchain boost:
      `baseline = (offchainScore * offchainBaselineMultiplier) / 100`
      `boost = (onchainScore * onchainBoostMultiplier) / 100`
      `compositeScore = min(100, baseline + boost)`
      Defaults: `offchainBaselineMultiplier = 70`, `onchainBoostMultiplier = 40`.
    - All four multipliers are configurable `uint8` state variables, admin-settable.
    - **Value-prop framing for the contract comment block** (verbatim target for `CreditOracle.sol`):
      * Onchain-only: better-than-standard-DeFi terms (~120% max), but still overcollateralized — a high thin-file score is not equivalent to genuine creditworthiness.
      * Offchain-only (strong FICO): competitive with traditional bank lending, maybe slightly worse (~110% collateral) — verified offchain creditworthiness earns bank-tier terms.
      * Offchain + strong onchain: genuinely better than a bank could offer (undercollateralized, 75–90%) — the onchain signal lifts above the bank baseline.
      * Value proposition: bringing offchain credit data onchain via ZK proofs unlocks undercollateralized lending, which has not yet been solved in DeFi. Two independent verified signals compound; onchain alone is insufficient because a thin onchain file (high score from minimal exposure) is not equivalent to proven creditworthiness.
  - **Phase 4 design note — Persistent credit identity across wallets (Sybil-resistant)**:
    - `OffchainAttestationRegistry` adds a `bytes32 identityHash` field to each attestation. In production, this hash is derived deterministically from the ZK proof (same offchain identity → same hash, regardless of which wallet submits the proof). Admin-set in the demo.
    - Registry tracks three additional mappings:
      * `_historicalOnchainScores: identityHash => uint8` — persistent per-identity onchain score, survives wallet rebinding.
      * `_identityToCurrentWallet: identityHash => address` — which wallet currently holds this identity.
      * `_walletToIdentity: address => identityHash` — reverse lookup.
    - `setAttestation(wallet, attestation)` behavior:
      * If `identityHash` is already bound to a different wallet → **rebinding**: clear the old wallet's attestation, preserve `_historicalOnchainScores[identityHash]`, bind identity to new wallet. Emit `AttestationTransferred(oldWallet, newWallet, identityHash, inheritedScore)`.
      * If `identityHash` is new → first-time attestation, no historical score to inherit.
    - New function `updateHistoricalScore(identityHash, score)` — callable **only by the CreditOracle** (not `onlyOwner`). The Oracle calls this inside `setOnchainScore` whenever the target wallet has an attestation, keeping the persistent record in sync.
    - New view `getHistoricalScore(identityHash) → uint8` read by the Oracle during composite calculation.
    - `CreditOracle.getCompositeScore(wallet)` change: when the wallet has an attestation AND its own `_onchainScores[wallet] == 0` AND registry has a non-zero historical score for its identity → use the historical score as the onchain input. This means a user who was liquidated on wallet A (low score), rebinds their attestation to wallet B (fresh wallet, no score), gets B's composite calculated using A's old score — not a fresh start.
    - `CreditOracle.setOnchainScore(wallet, score, chainsUsed)` change: if the wallet has an attestation, also call `registry.updateHistoricalScore(identityHash, score)` to keep the persistent record current.
    - **Deployment order implication**: Registry deploys first with no oracle address, then Oracle deploys with Registry address, then admin calls `Registry.setCreditOracle(oracleAddr)` once to authorize the Oracle. `setCreditOracle` can only be called when the current value is `address(0)` (one-shot, immutable after).
    - **NOT implemented (production considerations, documented in hackathon report)**:
      * Handling of active loans on the old wallet when attestation transfers (production: force repay, freeze old loan, or transfer debt).
      * Rebinding cooldowns (ZKredit handles at proof layer).
      * Privacy of identity hashes beyond the primitive `bytes32` (production: commit-reveal or Poseidon hashes).
    - **LendingPool is untouched** by this feature — it still reads composite scores via `oracle.getCompositeScore(wallet)`. All identity-persistence logic lives in Registry + Oracle.
    - **Demo beat #4** (after search → attestation → combined): "What if this user creates a new wallet?" Submit attestation for fresh wallet B with the same identity hash as wallet A. Show B's composite inherits A's onchain score. 30-second addition illustrating Sybil resistance.
  - **Phase 4 design note — thin-file problem motivates the cap**:
    - The Phase 3 scorecard's dominant feature is `lending_active_days`. Reference (safest) = [1, 1] — i.e., a single day of lending activity.
    - Mechanical consequence: a wallet that borrowed once, repaid once, and moved on can score ~98 (see `model/examples/ideal_wallet.json`). Its low liquidation risk is real (no ongoing exposure), but its creditworthiness signal is thin.
    - Analogous to a FICO "thin file": high score achieved through minimal activity is not equivalent to a high score earned through extensive, well-managed exposure.
    - The onchain-only composite cap resolves this: raw onchain 98 → capped composite 49 → ~110% collateral. The wallet gets slight benefit over standard DeFi (150%), but can't access undercollateralized terms without offchain attestation proving genuine creditworthiness.
    - Pitch framing: "A thin onchain history can produce a high score because minimal exposure implies minimal risk. But thin-file wallets shouldn't receive institutional-grade lending terms. The offchain attestation is what differentiates 'safe because inexperienced' from 'safe because genuinely creditworthy.' This is why the protocol requires both sources to unlock sub-100% collateral — two independent positive signals reduce uncertainty in ways either signal alone cannot."
    - Include this reasoning as a comment block in `CreditOracle.sol` above `getCompositeScore`.
- **Phase 5** 🚧 — Scoring pipeline (`pipeline/`). API decision: Explorer SQL (Wallet API lacks Venus lending event history for dominant features). Two concurrent SQL queries per wallet (~30s). CHECKPOINT: score a test wallet end-to-end, show output.
- **Phase 6** — Frontend. CHECKPOINT: walk through full demo flow end-to-end.
  - **User-facing feature labels (Phase 6 + Phase 7)**: everywhere a feature name is shown to the user or judge (factor breakdown component, ScoreGauge tooltips, validation report, hackathon report), use the display labels below — NOT the internal variable names. Internal names remain in the code, model artifacts, and `feature_config.json`. Display labels are also stored in `feature_config.json.feature_display_names` so they're the single source of truth.
    - `lending_active_days` → "Borrowing protocol activity (days)"
    - `borrow_repay_ratio` → "Repayment consistency ratio"
    - `repay_count` → "Loan repayment count"
    - `unique_borrow_tokens` → "Distinct assets borrowed"
    - `current_total_usd` → "Portfolio value (USD)"
    - `stablecoin_ratio` → "Stablecoin allocation"
    - `crosschain_total_tx_count` → "Cross-chain transaction volume"
    - `crosschain_dex_trade_count` → "Cross-chain DEX activity"
    - `chains_active_on` → "Blockchain networks used"
    - `has_used_bridge` → "Cross-chain bridge experience"
    - `net_flow_direction` → "Recent accumulation trend"
    - Rationale: "lending" in DeFi terminology typically refers to lending-side supply, but the model measures borrowing behavior — "Borrowing protocol activity" is less ambiguous.
- **Phase 7** — Documentation: architecture, pitch narrative, demo script, hackathon report. CHECKPOINT: final review before submission. (See Phase 6 note above — use display labels, not internal variable names, in all user-facing docs.)
  - **Phase 7 narrative note — Bidirectional credit identity (full vision)**:
    - The identity-persistence mechanism implemented in Phase 4 is a one-directional primitive: offchain identity anchors onchain reputation.
    - The full vision is bidirectional: onchain behavior also feeds back into the offchain credit profile, creating a unified credit record spanning wallets and protocols.
    - Over time, this produces a portable, unforgeable credit identity that:
      * Spans multiple wallets (rebinding preserves the identity's accumulated score)
      * Accumulates reputation across activity (new behavior updates the persistent record)
      * Survives wallet turnover (Sybil attacks don't work — identity anchored to offchain account)
      * Enables true undercollateralized DeFi at scale (track record can't be gamed by creating new wallets)
    - Include this vision in the architecture section of `docs/hackathon_report.md` and frame the submitted demo as the first primitive step toward this picture.
  - **Phase 7 production-considerations note — FICO mapping is linear for the hackathon**:
    - `CreditOracle.mapFicoToZero100` linearly maps FICO 300–850 to 0–100, so 575 (midpoint of range) → 50 and 300 → 0.
    - In practice almost no DeFi borrower has a FICO under ~500, so the bottom third of the mapping is dead space.
    - Production: replace with a nonlinear mapping that concentrates resolution in the 600–800 range where actual lending decisions cluster. A piecewise-linear or sigmoid-shaped mapping would be appropriate.
    - Include this in the "production considerations" section of `docs/hackathon_report.md`.

## Confirmed Allium Table Paths

| Purpose | Table | Key Columns | Filter |
|---|---|---|---|
| Venus liquidation labels | `bsc.lending.liquidations` | `borrower_address`, `project`, `usd_amount`, `block_timestamp` | `project = 'venus_finance'` |
| Venus borrow events | `bsc.lending.loans` | `borrower_address`, `project`, `usd_amount`, `block_timestamp`, `token_address` | `project = 'venus_finance'` |
| Venus repay events | `bsc.lending.repayments` | `borrower_address`, `repayer_address`, `project`, `usd_amount`, `block_timestamp` | `project = 'venus_finance'` |
| Raw transactions (activity) | `<chain>.raw.transactions` | `from_address`, `to_address`, `block_timestamp`, `hash`, `value`, `receipt_status` | Chains: bsc, ethereum, arbitrum, polygon, optimism |
| Token transfers | `crosschain.assets.transfers` | `chain`, `from_address`, `to_address`, `token_address`, `token_type`, `amount`, `usd_amount` | `chain = 'bsc'` etc. |
| Daily balances | `<chain>.assets.fungible_balances_daily` | `address`, `token_address`, `balance`, `usd_balance`, `date` | |
| Latest balances | `<chain>.assets.fungible_balances_latest` | `address`, `token_address`, `balance`, `usd_balance_current` | |
| DEX trades | `crosschain.dex.trades` | `chain`, `transaction_from_address`, `project`, `protocol`, `usd_amount`, `block_timestamp` | `chain = 'bsc'` etc. |
| Bridge transfers | `crosschain.bridges.transfers` | (unified crosschain bridge table) | For `has_used_bridge` feature |
| Wallet 360 | `ethereum.wallet_features.wallet_360` | `wallet_address`, `total_txn_count`, `total_days_active`, etc. | **ETH/Polygon/Base ONLY** — no BSC |

**Notes:**
- Venus is classified as Compound V2 fork in Allium's lending protocol list.
- `crosschain.*` tables have a `chain` column — use for multi-chain queries without per-chain joins.
- Wallet 360 lacks BSC coverage; all BSC features computed from raw/enriched tables.
- Allium Explorer does NOT support `SHOW TABLES` / `DESCRIBE TABLE` metadata queries.

## Open Questions / Active Blockers
- **DECISION (Phase 5)**: Allium Wallet API vs per-chain Explorer API for live scoring — defer to Phase 5.
- **PENDING USER**: BSC testnet wallet creation + `.env` population (needed before Phase 4 deploy).
- **PENDING USER**: BscScan API key (needed for contract verification, Phase 4).
- **PENDING USER**: Allium API key in `.env` (needed before Phase 5 live pipeline).

## Non-Goals (Explicitly Out of Scope)

- Production-grade contract security (audits, timelocks, multisig, upgradeable proxies)
- Gas optimization beyond defaults
- Real ZK proof integration (we simulate via admin attestations; real ZKredit integration is a "production v2" item)
- Liquidation engine / interest rate model / bad debt handling
- KYC/AML compliance
- More than 5 chains for features
- Model iteration after freeze

## Demo Narrative (for pitch)

1. Wallet search → onchain-only score → show ~110% collateral (narrow view of financial life)
2. Add offchain attestation (strong FICO equivalent) → composite jumps, collateral drops to 80–90% range
3. Show wallet with both strong onchain + offchain → compounds to the best terms
4. Show logit coefficient breakdown → interpretability as a regulatory feature, not a bug

## References

- Allium docs: https://docs.allium.so
- Venus Protocol: https://github.com/VenusProtocol/venus-protocol
- BNB Chain Hackathon: US College Edition (deadline 2026-04-19)
