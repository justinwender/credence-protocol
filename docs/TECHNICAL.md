# Credence Protocol -- Technical Architecture & Reproduction Guide

Complete instructions for cloning, configuring, and running the Credence Protocol demo from a clean terminal.

---

## Architecture Overview

Credence Protocol is a four-layer system that produces onchain credit scores and uses them to adjust collateral requirements in a BSC-deployed lending pool.

**Layer 1 -- Data & Feature Engineering.** A FICO-style logistic regression scorecard trained on 115,687 Venus Protocol borrowers across five blockchains (BSC, Ethereum, Arbitrum, Polygon, Optimism). The model uses 10 features spanning lending behavior, financial profile, DeFi sophistication, and cross-chain activity, achieving an AUC of 0.8182. Output: a 0--100 credit score where higher means lower liquidation risk. The model is frozen and ships as `model/model.pkl`.

**Layer 2 -- Smart Contracts.** Three Solidity contracts deployed and verified on BSC Testnet (chain ID 97). `OffchainAttestationRegistry` simulates a ZKredit attestation layer with Sybil-resistant identity persistence across wallets. `CreditOracle` stores onchain scores, reads offchain attestations, and exposes a composite score on-read using asymmetric weighting (onchain-only scores are capped to prevent thin-file wallets from accessing undercollateralized terms). `LendingPool` implements deposit, borrow, and repay operations with a continuous collateral curve from 75% to 150% driven by the composite credit score.

**Layer 3 -- Scoring Pipeline.** A FastAPI service that accepts a wallet address, queries blockchain data via Allium Explorer SQL, runs the frozen model, and pushes the resulting score to the CreditOracle contract. The pipeline supports tiered data sourcing: live Allium queries (with API key), pre-cached real wallet data, or deterministic synthetic features -- so the full demo works without any external API keys.

**Layer 4 -- Frontend.** A React + Vite + Tailwind + ethers.js v6 single-page application with a dark Bloomberg-terminal aesthetic. The UI walks users through a credit-card-application-style 4-step progress flow: wallet lookup, data collection, model scoring, and score publication. The dashboard displays a composite credit score gauge, factor breakdown with human-readable labels, collateral ratio, attestation simulator, and lending interface.

---

## Deployed Contract Addresses (BSC Testnet, Chain ID 97)

