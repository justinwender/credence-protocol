# AI Build Log

This document chronicles how AI (Claude Code, Anthropic) was used at each phase of the Credence Protocol development. For each phase, we note what the AI generated versus what the human decided, designed, or executed externally.

The consistent pattern throughout: AI generates code and proposes designs. Human reviews at checkpoints, makes strategic decisions, executes external steps (Allium queries, wallet setup, deployment configuration), and directs iterative refinement when outputs don't meet the bar.

## Phase 0: Architecture and Planning

**AI did:** Generated the initial CLAUDE.md project plan, proposed the 4-layer architecture (data, contracts, pipeline, frontend), recommended tech stack decisions (Foundry over Hardhat, logistic regression over neural networks, BSC testnet deployment targets).

**Human did:** Provided the complete project specification in the initial prompt. Made all scoping decisions: Venus-only labels (rejected mixing Radiant/Alpaca due to label contamination), 5-chain feature set, FICO-style scorecard methodology, collateral curve breakpoints (marked as provisional). Established the checkpoint methodology that governed every subsequent phase.

**Key decision:** The human chose logistic regression explicitly for regulatory interpretability (ECOA/FCRA alignment), not because the AI recommended it. The AI implemented the choice.

## Phase 1: Schema Discovery

**AI did:** Initially attempted to use the Allium MCP tools for schema discovery, but received 403 errors (account plan limitation). Generated a set of `SHOW TABLES` / `DESCRIBE TABLE` queries for the human to run in Allium Explorer.

**Human did:** Ran the queries in Allium Explorer, discovered that Allium does not support metadata queries (`SHOW TABLES`, `DESCRIBE TABLE`). Reported the failure. Suggested using Claude in Chrome as an alternative.

**AI did:** Drove Chrome browser through docs.allium.so, reading 8 documentation pages to extract exact table paths, column names, and data types. Compiled a confirmed schema map covering BSC raw tables, lending verticals (Venus as Compound V2 fork), crosschain token transfers, DEX trades, bridges, balances, and Wallet 360.

**Key finding:** Wallet 360 (pre-aggregated wallet features) covers only Ethereum, Polygon, and Base, not BSC. All BSC features had to be computed from raw and enriched tables.

## Phase 2: SQL Queries and Data Ingestion

**AI did:** Wrote 6 SQL query files in `data/queries/` with a README documenting each query's purpose, expected schema, and approximate row count. All queries used LEFT JOINs from the Venus borrower population to preserve zero-activity wallets.

**What actually happened (differs from original plan):** The original plan called for the human to run queries manually in Allium Explorer and export CSVs. However, the human's academic plan restricted CSV downloads from the Explorer UI. The AI wrote a Python script (`data/run_queries.py`) that used the Allium Explorer API to submit queries programmatically, bypassing the UI download restriction. The API supported 250,000 rows per query (versus the UI's 10,000 row cap), which allowed us to pull the full 115,687-wallet dataset in single API calls.

**Human did:** Provided the Allium API key. Identified the Venus project name discrepancy (`venus_finance`, not `venus`) when the first query returned zero rows. Ran the diagnostic query (`SELECT DISTINCT project FROM bsc.lending.loans`) to find the correct name.

**Bug caught by human:** The initial query used `project = 'venus'`, which returned empty results. The human ran a diagnostic and identified the correct project name as `venus_finance`. The AI updated all 6 queries.

## Phase 3: Model Training (4 Iterations)

This was the most iterative phase. The model went through 4 training cycles, each with a human checkpoint.

**Iteration 1: Initial logistic regression with continuous features.**
AI trained a standard L2 logit on 23 features (log-transformed continuous, boolean, categorical). AUC 0.8107. Human approved as a baseline but noted multicollinearity: `total_borrowed_usd_log` (+2.12) and `total_repaid_usd_log` (-1.92) had correlated signs that were counterintuitive individually.

