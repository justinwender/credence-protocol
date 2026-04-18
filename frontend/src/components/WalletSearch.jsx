import { useState } from 'react';
import { ethers } from 'ethers';
import { ENS_RPC } from '../config.js';

export default function WalletSearch({ onSearch, isLoading, account }) {
  const [input, setInput] = useState('');
  const [resolving, setResolving] = useState(false);
  const [resolvedInfo, setResolvedInfo] = useState(null);

  const handleSubmit = async (e) => {
    e.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || isLoading) return;

    let address = trimmed;

    // ENS resolution: if input contains a dot, try resolving
    if (trimmed.includes('.')) {
      setResolving(true);
      setResolvedInfo(null);
      try {
        const provider = new ethers.JsonRpcProvider(ENS_RPC);
        const resolved = await provider.resolveName(trimmed);
        if (resolved) {
          address = resolved;
          setResolvedInfo({ ens: trimmed, address: resolved });
        } else {
          setResolvedInfo({ ens: trimmed, error: 'Could not resolve ENS name' });
          setResolving(false);
          return;
        }
      } catch (err) {
        console.warn('ENS resolution failed:', err.message);
        setResolvedInfo({ ens: trimmed, error: `ENS resolution failed: ${err.message}` });
        setResolving(false);
        return;
      }
      setResolving(false);
    }

    // Validate address format
    if (!address.startsWith('0x') || address.length !== 42) {
      setResolvedInfo({ error: 'Invalid address format (expected 0x + 40 hex characters)' });
      return;
    }

    onSearch(address);
  };

  const handleScoreMyWallet = () => {
    if (account && !isLoading) {
      setInput(account);
      setResolvedInfo(null);
      onSearch(account);
    }
  };

  return (
    <div className="px-6 py-6">
      <form onSubmit={handleSubmit} className="max-w-2xl mx-auto">
        <label className="block text-sm text-text-secondary mb-2">
          Search any wallet to view its credit score
        </label>
        <div className="flex gap-2">
          <div className="flex-1 relative">
            <input
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder="Enter wallet address (0x...) or ENS name (vitalik.eth)"
              disabled={isLoading}
              className="w-full px-4 py-3 bg-bg-card border border-border rounded-lg text-text-primary font-mono text-sm
                         placeholder:text-text-muted focus:outline-none focus:border-border-active focus:ring-1 focus:ring-border-active
                         disabled:opacity-50 transition-colors"
            />
            {resolving && (
              <div className="absolute right-3 top-1/2 -translate-y-1/2">
                <div className="w-4 h-4 border-2 border-accent border-t-transparent rounded-full animate-spin" />
              </div>
            )}
          </div>
          <button
            type="submit"
            disabled={isLoading || resolving || !input.trim()}
            className="px-6 py-3 bg-accent text-bg-primary font-medium text-sm rounded-lg
                       hover:bg-accent-bright transition-colors disabled:opacity-50 whitespace-nowrap"
          >
            {isLoading ? 'Scoring...' : 'Score Wallet'}
          </button>
        </div>

        {/* Score My Wallet button — only when wallet is connected */}
        {account && !isLoading && (
          <button
            type="button"
            onClick={handleScoreMyWallet}
            className="mt-2 text-xs text-accent hover:text-accent-bright transition-colors underline underline-offset-2"
          >
            Score my connected wallet ({account.slice(0, 6)}...{account.slice(-4)})
          </button>
        )}

        {resolvedInfo && (
          <div className="mt-2 text-xs">
            {resolvedInfo.error ? (
              <span className="text-danger">{resolvedInfo.error}</span>
            ) : (
              <span className="text-text-secondary">
                <span className="text-accent">{resolvedInfo.ens}</span>
                {' → '}
                <span className="font-mono">{resolvedInfo.address}</span>
              </span>
            )}
          </div>
        )}
      </form>
    </div>
  );
}
