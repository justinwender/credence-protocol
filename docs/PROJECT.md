# Credence Protocol -- Project Overview

## Problem Statement

DeFi lending today requires 150%+ collateralization on every loan. Protocols like Aave, Compound, and Venus have no mechanism to assess borrower creditworthiness, so they treat every borrower identically: overcollateralize or don't borrow. This locks billions in excess collateral across the ecosystem and excludes creditworthy borrowers from capital-efficient terms.

Traditional finance solved this problem decades ago with credit scoring. FICO and VantageScore use logistic regression to predict default probability from historical financial behavior, enabling risk-adjusted lending terms. DeFi has no equivalent. Credence builds one.

## Solution: Credence Protocol

Credence is a two-source composite credit scoring system deployed on BNB Chain. It combines two independent risk signals into a single score that determines collateral requirements on a continuous curve.

**Source 1 -- Onchain behavioral scoring.** A FICO-methodology logistic regression model trained on 115,687 Venus Protocol borrowers across five blockchains (BSC, Ethereum, Arbitrum, Polygon, Optimism). The model uses 10 features spanning lending behavior, portfolio composition, and cross-chain activity to predict liquidation probability. Output: a 0-100 credit score with interpretable coefficients.

**Source 2 -- Offchain credit attestation.** Simulates ZKredit, a system where traditional credit data (FICO score) is verified via zero-knowledge proofs and attested onchain without exposing personal information. In the demo, an admin sets attestations; in production, a ZK verifier contract validates Brevis/Primus proofs.

**Composite scoring.** The two sources combine asymmetrically. Offchain attestation establishes a competitive baseline (reflecting verified real-world creditworthiness). Onchain data boosts above that baseline (reflecting DeFi-specific competence). Onchain data alone is capped -- a high score from thin onchain activity is not equivalent to proven creditworthiness. All weighting parameters are configurable onchain.

## Value Proposition: Two Risk Domains, Not Two Data Points

The value of combining onchain and offchain signals is not that onchain data improves FICO's prediction of default risk. There is no published evidence for that claim, and Credence does not make it.

Instead, the two sources measure fundamentally different risk domains. FICO measures offchain financial behavior: bill payments, credit utilization, account history, income stability. It cannot measure DeFi-specific risk -- how a borrower manages health factors, whether they have survived market volatility without liquidation, or how they interact with smart contracts. Onchain behavioral data measures exactly these DeFi-native risks, but it cannot measure income, employment stability, or broader credit obligations.

A lender operating onchain faces risks in both domains. Measuring both provides more complete risk coverage than measuring either alone.

This is analogous to auto insurance: insurers use telematics (driving behavior data) alongside credit scores. Driving data does not improve credit prediction. It measures a separate risk domain -- actual driving behavior -- that credit scores are structurally unable to capture. The combination reduces information asymmetry across both risk surfaces.

**Concrete example.** A FICO 780 borrower who has never used DeFi receives competitive terms through Credence (100-110% collateral) based on their offchain attestation alone. A FICO 780 borrower with two years of responsible Venus Protocol usage -- consistent repayments, no liquidations, active health factor management -- receives better terms (75-85% collateral). The onchain data did not change the FICO score. It assessed a second, independent risk domain that FICO cannot see, further reducing the lender's uncertainty.

## How It Works

A user enters a wallet address (or ENS name). Credence's scoring pipeline queries five blockchains in real time via Allium's institutional-grade data infrastructure, computes 10 behavioral features, runs the frozen logistic regression model, and pushes the resulting credit score to the CreditOracle smart contract on BSC. The oracle combines the onchain score with any existing offchain attestation to produce a composite score, which the LendingPool reads to determine the borrower's collateral requirement on a continuous curve from 150% down to 75%. The entire process takes approximately 90 seconds -- like applying for a credit card online.

## Real-World Relevance

- **Same methodology as FICO/VantageScore.** Logistic regression with interpretable coefficients. Every factor's contribution to the score is explainable -- a regulatory requirement that black-box ML models cannot satisfy.
- **Trained on real liquidation data.** Labels derived from actual Venus Protocol liquidation events on BSC, not synthetic or simulated outcomes.
- **Institutional-grade data.** Built on Allium's blockchain data platform covering 80+ chains, the same infrastructure used by institutional analytics teams.
- **Model validation.** AUC 0.8182 on held-out test data. All coefficient signs align with economic intuition (e.g., more repayments reduce liquidation risk, higher portfolio value reduces liquidation risk).

## Sybil Resistance

Credence implements a persistent credit identity system where offchain attestations anchor a wallet's credit history to a deterministic identity hash. If a user rebinds their attestation to a new wallet, the new wallet inherits the old wallet's onchain credit history. This prevents the Sybil attack where a user creates fresh wallets to escape a bad credit record. Credit history becomes portable and inescapable, just like in traditional finance.

## Production Roadmap

- **ZKredit integration.** Replace admin-set attestations with zero-knowledge proofs verified onchain via Brevis or Primus, enabling trustless offchain credit attestation without exposing personal data.
- **Latency optimization.** Pre-compute wallet features using materialized views or a dedicated indexing service, reducing scoring latency from 90 seconds to single-digit seconds. Model inference is already sub-millisecond; the bottleneck is data retrieval, which is a solved engineering problem at scale.
- **Multi-protocol training data.** Expand beyond Venus to include Aave, Compound, and MakerDAO liquidation data, improving model generalization across lending protocols.
- **Bidirectional credit identity.** Onchain behavior feeds back into the persistent identity record, creating a unified credit profile that spans wallets, protocols, and chains, a portable, unforgeable credit identity for DeFi.
- **Composable credit infrastructure.** Credence scores are composable onchain infrastructure. Any BNB Chain lending protocol can query the CreditOracle contract to read a wallet's composite score and adjust their own underwriting terms. This transforms Credence from a single lending pool into credit scoring infrastructure for the entire DeFi lending ecosystem. The revenue model extends to per-query or subscription fees charged to third-party protocols that integrate Credence scores.
- **Onchain hard inquiries.** Every CreditOracle query is logged onchain via event emissions, creating a transparent inquiry trail analogous to hard pulls in traditional credit reporting. In production, the frequency of recent score queries would be incorporated as a model feature, penalizing wallets rapidly seeking credit across multiple protocols, exactly as FICO penalizes multiple hard inquiries within a short period.

---

Credence is the first protocol to bring traditional credit scoring methodology onchain, because the trillion-dollar lending market won't move to DeFi until DeFi can underwrite like the real world does.