| Contract | Address | Explorer |
|---|---|---|
| OffchainAttestationRegistry | `0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0` | [BscScan](https://testnet.bscscan.com/address/0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0) |
| CreditOracle | `0x16253605BEef191024C950E00D829E0D410637B7` | [BscScan](https://testnet.bscscan.com/address/0x16253605BEef191024C950E00D829E0D410637B7) |
| LendingPool | `0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA` | [BscScan](https://testnet.bscscan.com/address/0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA) |

All three contracts are verified on BscScan -- source code is readable directly on the explorer.

---

## Prerequisites

- **Python 3.11+** -- for the scoring pipeline and model inference
- **Node.js 18+** -- for the frontend dev server
- **Foundry** -- for smart contract compilation and testing (optional, only needed to redeploy)
- **A Web3 wallet** -- MetaMask, Coinbase Wallet, Rabby, WalletConnect-compatible, or any EIP-6963 browser wallet

Install Foundry (optional):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/justinwender/credence-protocol.git
cd credence-protocol

# Install Python dependencies
pip install -r pipeline/requirements.txt

# Install frontend dependencies
cd frontend && npm install && cd ..

# Set up environment variables
cp .env.example .env
# Edit .env -- see "Environment Variables" section below
```

---

## Environment Variables

Copy `.env.example` to `.env` and configure the following:

| Variable | Required? | Description |
|---|---|---|
| `ALLIUM_API_KEY` | **No** | Allium API key for live blockchain data queries. Without it, the pipeline uses cached or synthetic data (see "Running Without an Allium API Key" below). Get a key at [app.allium.so](https://app.allium.so). |
| `BSC_TESTNET_RPC` | No | BSC Testnet RPC endpoint. Pre-filled with `https://data-seed-prebsc-1-s1.binance.org:8545/`. Change only if the default is unreliable. |
| `BSC_TESTNET_PRIVATE_KEY` | No | Private key for a BSC Testnet wallet. Only needed if you want the pipeline to push scores to the CreditOracle contract, or if you are redeploying contracts. Generate a fresh testnet-only wallet -- never use a mainnet key. |
| `ETHERSCAN_API_KEY` | No | Etherscan V2 API key (works across all chains including BscScan). Only needed for contract verification during redeployment. |
| `ATTESTATION_REGISTRY_ADDRESS` | No | Pre-populated if using the existing deployment. Set to `0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0`. |
| `CREDIT_ORACLE_ADDRESS` | No | Pre-populated if using the existing deployment. Set to `0x16253605BEef191024C950E00D829E0D410637B7`. |
| `LENDING_POOL_ADDRESS` | No | Pre-populated if using the existing deployment. Set to `0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA`. |

**Minimal `.env` for demo evaluation (no external keys needed):**

```
BSC_TESTNET_RPC=https://data-seed-prebsc-1-s1.binance.org:8545/
ATTESTATION_REGISTRY_ADDRESS=0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0
CREDIT_ORACLE_ADDRESS=0x16253605BEef191024C950E00D829E0D410637B7
LENDING_POOL_ADDRESS=0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA
```

---

## Running Without an Allium API Key

The scoring pipeline works out of the box without any external API keys. Judges can score wallets immediately using cached or synthetic data.

The pipeline uses a three-tier data sourcing strategy:

| Tier | Trigger | Data Source | Latency | Details |
|---|---|---|---|---|
| **Tier 0** | `ALLIUM_API_KEY` is set | Live blockchain data across 5 chains via Allium Explorer SQL | ~90 seconds | Real-time queries against BSC, Ethereum, Arbitrum, Polygon, Optimism |
| **Tier 1** | No API key, known address | Pre-cached real wallet data from `pipeline/demo_wallets.json` | Instant | Genuine blockchain features collected during development |
| **Tier 2** | No API key, unknown address | Deterministic synthetic features derived from the address hash | Instant | Reproducible -- same address always produces the same features |

Key points:

- The frozen logistic regression model genuinely runs on every request regardless of data source. The score is real model output, not a hardcoded value.
- If `BSC_TESTNET_PRIVATE_KEY` is set, the score is pushed to the live CreditOracle contract on BSC Testnet.
- The API response includes a `data_source` field (`"live"`, `"cached"`, or `"synthetic"`) so the data origin is always transparent.
- The frontend displays the data source to the user.

---

## Starting the Application

Open two terminal windows from the project root:

**Terminal 1 -- Scoring Backend:**

```bash
python3 -m uvicorn pipeline.api:app --host 0.0.0.0 --port 8000
```

**Terminal 2 -- Frontend:**

```bash
cd frontend && npm run dev
```

Open **http://localhost:3000** in your browser.

---

## Using the Demo

### Step 1: Score a Wallet

Open the frontend at http://localhost:3000. You will see a dark-themed dashboard with a wallet search bar.

Enter any Ethereum-format wallet address (0x...) or ENS name and press Enter. The UI displays a 4-step credit-card-application-style progress indicator as the pipeline works:

1. **Wallet Lookup** -- resolving the address
2. **Data Collection** -- querying blockchain data (instant for cached/synthetic, ~90s for live)
3. **Credit Scoring** -- running the logistic regression model
4. **Score Publication** -- pushing to the CreditOracle contract (if private key is configured)

### Step 2: Review the Credit Dashboard

After scoring completes, the dashboard shows:

- **Composite credit score gauge** -- the hero visualization, 0--100 scale
- **Factor breakdown** -- individual feature contributions with human-readable labels (e.g., "Borrowing protocol activity (days)", "Repayment consistency ratio")
- **Data completeness indicator** -- which chains contributed data
- **Collateral ratio** -- the required collateral percentage based on the composite score (75%--150%)
- **Data source badge** -- whether the score used live, cached, or synthetic data

### Step 3: Connect a Web3 Wallet

Click "Connect Wallet" in the header. The app uses Web3Modal, which supports MetaMask, WalletConnect QR code, Coinbase Wallet, Rabby, and any EIP-6963-compatible browser wallet.

Make sure your wallet is connected to **BSC Testnet (Chain ID 97)**. The frontend will prompt you to switch networks if needed.

### Step 4: Submit an Offchain Attestation

Use the **Attestation Simulator** panel to submit a FICO-equivalent credit attestation. Enter a FICO score (300--850) and submit the transaction. This simulates a ZKredit attestation -- in production, a ZK verifier contract would call this after validating a Brevis or Primus proof.

Watch the composite score update in real time. Without an attestation, the onchain score is capped at 50% of the raw value (the thin-file cap). With a strong attestation, the composite score can reach the full range, unlocking undercollateralized lending terms.

### Step 5: Interact with the Lending Pool

Use the **Lending Interface** to deposit collateral, borrow against your credit score, and repay loans. The required collateral ratio adjusts dynamically based on your composite credit score:

| Composite Score | Collateral Required |
|---|---|
| 0--20 | 150% |
| 20--50 | 150% down to 120% |
| 50--70 | 120% down to 100% |
| 70--85 | 100% down to 85% |
| 85--100 | 85% down to 75% |

---

## Contract Deployment (Optional)

The contracts are already deployed and verified at the addresses listed above. To redeploy from scratch:

```bash
cd contracts

# Install dependencies
forge install

# Build
forge build

# Deploy to BSC Testnet (requires BSC_TESTNET_PRIVATE_KEY and ETHERSCAN_API_KEY in .env)
source ../.env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BSC_TESTNET_RPC \
  --broadcast \
  --verify \
  --with-gas-price 5000000000
```

After deployment, update the contract addresses in your `.env` file with the new addresses from the deployment output.

---

## Running Smart Contract Tests

```bash
cd contracts
forge test
```

This runs the full test suite: 79 tests covering all three contracts with 99.5% line coverage. Tests include composite score calculation, attestation lifecycle, identity persistence across wallets, collateral curve math, and lending operations.

To see verbose output with gas reports:

```bash
forge test -vvv --gas-report
```

---

## API Reference

The scoring pipeline exposes a single endpoint:

**`POST http://localhost:8000/score`**

Request body:

```json
{
  "address": "0x1234...abcd"
}
```

Response:

```json
{
  "address": "0x1234...abcd",
  "credit_score": 44,
  "composite_score": 22,
  "collateral_ratio_pct": 148.0,
  "chains_used": ["bsc", "ethereum", "arbitrum", "polygon", "optimism"],
  "data_completeness": "5-chain history",
  "data_source": "cached",
  "factors": [
    {"name": "Borrowing protocol activity (days)", "value": 12, "contribution": 0.35},
    ...
  ]
}
```

---

## Project Structure

```
credence-protocol/
├── bsc.address                     # Deployed contract addresses
├── .env.example                    # Environment variable template
├── data/
│   ├── queries/                    # SQL queries used for training data
│   └── raw/                        # Training CSVs (gitignored)
├── model/
│   ├── train.py                    # Training script (Phase 3, frozen)
│   ├── score.py                    # Inference module
│   ├── model.pkl                   # Frozen logistic regression model
│   ├── feature_config.json         # Feature bins, coefficients, display names
│   └── validation_report.md        # Model performance report
├── contracts/                      # Foundry project
│   ├── src/                        # Solidity source (3 contracts)
│   ├── test/                       # Forge tests (79 tests)
│   ├── script/Deploy.s.sol         # Deployment script
│   └── foundry.toml
├── pipeline/
│   ├── api.py                      # FastAPI POST /score
│   ├── push_score.py               # Contract interaction
│   ├── config.py                   # Environment config
│   ├── demo_wallets.json           # Cached wallet data for keyless demo
│   └── requirements.txt
├── frontend/                       # Vite + React
│   ├── src/                        # React components
│   └── package.json
└── docs/                           # Documentation
```

---

## Troubleshooting

**Frontend shows "Failed to fetch" or network error:**
Make sure the scoring backend is running on port 8000. The frontend proxies API calls to `http://localhost:8000`.

**"No module named 'pipeline'":**
Run the backend from the project root directory, not from inside `pipeline/`. The command `python3 -m uvicorn pipeline.api:app` requires the project root as the working directory.

**Wallet won't connect:**
Ensure your browser wallet is set to BSC Testnet (Chain ID 97). The frontend will prompt for a network switch, but some wallets require manual configuration. BSC Testnet RPC: `https://data-seed-prebsc-1-s1.binance.org:8545/`, Chain ID: `97`, Currency: `tBNB`.

**Contract transactions fail:**
BSC Testnet requires tBNB for gas. Get test tokens from the [BNB Testnet Faucet](https://testnet.bnbchain.org/faucet-smart).

**Forge tests won't run:**
Run `forge install` inside the `contracts/` directory first to fetch OpenZeppelin and forge-std dependencies.
