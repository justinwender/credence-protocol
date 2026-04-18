# Credence Protocol

Onchain credit scoring and undercollateralized lending on BNB Chain. Credence blends two independent credit signals — onchain wallet behavior across 5 blockchains and ZK-verified offchain credit attestations — into a composite score that determines collateral requirements on a continuous curve. The result: creditworthy borrowers access capital-efficient lending terms that neither traditional finance nor existing DeFi protocols can offer alone.

**Credence is the first protocol to bring traditional credit scoring methodology onchain, because the trillion-dollar lending market won't move to DeFi until DeFi can underwrite like the real world does.**

No external API keys are required to run the demo. See [docs/TECHNICAL.md](docs/TECHNICAL.md) for details on live vs. demo scoring modes.

## Deployed Contracts (BSC Testnet)

| Contract | Address | Verified |
|---|---|---|
| OffchainAttestationRegistry | [`0x7574...bf6e0`](https://testnet.bscscan.com/address/0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0) | Yes |
| CreditOracle | [`0x1625...37B7`](https://testnet.bscscan.com/address/0x16253605BEef191024C950E00D829E0D410637B7) | Yes |
| LendingPool | [`0x159F...0edA`](https://testnet.bscscan.com/address/0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA) | Yes |

## Quick Start

```bash
git clone <repo-url> && cd credence-protocol
pip install -r pipeline/requirements.txt
cd frontend && npm install && cd ..
cp .env.example .env

# Terminal 1: Backend
python3 -m uvicorn pipeline.api:app --host 0.0.0.0 --port 8000

# Terminal 2: Frontend
cd frontend && npm run dev
```

Open [http://localhost:3000](http://localhost:3000). Full setup details in [TECHNICAL.md](docs/TECHNICAL.md).

## Documentation

- [PROJECT.md](docs/PROJECT.md) — Project overview (start here)
- [TECHNICAL.md](docs/TECHNICAL.md) — Architecture and reproduction instructions
- [EXTRAS.md](docs/EXTRAS.md) — Demo video and AI build log

## License

MIT
