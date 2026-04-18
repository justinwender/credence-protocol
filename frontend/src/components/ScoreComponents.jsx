/**
 * Score Components card: shows the two inputs that feed into the composite
 * score (onchain score + offchain attestation status). Visually communicates
 * that these are inputs, not standalone metrics. When no attestation exists,
 * nudges the user toward the attestation simulator.
 */
export default function ScoreComponents({
  onchainScore = 0,
  chainsUsed = 1,
  dataCompleteness = 'BNB Chain only',
  hasAttestation = false,
  offchainScore = 0,
  isUsingInheritedScore = false,
}) {
  const isMultiChain = dataCompleteness.toLowerCase().includes('5-chain')
    || dataCompleteness.toLowerCase().includes('chain history');

  return (
    <div className="bg-bg-card border border-border rounded-xl p-6 flex flex-col gap-4">
      <h2 className="text-xs font-medium text-text-muted uppercase tracking-wider">
        Score Components
      </h2>

      {/* Onchain score */}
      <div className="flex items-center justify-between">
        <div>
          <span className="text-text-secondary text-sm">Onchain Score</span>
          <div className="flex items-center gap-2 mt-0.5">
            <span className="font-mono text-2xl font-bold text-text-primary">
              {onchainScore}
            </span>
            <span className="text-text-muted text-xs">/100</span>
          </div>
        </div>
        <div className="text-right">
          <div className="flex items-center gap-1.5 justify-end">
            <span
              className={`inline-block w-2 h-2 rounded-full ${
                isMultiChain ? 'bg-accent' : 'bg-warning'
              }`}
            />
            <span
              className={`text-xs ${
                isMultiChain ? 'text-accent' : 'text-warning'
              }`}
            >
              {dataCompleteness}
            </span>
          </div>
          {isUsingInheritedScore && (
            <span className="text-xs text-warning mt-1 block">
              Inherited from prior wallet
            </span>
          )}
        </div>
      </div>

      {/* Divider */}
      <div className="border-t border-border" />

      {/* Offchain attestation status */}
      <div>
        <span className="text-text-secondary text-sm">Offchain Attestation</span>
        <div className="mt-1.5">
          {hasAttestation ? (
            <div className="flex items-center gap-2">
              <svg
                className="w-4 h-4 text-accent flex-shrink-0"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2.5}
              >
                <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
              </svg>
              <span className="text-sm text-accent font-medium">
                Verified (score: {offchainScore}/100)
              </span>
            </div>
          ) : (
            <div className="bg-bg-primary/60 border border-border rounded-lg p-3">
              <div className="flex items-start gap-2">
                <svg
                  className="w-4 h-4 text-warning flex-shrink-0 mt-0.5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  strokeWidth={2}
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"
                  />
                </svg>
                <div>
                  <p className="text-sm text-warning font-medium">
                    No offchain attestation
                  </p>
                  <p className="text-xs text-text-muted mt-1 leading-relaxed">
                    Add offchain credit verification below to unlock
                    undercollateralized lending terms. Your onchain score alone
                    is capped at 50% of its raw value.
                  </p>
                </div>
              </div>
              <div className="mt-2 flex justify-center">
                <svg className="w-4 h-4 text-text-muted animate-bounce" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
                </svg>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