**Human decision:** Directed the conversion to a FICO-style scorecard approach. Specified the methodology: bin all continuous features into 3-5 discrete categories, use lowest-risk bin as reference, one-hot encode. The human also specified: drop the collinear borrow/repay USD pair, replace with `total_lending_volume_log`, and present proposed bin edges for approval before retraining.

**Iteration 2: FICO scorecard with binning.**
AI analyzed distributions of all 17 continuous features across the 115,687 wallets, proposed bin edges for each with domain-informed justifications (e.g., wallet age: 0-180, 180-365, 365-1095, 1095+ days). Human reviewed and approved all bin definitions. AUC improved to 0.8451, but 25 coefficient sign flags appeared (non-reference bins with positive coefficients, meaning "this bin appears safer than the reference").

**AI analysis:** Identified the root cause as multicollinearity between overlapping lending-activity features. The total_lending_volume_log feature had all non-reference bins positive (unpitchable), and the borrow_repay_ratio [0,0] bin was +0.88 due to right-censoring in the training data (2,010 wallets that never repaid had 0% liquidation rate because they were recent borrowers, not because never repaying is safe).

**Human decision:** Approved dropping `total_lending_volume_log` (redundant with `lending_active_days` + `repay_count`) and collapsing the `borrow_repay_ratio` [0,0] bin into [0, 0.9] (pooling never-repaid wallets with under-repayers).

**Iteration 3: Post-fix retraining.**
AUC 0.8308, 22 sign flags remaining. The feature cuts resolved the Tier 1 issues but redistributed signal to `borrow_count` (now +0.25 for some bins) and generic activity features.

**Human decision:** Approved dropping 7 additional features where at least one non-reference bin had a materially positive coefficient (>0.10). Kept `crosschain_total_tx_count` and `chains_active_on` despite small positive flips (<0.10) because dropping every crosschain feature would weaken the project's differentiation narrative.

**Iteration 4: Final 10-feature scorecard.**
AI retrained. Then discovered `bsc_wallet_age_days` had become non-monotonic after the correlated features were removed. AI presented three options (drop, keep with caveats, simplify to 2 bins). Human chose to drop it.

Final model: 10 features, 24 one-hot columns, AUC 0.8182, 0 serious sign flags. Every coefficient explainable in one sentence. Model frozen.

**Human decision (post-freeze):** Specified user-facing display names for all 11 features (e.g., `lending_active_days` → "Borrowing protocol activity (days)") to avoid DeFi terminology ambiguity in the frontend and reports.

## Phase 4: Smart Contracts

**AI did:** Scaffolded the Foundry project, installed OpenZeppelin, wrote all three contracts (OffchainAttestationRegistry, CreditOracle, LendingPool) with NatSpec documentation, wrote 79 tests (unit, integration, fuzz), achieved 99.5% line coverage. Deployed all three contracts to BSC testnet and verified on BscScan. Ran a demo transaction confirming composite score transitions (49 → 99) on-chain.

**Human did:** Funded the BSC testnet wallet (from faucet). Provided the Etherscan API key for contract verification. Reviewed compiled interfaces at the checkpoint before tests were written.

**Key design decisions made by human during this phase:**

1. Composite math restructuring: the human rejected the initial symmetric weighted blend (40/60) and specified the asymmetric approach (offchain baseline + onchain boost) to match the value proposition that offchain attestation is the gateway to undercollateralized terms, not just one of two equal inputs.

2. Sybil resistance mechanism: the persistent credit identity system (identityHash, historical score inheritance, wallet rebinding) was conceived during conversation between the human and AI. The human specified the full design including the three storage mappings, the rebinding logic, the one-shot oracle authorization, and the production considerations to document but not implement. This was not in the original project prompt.

3. Thin-file problem framing: the human identified that a high onchain score from minimal activity (1 day, 1 borrow) is analogous to a FICO thin file and should not receive undercollateralized terms. This insight directly motivated the onchain-only composite cap design.

