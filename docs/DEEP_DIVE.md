# Credence Protocol -- Technical Deep Dive

**Live demo:** [credence-protocol.vercel.app](https://credence-protocol.vercel.app/) | **GitHub:** [github.com/justinwender/credence-protocol](https://github.com/justinwender/credence-protocol)

## 1. Problem Statement

DeFi lending protocols collectively lock over $100 billion in excess collateral. Every major protocol (Aave, Compound, Venus, MakerDAO) treats every borrower identically: post 150% or more of your loan value as collateral, or you cannot borrow at all. There is no mechanism to distinguish a borrower who has never been liquidated across two years of active lending from one who opened their wallet yesterday.

This is not a novel problem. Traditional finance solved it decades ago with credit scoring. FICO and VantageScore use logistic regression to predict default probability from historical financial behavior, enabling lenders to offer risk-adjusted terms. A borrower with a 780 FICO pays less for a mortgage than a borrower with a 620 FICO, and the lender's portfolio performs better as a result. DeFi has no equivalent infrastructure, so it cannot price risk, and borrowers who are genuinely creditworthy subsidize borrowers who are not.

The capital inefficiency is not abstract. A borrower who wants $10,000 in USDC must lock $15,000 in ETH. That $5,000 in excess collateral earns nothing. Multiply this across the ecosystem, and billions sit idle, locked in contracts that cannot distinguish good borrowers from bad ones.

## 2. Solution Overview

Credence Protocol is a two-source composite credit scoring system deployed on BNB Chain. It combines two independent risk signals into a single onchain score that determines collateral requirements on a continuous curve from 150% down to 75%.

The first signal is an onchain behavioral score. I trained a FICO-methodology logistic regression model on 115,687 Venus Protocol borrowers across five blockchains (BSC, Ethereum, Arbitrum, Polygon, Optimism). The model ingests 10 features spanning lending behavior, portfolio composition, and cross-chain activity, and outputs a 0-100 credit score with interpretable coefficients. Every factor's contribution to the score is explainable, matching the transparency requirements that regulators impose on traditional credit scoring.

The second signal is an offchain credit attestation. Credence simulates ZKredit, a system where traditional credit data (a FICO score) is verified via zero-knowledge proofs and attested onchain without exposing personal information. In the demo, an admin sets attestations to show the mechanism. In production, a ZK verifier contract would validate Brevis or Primus proofs before writing the attestation.

The two signals combine asymmetrically. Offchain attestation establishes a competitive baseline, reflecting verified real-world creditworthiness. Onchain data boosts above that baseline, reflecting DeFi-specific competence that offchain data cannot measure. Onchain data alone is capped, because a high score from thin onchain activity is not equivalent to proven creditworthiness.

## 3. Technical Architecture

Credence is a four-layer system. For full technical detail, see `docs/architecture.md` and `docs/TECHNICAL.md`.

**Layer 1, Data and Feature Engineering.** I wrote Allium Explorer SQL queries to extract training data from five blockchains. Labels came exclusively from Venus Protocol liquidation events on BSC: a binary indicator of whether each borrower wallet was ever liquidated. Features span four categories: lending behavior (days active, repayment consistency, distinct assets borrowed), financial profile (portfolio value, stablecoin allocation, accumulation trend), DeFi sophistication (DEX activity), and cross-chain breadth (transaction volume, chains used, bridge usage). The result is a FICO-style scorecard that bins continuous features into discrete risk tiers, exactly as traditional credit bureaus do.

**Layer 2, Smart Contracts.** Three Solidity contracts deployed and verified on BSC Testnet (chain ID 97). The `OffchainAttestationRegistry` stores FICO-equivalent attestations with a persistent identity hash that survives wallet rebinding (Sybil resistance). The `CreditOracle` stores onchain scores pushed by the scoring pipeline, reads attestations from the registry, and exposes a composite score on-read using configurable asymmetric weighting. The `LendingPool` implements deposit, borrow, and repay operations with a continuous five-segment collateral curve driven by the composite score. The test suite contains 79 tests with 99.5% line coverage.

**Layer 3, Scoring Pipeline.** A FastAPI service accepts a wallet address, runs two concurrent SQL queries against Allium Explorer (one for BSC lending features, one for cross-chain activity), computes 10 features from the results, runs the frozen logistic regression model, and pushes the resulting score to the CreditOracle contract on BSC Testnet. The pipeline supports three-tier data sourcing: live Allium queries with an API key (~90 seconds), pre-cached real wallet data (instant), or deterministic synthetic features for unknown addresses (instant). The full demo works without any external API keys.

**Layer 4, Frontend.** A React + Vite + Tailwind + ethers.js v6 single-page application with a dark Bloomberg-terminal aesthetic. The UI walks users through a credit-card-application-style 4-step progress flow: wallet lookup, data collection, model scoring, and score publication. The dashboard displays a composite credit score gauge, factor breakdown with human-readable labels, collateral ratio, attestation simulator, and lending interface. Web3Modal provides multi-wallet support (MetaMask, WalletConnect, Coinbase Wallet, Rabby, and any EIP-6963-compatible browser wallet).

### Bidirectional Credit Identity (Full Vision)

The identity-persistence mechanism I implemented is a one-directional primitive: an offchain identity anchors onchain reputation. The full vision is bidirectional. Onchain behavior feeds back into the persistent identity record, creating a unified credit profile that spans wallets, protocols, and chains. Over time, this produces a portable, unforgeable credit identity that:

- Spans multiple wallets (rebinding preserves the identity's accumulated score)
- Accumulates reputation across DeFi activity (new behavior updates the persistent record)
- Survives wallet turnover (Sybil attacks fail because the identity is anchored to an offchain account, not a wallet address)
- Enables true undercollateralized DeFi at scale (track record cannot be gamed by creating new wallets)

The submitted demo is the first primitive step toward this picture. The contracts already track historical onchain scores per identity hash and carry them across wallet rebindings. What remains is closing the feedback loop from onchain to offchain, which requires integration with ZK proof systems that can attest to onchain behavior back into the offchain credit profile.

## 4. Data and Model Methodology

### Training Data

I collected data on 115,687 Venus Protocol borrowers, of which 15,889 (13.7%) were liquidated at least once. All labels come from Venus Protocol liquidation events on BSC. I deliberately excluded other BNB Chain lending protocols (Radiant, Alpaca Finance) because their liquidation mechanics differ, and mixing label semantics across protocols would contaminate the training signal. Venus alone provided a dataset large enough for robust logistic regression.

Feature data spans five blockchains: BSC (required for all wallets), Ethereum, Arbitrum, Polygon, and Optimism (best-effort, providing cross-chain breadth signals). All data was queried via Allium Explorer SQL against institutional-grade indexed blockchain data.

### Feature Engineering

I computed 10 features across four categories, using a FICO-style scorecard approach where each continuous feature is binned into 3-5 discrete risk tiers. The lowest-risk bin serves as the reference category (dropped from one-hot encoding), so every retained coefficient represents the credit score penalty for being in that tier relative to the safest bucket. The final model uses 24 one-hot columns derived from the 10 source features.

The features and their rationale:

| Feature | Category | Why It Matters |
|---|---|---|
| Borrowing protocol activity (days) | Lending behavior | Duration of active lending positions is the strongest signal of liquidation risk. More days active means more exposure to market volatility. |
| Repayment consistency ratio | Lending behavior | A ratio near 1.0 (balanced repayments to borrows) indicates disciplined debt management. Extreme ratios in either direction signal risk. |
| Loan repayment count | Lending behavior | Higher repayment counts indicate track record of fulfilling obligations. |
| Distinct assets borrowed | Lending behavior | Borrowing across many token types increases complexity and liquidation surface area. |
| Portfolio value (USD) | Financial profile | Larger portfolios provide more buffer against liquidation, up to a point. |
| Stablecoin allocation | Financial profile | Higher stablecoin ratios indicate conservative positioning, reducing volatility exposure. |
| Cross-chain transaction volume | Cross-chain breadth | Activity across non-BSC chains signals a broader, more established DeFi presence. |
| Cross-chain DEX activity | Cross-chain breadth | DEX trading on multiple chains indicates DeFi sophistication. |
| Blockchain networks used | Cross-chain breadth | The number of non-BSC chains with recorded activity. |
| Cross-chain bridge experience | Cross-chain breadth | Bridge usage indicates comfort with cross-chain operations. |
| Recent accumulation trend | Financial profile | Whether the wallet has been accumulating or depleting assets over the past 90 days. |

### Model Training and Iteration

I trained a logistic regression model with L2 regularization, balanced class weights, and 5-fold stratified cross-validation. The choice of logistic regression was deliberate: it matches FICO/VantageScore methodology, produces interpretable coefficients (every factor's contribution is explainable), and satisfies regulatory transparency requirements that black-box ML models cannot meet.

I iterated through four training rounds, each addressing specific issues identified in the previous round:

1. **Initial logit with continuous features.** AUC 0.81, but multicollinearity between features (total lending volume correlated with repayment count, wallet age correlated with lending active days) inflated variance in coefficient estimates.

2. **FICO scorecard conversion.** I binned all continuous features into discrete tiers, converting the model to a proper scorecard. AUC improved to 0.845, but 25 coefficient sign flags appeared (bins where the coefficient direction contradicted economic intuition, such as more repayments increasing liquidation risk).

3. **Tier 1 fixes.** I dropped `total_lending_volume` (redundant with repayment count) and collapsed the `[0, 0]` bin of Repayment consistency ratio into the adjacent bin (zero-ratio wallets are mechanically different from low-ratio wallets). Sign flags reduced but remained.

4. **Feature cuts.** I dropped 7 correlated features including wallet age, BSC DEX trade count, and total lending volume. The final model uses 10 features with 24 one-hot columns, achieves AUC 0.8182, and has 0 serious sign flags. Every coefficient direction aligns with economic intuition.

### Top 5 Coefficients

| Rank | Feature | Bin | Coefficient | Interpretation |
|---|---|---|---|---|
| 1 | Borrowing protocol activity (days) | 15+ days | -1.23 | Wallets active in lending protocols for 15+ days face substantially higher liquidation risk than single-day borrowers. This is the dominant signal. |
| 2 | Borrowing protocol activity (days) | 5-14 days | -1.05 | Same pattern at lower magnitude. |
| 3 | Borrowing protocol activity (days) | 2-4 days | -0.80 | Even 2-4 days of activity significantly increases risk relative to single-day borrowers. |
| 4 | Repayment consistency ratio | Over 2.0x | -0.60 | Repaying more than double what was borrowed signals unusual behavior (over-repaying due to liquidation pressure or position mismanagement). |
| 5 | Repayment consistency ratio | 1.1-2.0x | -0.54 | Even moderate imbalance increases risk relative to the 0.9-1.1 balanced range. |

The dominance of Borrowing protocol activity (days) is the most important finding. Wallets that borrowed once and repaid once score near 98, because minimal exposure means minimal risk. This is mechanically correct but creates a "thin-file" problem: a high score achieved through minimal activity is not equivalent to a high score earned through extensive, well-managed exposure. Credence addresses this at the contract layer (see Section 5).

### Model Performance

| Metric | Value |
|---|---|
| AUC-ROC (5-fold CV) | 0.8182 |
| Precision | 0.9508 |
| Recall | 0.7208 |
| F1 | 0.8200 |
| Training samples | 115,687 |
| Liquidation rate | 13.7% |

The model separates well: the median credit score for non-liquidated wallets is 71, versus 29 for liquidated wallets. The score distribution shows clear discriminative power across the full 0-100 range.

## 5. Smart Contract Design

### Composite Score Math (Asymmetric Weighting)

The CreditOracle uses asymmetric logic to compute composite scores, reflecting the protocol's core value proposition.

**Onchain-only (no attestation), the thin-file cap.** When a wallet has an onchain score but no offchain attestation, the composite is capped:

```
compositeScore = (onchainScore * onchainOnlyMultiplier) / 100
```

The default `onchainOnlyMultiplier` is 50. A raw onchain score of 98 becomes a composite of 49, mapping to approximately 121% collateral. The wallet gets better terms than standard DeFi (150%), but cannot access undercollateralized terms.

This cap exists because of the thin-file problem. The model's dominant feature, Borrowing protocol activity (days), assigns the safest reference category to wallets with just one day of activity. A wallet that borrowed once, repaid once, and moved on can score 98. Its low liquidation risk is real (no ongoing exposure), but its creditworthiness signal is thin. Analogous to a FICO thin file, a high score from minimal activity should not unlock institutional-grade lending terms.

**With attestation (offchain baseline plus onchain boost).** When a wallet has both signals, the offchain attestation sets a competitive baseline and the onchain score boosts above it:

```
baseline = (offchainScore * offchainBaselineMultiplier) / 100
boost = (onchainScore * onchainBoostMultiplier) / 100
compositeScore = min(100, baseline + boost)
```

Defaults: `offchainBaselineMultiplier = 70`, `onchainBoostMultiplier = 40`. All four multipliers are configurable `uint8` state variables, admin-settable.

This asymmetry captures the protocol's value proposition:

- **Onchain-only**: better than standard DeFi terms (~120% max), but still overcollateralized. A high thin-file score is not equivalent to genuine creditworthiness.
- **Offchain-only (strong FICO)**: competitive with traditional bank lending, maybe slightly worse (~110% collateral). Verified offchain creditworthiness earns bank-tier terms.
- **Offchain plus strong onchain**: genuinely better than a bank could offer (undercollateralized, 75-90%). The onchain signal lifts above the bank baseline.

### Persistent Credit Identity (Sybil Resistance)

The `OffchainAttestationRegistry` includes a `bytes32 identityHash` field on each attestation. In production, this hash is derived deterministically from the ZK proof: same offchain identity produces the same hash, regardless of which wallet submits the proof. The registry tracks three additional mappings:

- `_historicalOnchainScores`: a persistent per-identity onchain score that survives wallet rebinding.
- `_identityToCurrentWallet`: which wallet currently holds this identity.
- `_walletToIdentity`: reverse lookup.

When an attestation is set for a wallet whose `identityHash` is already bound to a different wallet, the registry performs a rebinding: it clears the old wallet's attestation, preserves the historical onchain score, and binds the identity to the new wallet. The CreditOracle uses the historical score (not zero) when computing the new wallet's composite, so a user who was liquidated on wallet A, then rebinds their attestation to fresh wallet B, gets wallet B's composite calculated using wallet A's old score. There is no fresh start. Credit history is portable and inescapable, just like in traditional finance.

### Collateral Curve

The LendingPool reads the composite score from the CreditOracle and maps it to a collateral requirement on a continuous five-segment curve:

| Composite Score Range | Collateral Required |
|---|---|
| 0-20 | 150% (flat) |
| 20-50 | 150% linearly decreasing to 120% |
| 50-70 | 120% linearly decreasing to 100% |
| 70-85 | 100% linearly decreasing to 85% |
| 85-100 | 85% linearly decreasing to 75% |

The curve is implemented as piecewise linear interpolation with configurable breakpoints. A composite score of 99 yields 75.7% collateral. A composite of 22 (a real Venus borrower scored via the live pipeline) yields 148% collateral.

### Test Coverage

The smart contract test suite contains 79 tests achieving 99.5% line coverage. Tests cover composite score calculation, attestation lifecycle, identity persistence across wallets, collateral curve math, lending operations (deposit, borrow, repay), edge cases (zero scores, max scores, rebinding to same wallet), and access control.

## 6. ZKredit Integration Architecture

### What I Built

For the hackathon, Credence simulates ZKredit with admin-set attestations. The `OffchainAttestationRegistry` contract accepts a struct containing a FICO score (mapped linearly from 300-850 to 0-100), an identity hash, and a verified flag. An admin wallet (the contract owner) calls `setAttestation` to write these values. This demonstrates the full composite scoring flow without requiring a live ZK proof system.

### What Production Looks Like

In production, the admin-set path would be replaced by a ZK verifier contract. The flow would work as follows:

1. A user connects to ZKredit (powered by Brevis or Primus) and authorizes a zero-knowledge proof of their FICO score range.
2. The ZK proof is generated offchain, attesting to the score without revealing the underlying credit report.
3. The proof is submitted to a verifier contract on BSC, which validates its cryptographic integrity.
4. Upon successful verification, the verifier contract calls `OffchainAttestationRegistry.setAttestation`, writing the attested score onchain.
5. The identity hash is derived deterministically from the ZK proof inputs (same offchain identity always produces the same hash), enabling the Sybil resistance mechanism.

The key architectural decision was separating the attestation storage (registry contract) from the attestation source (admin for demo, ZK verifier for production). The CreditOracle and LendingPool never need to change when the attestation source upgrades. They read composite scores from the oracle, which reads attestations from the registry, regardless of how those attestations arrived.

## 7. Frontend and UX

### Credit Card Application Loading Experience

When a user submits a wallet address for scoring, the frontend displays a 4-step progress indicator inspired by the experience of applying for a credit card online:

1. **Wallet Lookup**: resolving the address (and ENS name, if applicable)
2. **Data Collection**: querying blockchain data across five chains
3. **Credit Scoring**: running the logistic regression model
4. **Score Publication**: pushing the score to the CreditOracle contract

The progress indicator is driven by real-time server-sent events (SSE) from the backend `/score/stream` endpoint. As each query completes on the backend, an event is emitted and the frontend updates immediately. A live network map shows each of the five blockchains (BSC, Ethereum, Arbitrum, Polygon, Optimism) lighting up with its brand color as its data is retrieved, then displaying a checkmark when complete. For live Allium queries, the ~90-second wait reflects genuine computation across real onchain data. For pre-scored demo wallets, the cached response loads instantly.

### Activity Tier Adjustments

The model was trained on Venus Protocol borrowers, so it produces a mathematically valid but misleading output for wallets outside its training population. A wallet with no lending history scores high because it has zero liquidation exposure, but that high score reflects absence of risk, not proven creditworthiness. This is the thin-file problem applied to the scoring pipeline itself.

Credence addresses this with tiered score adjustments applied after model inference but before the score is pushed to the CreditOracle. These adjustments correct for the gap between "low risk because never exposed" and "low risk because responsibly managed":

- **No onchain activity**: score set to 0, no contract push, frontend displays "No onchain activity found"
- **No lending history** (general onchain activity but zero Venus interactions): raw model score scaled by 0.6x, reflecting that the score is based entirely on non-lending features and carries less signal
- **Thin lending history** (fewer than 2 active lending days): raw model score scaled by 0.8x, reflecting limited track record
- **Full history** (2+ active lending days): no adjustment, full model score

The frontend displays the activity tier prominently near the score gauge, showing both the raw model score and the adjusted score so the user understands the reasoning and what they can do to improve (build more lending history).

### Pre-Scored Demo Wallets

Five wallets from the training data are pre-scored and cached in `pipeline/demo_wallets.json` with their full API response objects. When a judge clicks a demo wallet chip on the homepage, the backend recognizes the address and returns the cached response instantly, bypassing Allium queries, model inference, and contract push. This enables rapid comparison across diverse credit profiles (liquidated borrower, thin-file wallet, crosschain power user, strong lending history) without 90-second waits per wallet. Any address typed into the search bar still triggers the full live scoring pipeline.

### Full Credit Report

Below the factor breakdown summary, a "View Full Credit Report" expansion panel provides an Experian-style detailed report for each of the 10 model features. Each feature card shows the wallet's assessed tier (Poor, Fair, Good, or Excellent), a qualitative impact level (Very High through Minimal, replacing raw coefficient numbers), a benchmark comparison against top-scoring wallets, and a specific improvement suggestion. Tier assignment uses domain-informed logic: for features where more experience is better (lending activity, repay count, crosschain presence), the highest-activity bin maps to Excellent. For features where the model's reference bin is genuinely safest (repayment ratio near 1.0, high stablecoin allocation), the reference bin maps to Excellent.

### Bloomberg-Terminal Aesthetic

The design direction is Bloomberg-terminal-meets-fintech: dark background, data-dense layout, monospaced numerics. The credit score gauge is the hero element, rendered as a semicircular arc with color grading from red (low scores) through yellow to green (high scores). Below the gauge, a factor breakdown table shows each feature's contribution to the score using human-readable display names (for example, "Borrowing protocol activity (days)" rather than the internal variable name `lending_active_days`).

### Wallet Integration

The frontend uses Web3Modal for wallet connectivity, supporting MetaMask, WalletConnect QR code, Coinbase Wallet, Rabby, and any EIP-6963-compatible browser wallet. The app prompts users to switch to BSC Testnet (chain ID 97) if they are connected to a different network. The attestation simulator and lending interface activate only when a wallet is connected, providing a clear distinction between read-only scoring (available to anyone) and interactive DeFi operations (requiring a connected wallet).

## 8. Two Independent Risk Domains

This section addresses the central claim of the protocol: that combining onchain and offchain signals provides more complete risk coverage than either signal alone.

There is no published evidence that onchain data improves FICO's prediction of default risk. I do not claim it does.

Instead, the two sources measure fundamentally different risk domains. FICO measures offchain financial behavior: bill payments, credit utilization, account history, income stability. It cannot measure DeFi-specific risk, such as how a borrower manages health factors, whether they have survived market volatility without liquidation, or how they interact with smart contracts across multiple chains. Onchain behavioral data measures exactly these DeFi-native risks, but it cannot measure income, employment stability, or broader credit obligations.

A lender operating onchain faces risks in both domains. Measuring both provides more complete risk coverage than measuring either alone. This is not "improving FICO." It is covering a second risk surface that FICO is structurally unable to capture.

The analogy to auto insurance is precise. Insurers use telematics (driving behavior data) alongside credit scores. Driving data does not improve credit prediction. It measures a separate risk domain (actual driving behavior) that credit scores cannot see. The combination reduces information asymmetry across both risk surfaces, enabling more accurate premium pricing.

**Concrete example.** A FICO 780 borrower who has never used DeFi receives competitive terms through Credence (~110% collateral) based on their offchain attestation alone. A FICO 780 borrower with two years of responsible Venus Protocol usage (consistent repayments, no liquidations, active health factor management) receives better terms (~76% collateral). The onchain data did not change the FICO score. It assessed a second, independent risk domain that FICO cannot see, further reducing the lender's uncertainty. The difference between 110% and 76% collateral is the value of measuring DeFi-specific risk on top of offchain creditworthiness.

## 9. Production Considerations

### Latency Optimization

The 90-second scoring latency in the demo comes from ad-hoc SQL queries against Allium's OLAP warehouse, which is optimized for analytical throughput, not low-latency point lookups. In production, wallet features would be pre-computed and cached using materialized views or a dedicated indexing service, bringing data retrieval latency to single-digit seconds. Model inference is already sub-millisecond (logistic regression is a single matrix multiplication). The bottleneck is entirely data retrieval, which is a solved engineering problem at scale.

### FICO Mapping Nonlinearity

The `CreditOracle.mapFicoToZero100` function linearly maps FICO 300-850 to 0-100. This means FICO 575 (the midpoint of the range) maps to 50, and FICO 300 maps to 0. In practice, almost no DeFi borrower has a FICO score under 500, so the bottom third of the mapping is dead space that wastes resolution. In production, this would be replaced with a nonlinear mapping (piecewise-linear or sigmoid-shaped) that concentrates resolution in the 600-800 range where actual lending decisions cluster. This would give the protocol finer-grained discrimination between borrowers in the decision-relevant FICO range.

### Real ZK Proof Integration

The admin-set attestation mechanism is a simulation. Production integration with Brevis or Primus would involve deploying a ZK verifier contract that validates proofs before writing attestations to the registry. The contract architecture already supports this: `setAttestation` is an access-controlled function that can be called by any authorized address, not just the owner. Adding a ZK verifier is a matter of deploying the verifier contract and granting it write access, without modifying the registry, oracle, or lending pool.

### Active Loans During Attestation Rebinding

The current implementation does not handle active loans on the old wallet when an attestation transfers to a new wallet. In production, the protocol would need to either force repayment on the old wallet before allowing rebinding, freeze the old loan at its current terms, or implement a debt transfer mechanism. This is a non-trivial design decision that depends on the protocol's risk appetite and the ZK proof layer's rebinding cooldown policy.

### Liquidation Engine, Interest Rate Model, and Bad Debt Handling

The demo LendingPool implements basic deposit/borrow/repay without a liquidation engine, dynamic interest rates, or bad debt socialization. A production protocol would need all three. The liquidation engine would monitor health factors and trigger partial or full liquidations when collateral ratios fall below maintenance thresholds. Interest rates would follow a utilization-based curve (similar to Aave or Compound). Bad debt from under-collateralized positions would be socialized across the insurance fund or absorbed by protocol reserves.

### Multi-Protocol Training Data

I trained exclusively on Venus Protocol liquidation data to maintain clean label semantics. Other BSC lending protocols (Radiant, Alpaca Finance) use different liquidation mechanics, and mixing them would introduce label noise. In production, the training data would expand to include Aave, Compound, and MakerDAO liquidations (after normalizing for protocol-specific mechanics), improving the model's generalization across lending environments.

### Governance for Parameter Tuning

All composite score multipliers, collateral curve breakpoints, and FICO mapping parameters are configurable state variables behind `onlyOwner` access control. In production, these would be governed by a DAO or multisig with timelock, allowing the community to adjust risk parameters through transparent governance rather than unilateral admin action.

### Security Hardening

The hackathon contracts use Solidity 0.8+ (built-in overflow protection), `onlyOwner` for admin functions, and `ReentrancyGuard` on borrow and repay operations. Production contracts would additionally need: formal verification of the composite score and collateral curve math, a pause mechanism for emergency response, a timelock on parameter changes, multisig for admin operations, and a security audit by a reputable firm.

### Composable Credit Infrastructure

Credence scores are composable onchain infrastructure, not a closed system. Any BNB Chain lending protocol can query the CreditOracle contract to read a wallet's composite score and adjust their own underwriting terms. This transforms Credence from a single lending pool into credit scoring infrastructure for the entire DeFi lending ecosystem. The revenue model extends beyond Credence's own lending activity to per-query or subscription fees charged to third-party protocols that integrate Credence scores. Every score query is logged onchain via event emissions, creating a transparent inquiry trail analogous to hard pulls in traditional credit reporting.

### Onchain Hard Inquiries

Onchain credit inquiries are the natural analog of hard pulls in traditional credit reporting. Every time a protocol queries the CreditOracle, the query is logged onchain via event emissions, creating a transparent, auditable trail of credit inquiries. In production, the frequency of recent score queries would be incorporated as a model feature, penalizing wallets that are rapidly seeking credit across multiple protocols in a short window, exactly as FICO penalizes multiple hard inquiries within a short period. This feature is architecturally built into the CreditOracle's event system and requires only model integration to activate.

### Bidirectional Credit Identity

The identity-persistence mechanism I built is one-directional: offchain identity anchors onchain reputation. The full production vision is bidirectional. Onchain behavior feeds back into the offchain credit profile, creating a unified credit record that spans wallets, protocols, and chains. A borrower who demonstrates consistent repayment behavior across multiple DeFi protocols would see that track record reflected not just in their onchain score, but in their persistent identity record. This produces a portable, unforgeable credit identity for DeFi, the infrastructure needed for true undercollateralized lending at scale.

## 9. Team and Acknowledgments

### Justin Wender (Solo Developer)

Justin is completing his MS in Economics and Data Science at Northeastern University (expected July 2026, 3.9 GPA) after earning his BS in Politics, Philosophy, and Economics (Concentration: Logic and Game Theory) Summa Cum Laude in December 2025. He is the outgoing President of NEU Blockchain, Northeastern's premier blockchain club, where he oversees 12 board members and coordinates relationships with VCs, protocols, and universities.

His professional experience spans digital asset research and blockchain infrastructure. At Fireblocks (Summer 2025), he worked on NYDFS cold custody self-certification, MPC warm wallet implementation, and asset research covering 18 digital assets. At TRGC Amsterdam (November 2024 to March 2025), he evaluated 30+ assets for a $10M fund serving high-net-worth clients.

Justin recently accepted a Growth/BDR role at Allium, the institutional blockchain data platform (Series A, backed by Kleiner Perkins), starting May 2026. Allium's data infrastructure powers the crosschain wallet features that feed Credence's credit scoring model.

His research interests span blockchain economics (token emission schedules as credible commitment devices, applying Kydland-Prescott monetary theory to protocol design), DeFi capital markets, and the application of traditional finance methodology to onchain systems. Credence Protocol reflects this research direction: bringing traditional credit scoring methodology, specifically the FICO logistic regression scorecard approach, onchain for the first time.

[LinkedIn](https://www.linkedin.com/in/justinwender/) | wender.j@northeastern.edu

### Built With

Claude Code (Anthropic), Allium blockchain data infrastructure, Foundry smart contract toolchain, ethers.js v6, Web3Modal, React, Vite, Tailwind CSS, FastAPI, scikit-learn.

## Deployed Contracts (BSC Testnet, Chain ID 97)

| Contract | Address | Explorer |
|---|---|---|
| OffchainAttestationRegistry | `0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0` | [BscScan](https://testnet.bscscan.com/address/0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0) |
| CreditOracle | `0x16253605BEef191024C950E00D829E0D410637B7` | [BscScan](https://testnet.bscscan.com/address/0x16253605BEef191024C950E00D829E0D410637B7) |
| LendingPool | `0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA` | [BscScan](https://testnet.bscscan.com/address/0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA) |

All three contracts are verified on BscScan. Source code is readable directly on the explorer.

---

Credence is the first protocol to bring traditional credit scoring methodology onchain, because the trillion-dollar lending market won't move to DeFi until DeFi can underwrite like the real world does.
