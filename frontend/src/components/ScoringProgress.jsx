import { useState, useEffect } from 'react';

/**
 * ScoringProgress — real-time progress indicator driven by SSE events
 * from the backend /score/stream endpoint.
 *
 * Props:
 *   isActive: boolean — whether scoring is in progress
 *   progress: object — map of completed event names from the SSE stream
 *     e.g. { bsc_start: true, bsc_done: true, crosschain_start: true, ... }
 */

const CHAINS = [
  { id: 'bsc',       name: 'BNB Chain',  short: 'BSC',  color: '#F0B90B', startEvent: 'bsc_start',         doneEvent: 'bsc_done' },
  { id: 'ethereum',  name: 'Ethereum',   short: 'ETH',  color: '#627EEA', startEvent: 'crosschain_start',  doneEvent: 'crosschain_done' },
  { id: 'arbitrum',  name: 'Arbitrum',   short: 'ARB',  color: '#28A0F0', startEvent: 'crosschain_start',  doneEvent: 'crosschain_done' },
  { id: 'polygon',   name: 'Polygon',    short: 'POLY', color: '#8247E5', startEvent: 'crosschain_start',  doneEvent: 'crosschain_done' },
  { id: 'optimism',  name: 'Optimism',   short: 'OP',   color: '#FF0420', startEvent: 'crosschain_start',  doneEvent: 'crosschain_done' },
];

const STEPS = [
  { label: 'Querying BNB Chain lending history...', doneEvent: 'bsc_done' },
  { label: 'Scanning cross-chain activity across 4 networks...', doneEvent: 'crosschain_done' },
  { label: 'Computing credit score...', doneEvent: 'model_done' },
  { label: 'Publishing score on-chain...', doneEvent: 'push_done' },
];

export default function ScoringProgress({ isActive, progress = {} }) {
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!isActive) {
      setElapsed(0);
      return;
    }
    const interval = setInterval(() => setElapsed(prev => prev + 1), 1000);
    return () => clearInterval(interval);
  }, [isActive]);

  if (!isActive) return null;

  // Determine which step is currently active based on real events
  let activeStepIdx = 0;
  for (let i = 0; i < STEPS.length; i++) {
    if (progress[STEPS[i].doneEvent]) {
      activeStepIdx = i + 1;
    }
  }
  // If result arrived, all steps are done
  if (progress.result) activeStepIdx = STEPS.length;

  return (
    <div className="max-w-2xl mx-auto px-6 py-10">
      <div className="bg-bg-card border border-border rounded-xl p-6">
        <h3 className="text-sm font-medium text-text-secondary mb-1">
          Analyzing Wallet
        </h3>
        <p className="text-xs text-text-muted mb-6">
          Querying 5 blockchains and running credit model...
        </p>

        {/* Live network map */}
        <div className="mb-6 p-4 bg-bg-primary/80 rounded-lg border border-border/50">
          <div className="flex items-center justify-center gap-3 flex-wrap">
            {CHAINS.map((chain) => {
              const isScanning = progress[chain.startEvent] && !progress[chain.doneEvent];
              const isDone = !!progress[chain.doneEvent];
              const isPending = !progress[chain.startEvent];

              return (
                <div key={chain.id} className="flex flex-col items-center gap-1.5">
                  <div
                    className={`w-10 h-10 rounded-full flex items-center justify-center text-xs font-bold transition-all duration-500 ${
                      isDone
                        ? 'border-2 scale-100'
                        : isScanning
                        ? 'border-2 scale-110'
                        : 'border border-border/50 scale-90 opacity-40'
                    }`}
                    style={{
                      borderColor: isPending ? undefined : chain.color,
                      backgroundColor: isDone ? `${chain.color}20` : 'transparent',
                      color: isPending ? 'var(--color-text-muted)' : chain.color,
                    }}
                  >
                    {isDone ? (
                      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                      </svg>
                    ) : isScanning ? (
                      <div
                        className="w-2.5 h-2.5 rounded-full pulse-dot"
                        style={{ backgroundColor: chain.color }}
                      />
                    ) : (
                      <span className="text-[10px]">{chain.short}</span>
                    )}
                  </div>

                  <span
                    className={`text-[10px] font-mono transition-colors duration-300 ${
                      isDone ? 'text-text-secondary' : isScanning ? 'text-text-primary' : 'text-text-muted/40'
                    }`}
                  >
                    {chain.short}
                  </span>

                  <span
                    className={`text-[9px] h-3 transition-opacity duration-300 ${
                      isDone ? 'text-accent' : isScanning ? 'text-text-muted' : 'opacity-0'
                    }`}
                  >
                    {isDone ? 'done' : isScanning ? 'scanning...' : ''}
                  </span>
                </div>
              );
            })}
          </div>
        </div>

        {/* Pipeline steps */}
        <div className="space-y-4">
          {STEPS.map((step, i) => {
            const isComplete = i < activeStepIdx;
            const isCurrent = i === activeStepIdx && i < STEPS.length;

            return (
              <div key={i} className="flex items-start gap-3">
                <div className="mt-0.5 flex-shrink-0">
                  {isComplete ? (
                    <div className="w-5 h-5 rounded-full bg-accent flex items-center justify-center check-in">
                      <svg className="w-3 h-3 text-bg-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                      </svg>
                    </div>
                  ) : isCurrent ? (
                    <div className="w-5 h-5 rounded-full border-2 border-accent flex items-center justify-center">
                      <div className="w-2 h-2 rounded-full bg-accent pulse-dot" />
                    </div>
                  ) : (
                    <div className="w-5 h-5 rounded-full border-2 border-border" />
                  )}
                </div>

                <span
                  className={`text-sm ${
                    isComplete ? 'text-accent' : isCurrent ? 'text-text-primary' : 'text-text-muted'
                  }`}
                >
                  {step.label}
                </span>
              </div>
            );
          })}
        </div>

        <div className="mt-6 text-xs text-text-muted text-center font-mono">
          {elapsed}s elapsed
        </div>
      </div>
    </div>
  );
}
