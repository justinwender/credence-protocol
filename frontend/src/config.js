// Credence Protocol — Frontend Configuration
// Contract addresses from BSC testnet deployment (Phase 4)

export const BSC_TESTNET_CHAIN_ID = 97;
export const BSC_TESTNET_RPC = 'https://data-seed-prebsc-1-s1.binance.org:8545/';

export const CONTRACTS = {
  registry: '0x7574581d7D872F605FD760Bb1BAcc69a551bf6e0',
  oracle:   '0x16253605BEef191024C950E00D829E0D410637B7',
  pool:     '0x159F82bFbBc4D5f7C962b5C4667ECA0004030edA',
};

// Scoring API (FastAPI backend)
// In production: set VITE_API_URL to the deployed backend URL (e.g., https://credence-api.onrender.com)
// In development: empty string means Vite dev server proxies to localhost:8000
export const API_BASE = import.meta.env.VITE_API_URL || '';

// ENS resolution uses Ethereum mainnet (ENS is on L1)
// Using Cloudflare's public Ethereum gateway — no API key, reliable
export const ENS_RPC = 'https://cloudflare-eth.com';

// BSC testnet network config for MetaMask
export const BSC_TESTNET_NETWORK = {
  chainId: `0x${BSC_TESTNET_CHAIN_ID.toString(16)}`,
  chainName: 'BSC Testnet',
  nativeCurrency: { name: 'tBNB', symbol: 'tBNB', decimals: 18 },
  rpcUrls: [BSC_TESTNET_RPC],
  blockExplorerUrls: ['https://testnet.bscscan.com'],
};

// Collateral ratio labels for display
export function getCollateralLabel(bps) {
  if (bps >= 15000) return { text: 'Standard DeFi', color: 'text-danger' };
  if (bps >= 12000) return { text: 'Improved', color: 'text-warning' };
  if (bps >= 10000) return { text: 'Competitive', color: 'text-yellow-400' };
  if (bps >= 8500)  return { text: 'Undercollateralized', color: 'text-accent' };
  return               { text: 'Premium', color: 'text-accent-bright' };
}

// Score color for gauge
export function getScoreColor(score) {
  if (score <= 30) return '#ef4444';
  if (score <= 60) return '#f59e0b';
  if (score <= 80) return '#10b981';
  return '#22c55e';
}
