import { useState, useEffect } from 'react';

const STEPS = [
  { label: 'Querying BNB Chain lending history...', duration: 35 },
  { label: 'Scanning cross-chain activity across 4 networks...', duration: 35 },
  { label: 'Computing credit score...', duration: 5 },
  { label: 'Publishing score on-chain...', duration: null }, // no timer — waits for API
];

export default function ScoringProgress({ isActive }) {
  const [activeStep, setActiveStep] = useState(0);
  const [elapsed, setElapsed] = useState(0);

  // Timer: advances steps based on estimated durations
  useEffect(() => {
    if (!isActive) {
      setActiveStep(0);
      setElapsed(0);
      return;
    }

    const interval = setInterval(() => {
      setElapsed((prev) => {
        const next = prev + 1;
        // Check if current step's estimated duration has passed
        let cumulative = 0;
        for (let i = 0; i < STEPS.length; i++) {
          if (STEPS[i].duration === null) break;
          cumulative += STEPS[i].duration;
          if (next >= cumulative && i >= activeStep) {
            setActiveStep(Math.min(i + 1, STEPS.length - 1));
          }
        }
        return next;
      });
    }, 1000);

    return () => clearInterval(interval);
  }, [isActive, activeStep]);

  if (!isActive) return null;

  return (
    <div className="max-w-lg mx-auto px-6 py-10">
      <div className="bg-bg-card border border-border rounded-xl p-6">
        <h3 className="text-sm font-medium text-text-secondary mb-1">
          Analyzing Wallet
        </h3>
        <p className="text-xs text-text-muted mb-6">
          Querying 5 blockchains and running credit model...
        </p>

        <div className="space-y-4">
          {STEPS.map((step, i) => {
            const isComplete = i < activeStep;
            const isCurrent = i === activeStep;
            const isPending = i > activeStep;

            return (
              <div key={i} className="flex items-start gap-3">
                {/* Status indicator */}
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

                {/* Step label */}
                <span
                  className={`text-sm ${
                    isComplete
                      ? 'text-accent'
                      : isCurrent
                      ? 'text-text-primary'
                      : 'text-text-muted'
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