**Bugs caught by tests:** The AI's initial collateral curve implementation had an off-by-one error in the control-point mapping (the interpolation function treated ratios[i] as the value at breakpoints[i-1] instead of using the correct 6-control-point scheme). The unit tests caught this immediately and the AI fixed it before deployment.

## Phase 5: Scoring Pipeline

**AI did:** Built the FastAPI scoring endpoint, parameterized SQL queries for single-wallet scoring, implemented web3.py contract interaction for score pushing.

**Key decision (AI evaluated, human approved):** The Allium Wallet API was evaluated as a potential replacement for per-chain Explorer SQL queries. The AI tested the Wallet API using the MCP realtime tools and a known Venus borrower. Finding: the Wallet API returns transaction-level activities (DEX trades are labeled) but does not expose Venus-specific lending events (borrow, repay, liquidation). Since our 4 dominant model features require Venus lending event history, the Wallet API was rejected. The human approved this decision.

**Human did:** Identified that the 90-second scoring latency should be framed as a feature, not a bug (credit card application analogy). Specified the 4-step progress indicator design for the frontend.

## Phase 6: Frontend

**AI did:** Scaffolded Vite + React + Tailwind project, built 9 components and 2 hooks, integrated Web3Modal for multi-wallet support (MetaMask, WalletConnect, Coinbase Wallet, EIP-6963 auto-detection). Built the 4-step credit-card-application-style scoring progress indicator.

**Human did:** Directed the layout swap (composite score as hero gauge instead of onchain score). Identified the need for Web3Modal (standard multi-wallet modal) after the initial MetaMask-only implementation. Requested the "Score My Wallet" button, testnet warning banner, and logo-click-to-reset behavior.

**Bug caught by human:** The signer-connected contract instances were using `BrowserProvider` (read-only) instead of a resolved `Signer`, causing "contract runner does not support sending transactions" on attestation submission. The AI restructured useContracts.js to resolve the signer asynchronously via useEffect.

**Human-directed addition:** Tiered Allium fallback system (demo mode) so judges can run the project without an Allium API key. The human specified the three-tier design (live Allium → cached real wallets → deterministic synthetic features), the rate limiting requirements (20/hr per IP, 100/day global), and the security requirements (no Allium details exposed to frontend).

## Phase 7: Documentation

**AI did:** Wrote all documentation deliverables (bsc.address, README.md, PROJECT.md, TECHNICAL.md, EXTRAS.md, architecture.md, pitch_narrative.md, demo_script.md, DEEP_DIVE.md, this build log).

**Human did:** Specified the judge's starter kit alignment (bsc.address, PROJECT.md, TECHNICAL.md, EXTRAS.md structure). Directed the information-asymmetry framing for the "two signals compound" claim (explicitly disclaiming that onchain data improves FICO). Wrote the punchline. Specified the writing style (active voice, first person plural, no em dashes, concrete examples over abstractions). Directed that pitch_narrative.md and demo_script.md be gitignored as internal prep documents. Directed the API composability paragraph for the production roadmap. Directed the Vercel + Render deployment setup.

## Summary

Across all 8 phases, the pattern was consistent: the AI generated code, wrote queries, trained models, built contracts, and produced documentation. The human made every strategic decision (feature selection, scorecard methodology, composite weighting scheme, Sybil resistance mechanism, value proposition framing), reviewed outputs at checkpoints, caught bugs and data issues, executed external steps (Allium queries, wallet funding, deployment configuration), and directed iterative refinement when the AI's outputs did not meet the bar for defensibility or interpretability.

The project required 4 model retraining iterations, 3 contract revisions (composite math restructure, identity persistence addition, curve interpolation bugfix), 2 frontend wallet integration approaches (raw MetaMask → Web3Modal), and continuous documentation updates as design decisions evolved during development. None of this was in the original prompt. It emerged from the human-AI collaboration process.
