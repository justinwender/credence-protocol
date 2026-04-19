import { useState, useCallback } from 'react';
import './web3modal.js';  // Initialize Web3Modal (must be imported before hooks)
import Header from './components/Header.jsx';
import WalletSearch from './components/WalletSearch.jsx';
import ScoringProgress from './components/ScoringProgress.jsx';
import CompositeScore from './components/CompositeScore.jsx';
import ScoreComponents from './components/ScoreComponents.jsx';
import FactorBreakdown from './components/FactorBreakdown.jsx';
import CreditReport from './components/CreditReport.jsx';
import AttestationSimulator from './components/AttestationSimulator.jsx';
import LendingInterface from './components/LendingInterface.jsx';
import useWallet from './hooks/useWallet.js';
import useContracts from './hooks/useContracts.js';
import { API_BASE } from './config.js';

export default function App() {
  const { account, isConnecting, connect, disconnect, walletProvider } = useWallet();
  const { oracle, pool, registry, readOracle, readPool, readRegistry } = useContracts(account, walletProvider);

  // Scoring state
  const [isScoring, setIsScoring] = useState(false);
  const [scoreResult, setScoreResult] = useState(null);
  const [scoreError, setScoreError] = useState(null);
  const [searchedAddress, setSearchedAddress] = useState(null);

  // Credit report expansion state
  const [reportExpanded, setReportExpanded] = useState(false);

  // On-chain composite state (refreshed after scoring or attestation)
  const [compositeData, setCompositeData] = useState(null);

  const refreshComposite = useCallback(async (address) => {
    if (!readOracle || !readPool || !address) return;
    try {
      const composite = await readOracle.getCompositeScore(address);
      const profile = await readOracle.getFullProfile(address);
      const ratioBps = await readPool.getBorrowerCollateralRatioBps(address);

      setCompositeData({
        compositeScore: Number(composite),
        onchainScore: Number(profile[0]),
        historicalOnchainScore: Number(profile[1]),
        offchainScore: Number(profile[2]),
        chainsUsed: Number(profile[4]),
        hasAttestation: Boolean(profile[5]),
        isUsingInheritedScore: Boolean(profile[6]),
        collateralRatioBps: Number(ratioBps),
      });
    } catch (err) {
      console.error('Failed to refresh composite:', err);
    }
  }, [readOracle, readPool, readRegistry]);

  // Progress state for the chain map (real SSE events from backend)
  const [progress, setProgress] = useState({});

  const handleSearch = useCallback(async (address) => {
    setIsScoring(true);
    setScoreResult(null);
    setScoreError(null);
    setSearchedAddress(address);
    setCompositeData(null);
    setProgress({});
    setReportExpanded(false);

    try {
      // Try SSE streaming endpoint first (real-time progress)
      let resp = await fetch(`${API_BASE}/score/stream`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address }),
      });

      // Fallback to JSON endpoint if streaming isn't available (old backend)
      if (resp.status === 404) {
        setProgress({ bsc_start: true, crosschain_start: true });
        resp = await fetch(`${API_BASE}/score`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ address }),
        });
        if (!resp.ok) {
          const errData = await resp.json().catch(() => ({}));
          throw new Error(errData.detail || `HTTP ${resp.status}`);
        }
        const data = await resp.json();
        setScoreResult(data);
        setProgress({ bsc_start: true, bsc_done: true, crosschain_start: true, crosschain_done: true, model_done: true, push_done: true, result: true });
        await refreshComposite(address);
        return;
      }

      if (!resp.ok) {
        const errData = await resp.json().catch(() => ({}));
        throw new Error(errData.detail || `HTTP ${resp.status}`);
      }

      // Read SSE stream for real-time progress
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue;
          try {
            const event = JSON.parse(line.slice(6));

            setProgress(prev => ({ ...prev, [event.event]: true, lastEvent: event }));

            if (event.event === 'error') {
              throw new Error(event.message);
            }

            if (event.event === 'result') {
              setScoreResult(event.data);
              await refreshComposite(address);
            }
          } catch (parseErr) {
            if (parseErr.message && !parseErr.message.includes('JSON')) {
              throw parseErr;
            }
          }
        }
      }
    } catch (err) {
      // Friendly message for cold-start / network errors (Render free tier sleeps after inactivity)
      const msg = err.message || '';
      if (msg.includes('Failed to fetch') || msg.includes('NetworkError') || msg.includes('network') || msg === 'Not Found') {
        setScoreError('Backend is starting up (free tier cold start). Please wait 30-60 seconds and try again.');
      } else {
        setScoreError(msg);
      }
    } finally {
      setIsScoring(false);
    }
  }, [refreshComposite]);

  const handleAttestationSubmitted = useCallback(async () => {
    if (searchedAddress) {
      setTimeout(() => refreshComposite(searchedAddress), 2000);
    }
  }, [searchedAddress, refreshComposite]);

  // Reset to home screen
  const handleReset = useCallback(() => {
    setIsScoring(false);
    setScoreResult(null);
    setScoreError(null);
    setSearchedAddress(null);
    setCompositeData(null);
    setReportExpanded(false);
  }, []);

  const hasScore = scoreResult !== null;

  // Data source badge helper
  const dataSourceBadge = scoreResult?.data_source === 'live'
    ? { text: 'Live data', color: 'text-accent', bg: 'border-accent/30' }
    : scoreResult?.data_source === 'cached'
    ? { text: 'Demo: cached data', color: 'text-info', bg: 'border-info/30' }
    : scoreResult?.data_source === 'synthetic'
    ? { text: 'Demo: synthetic profile', color: 'text-warning', bg: 'border-warning/30' }
    : null;

  return (
    <div className="min-h-screen flex flex-col">
      {/* Testnet warning banner */}
      <div className="bg-warning/10 border-b border-warning/20 px-4 py-1.5 text-center">
        <p className="text-xs text-warning">
          ⚠ Testnet Demo — Smart contracts are unaudited. Use only with BSC testnet wallets. Do not send real funds.
        </p>
      </div>

      <Header
        account={account}
        onConnect={connect}
        onDisconnect={disconnect}
        isConnecting={isConnecting}
        onReset={handleReset}
      />

      <WalletSearch
        onSearch={handleSearch}
        isLoading={isScoring}
        account={account}
      />

      {/* Loading state: credit-card-application-style progress */}
      <ScoringProgress isActive={isScoring} progress={progress} />

      {/* Error state */}
      {scoreError && !isScoring && (
        <div className="max-w-2xl mx-auto px-6 py-4">
          <div className="bg-bg-card border border-danger/30 rounded-lg p-4 text-center">
            <p className="text-danger text-sm font-medium">Scoring failed</p>
            <p className="text-text-muted text-xs mt-1">{scoreError}</p>
          </div>
        </div>
      )}

      {/* Score dashboard */}
      {hasScore && !isScoring && (
        <div className="flex-1 px-6 pb-8">
          {/* Address bar + data source badge */}
          <div className="max-w-6xl mx-auto mb-6">
            <div className="flex items-center gap-2 text-xs text-text-muted flex-wrap">
              <span>Wallet:</span>
              <span className="font-mono text-text-secondary">{scoreResult.address}</span>
              <a
                href={`https://testnet.bscscan.com/address/${scoreResult.address}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-info hover:underline"
              >
                BscScan
              </a>
              {scoreResult.tx_hash && (
                <a
                  href={`https://testnet.bscscan.com/tx/${scoreResult.tx_hash}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-info hover:underline"
                >
                  Score TX
                </a>
              )}
              {dataSourceBadge && (
                <span className={`ml-auto px-2 py-0.5 rounded text-xs border ${dataSourceBadge.color} ${dataSourceBadge.bg}`}>
                  {dataSourceBadge.text}
                </span>
              )}
            </div>
          </div>

          {/* Activity tier notice */}
          {scoreResult.activity_note && scoreResult.activity_tier !== 'full_history' && (
            <div className="max-w-6xl mx-auto mb-4">
              <div className={`rounded-lg px-4 py-3 text-sm border ${
                scoreResult.activity_tier === 'no_activity'
                  ? 'bg-danger/10 border-danger/30 text-danger'
                  : scoreResult.activity_tier === 'no_lending_history'
                  ? 'bg-warning/10 border-warning/30 text-warning'
                  : 'bg-info/10 border-info/30 text-info'
              }`}>
                {scoreResult.activity_note}
                {scoreResult.raw_model_score != null && scoreResult.raw_model_score !== scoreResult.credit_score && (
                  <span className="text-text-muted ml-2">
                    (Raw model score: {scoreResult.raw_model_score}, adjusted to {scoreResult.credit_score})
                  </span>
                )}
              </div>
            </div>
          )}

          {/* Main grid: score + factors on left, attestation + lending on right */}
          <div className="max-w-6xl mx-auto grid grid-cols-1 lg:grid-cols-5 gap-6">
            {/* Left column: Score dashboard (3/5 width) */}
            <div className="lg:col-span-3 space-y-6">
              {/* Top row: composite gauge (hero) + score components (inputs) */}
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <CompositeScore
                  compositeScore={compositeData?.compositeScore ?? scoreResult.composite_score}
                  collateralRatioBps={compositeData?.collateralRatioBps ?? scoreResult.collateral_ratio_bps}
                />

                <ScoreComponents
                  onchainScore={scoreResult.credit_score}
                  chainsUsed={scoreResult.chains_used}
                  dataCompleteness={scoreResult.data_completeness}
                  hasAttestation={compositeData?.hasAttestation ?? false}
                  offchainScore={compositeData?.offchainScore ?? 0}
                  isUsingInheritedScore={compositeData?.isUsingInheritedScore ?? false}
                />
              </div>

              {/* Factor breakdown */}
              <div className="bg-bg-card border border-border rounded-xl p-6">
                <h2 className="text-xs font-medium text-text-muted uppercase tracking-wider mb-4">
                  Score Factor Breakdown
                </h2>
                <FactorBreakdown factors={scoreResult.factor_breakdown} />
              </div>

              {/* Full credit report (expandable) */}
              <CreditReport
                factors={scoreResult.factor_breakdown}
                isExpanded={reportExpanded}
                onToggle={() => setReportExpanded((prev) => !prev)}
              />
            </div>

            {/* Right column: attestation + lending (2/5 width) */}
            <div className="lg:col-span-2 space-y-6">
              <AttestationSimulator
                walletAddress={searchedAddress}
                registry={registry}
                onAttestationSubmitted={handleAttestationSubmitted}
              />

              <LendingInterface
                pool={pool}
                readPool={readPool}
                walletAddress={account}
                compositeScore={compositeData?.compositeScore}
              />
            </div>
          </div>
        </div>
      )}

      {/* Empty state */}
      {!hasScore && !isScoring && !scoreError && (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-md">
            <div className="w-16 h-16 rounded-2xl bg-bg-card border border-border flex items-center justify-center mx-auto mb-4">
              <svg className="w-8 h-8 text-text-muted" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
              </svg>
            </div>
            <h2 className="text-lg text-text-secondary font-medium mb-2">
              Search a wallet to begin
            </h2>
            <p className="text-sm text-text-muted leading-relaxed">
              Enter any BNB Chain wallet address or ENS name to generate a
              real-time credit score based on onchain lending behavior across
              5 blockchains.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
