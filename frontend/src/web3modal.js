/**
 * Web3Modal configuration — provides the standard multi-wallet connection
 * modal (MetaMask, WalletConnect, Coinbase Wallet, Ledger, etc.)
 */
import { createWeb3Modal, defaultConfig } from '@web3modal/ethers/react';

// WalletConnect Cloud project ID
// For production, register at https://cloud.walletconnect.com
// This is a public demo project ID — rate-limited but functional
const WALLETCONNECT_PROJECT_ID = '3e45b9ea29dd7b20e2e5e48e62e5e5d1';

const bscTestnet = {
  chainId: 97,
  name: 'BSC Testnet',
  currency: 'tBNB',
  explorerUrl: 'https://testnet.bscscan.com',
  rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545/',
};

const metadata = {
  name: 'Credence Protocol',
  description: 'Onchain Credit Scoring & Undercollateralized Lending',
  url: 'https://credence-protocol.vercel.app',
  icons: [],
};

const ethersConfig = defaultConfig({
  metadata,
  enableEIP6963: true,    // auto-detect installed wallets
  enableInjected: true,   // MetaMask and other injected wallets
  enableCoinbase: true,   // Coinbase Wallet
});

createWeb3Modal({
  ethersConfig,
  chains: [bscTestnet],
  defaultChain: bscTestnet,
  projectId: WALLETCONNECT_PROJECT_ID,
  enableAnalytics: false,
  themeMode: 'dark',
  themeVariables: {
    '--w3m-accent': '#10b981',
    '--w3m-border-radius-master': '2px',
  },
});
