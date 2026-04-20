import { useState } from 'react';
import { ethers } from 'ethers';

const SLIDER_TRACK =
  'w-full h-1.5 rounded-full appearance-none cursor-pointer bg-border accent-accent';

function SliderField({ label, value, onChange, min, max, suffix = '', step = 1 }) {
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between">
        <label className="text-xs text-text-secondary uppercase tracking-wider">
          {label}
        </label>
        <span className="font-mono text-sm text-text-primary">
          {value}
          {suffix}
        </span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className={SLIDER_TRACK}
      />
      <div className="flex justify-between text-[10px] text-text-secondary font-mono">
        <span>{min}{suffix}</span>
        <span>{max}{suffix}</span>
      </div>
    </div>
  );
}

function NumberField({ label, value, onChange, min = 0, max = 999, suffix = '' }) {
  return (
    <div className="space-y-1">
      <label className="text-xs text-text-secondary uppercase tracking-wider block">
        {label}
      </label>
      <div className="flex items-center gap-2">
        <input
          type="number"
          min={min}
          max={max}
          value={value}
          onChange={(e) => onChange(Math.max(min, Math.min(max, Number(e.target.value))))}
          className="w-full bg-bg-primary border border-border rounded px-3 py-1.5 font-mono text-sm text-text-primary focus:outline-none focus:border-accent"
        />
        {suffix && (
          <span className="text-xs text-text-secondary whitespace-nowrap">{suffix}</span>
        )}
      </div>
    </div>
  );
}

export default function AttestationSimulator({ walletAddress, registry, onAttestationSubmitted }) {
  const [compositeScore, setCompositeScore] = useState(700);
  const [paymentHistory, setPaymentHistory] = useState(85);
  const [creditUtil, setCreditUtil] = useState(25);
  const [historyMonths, setHistoryMonths] = useState(60);
  const [numAccounts, setNumAccounts] = useState(5);
  const [hardInquiries, setHardInquiries] = useState(1);
  const [identityLabel, setIdentityLabel] = useState('demo-identity-001');

  const [loading, setLoading] = useState(false);
  const [feedback, setFeedback] = useState(null); // { type: 'success'|'error', message }

  const identityHash = ethers.keccak256(ethers.toUtf8Bytes(identityLabel));

  async function handleClear() {
    if (!registry || !walletAddress) return;
    setLoading(true);
    setFeedback(null);
    try {
      const tx = await registry.clearAttestation(walletAddress);
      setFeedback({ type: 'pending', message: `Clearing: ${tx.hash.slice(0, 18)}...` });
      await tx.wait();
      setFeedback({ type: 'success', message: 'Attestation cleared' });
      onAttestationSubmitted?.();
    } catch (err) {
      const msg = err?.reason || err?.shortMessage || err?.message || 'Transaction failed';
      setFeedback({ type: 'error', message: msg });
    } finally {
      setLoading(false);
    }
  }

  async function handleSubmit() {
    if (!registry || !walletAddress) return;
    setLoading(true);
    setFeedback(null);

    try {
      const attestation = {
        identityHash,
        paymentHistoryScore: paymentHistory,
        creditUtilizationPct: creditUtil,
        creditHistoryMonths: historyMonths,
        numberOfAccounts: numAccounts,
        hardInquiries,
        compositeScore,
        isVerified: true,
        timestamp: 0,
      };

      const tx = await registry.setAttestation(walletAddress, attestation);
      setFeedback({ type: 'pending', message: `Tx submitted: ${tx.hash.slice(0, 18)}...` });
      await tx.wait();
      setFeedback({ type: 'success', message: 'Attestation recorded on-chain' });
      onAttestationSubmitted?.();
    } catch (err) {
      const msg = err?.reason || err?.shortMessage || err?.message || 'Transaction failed';
      setFeedback({ type: 'error', message: msg });
    } finally {
      setLoading(false);
    }
  }

  // FICO color hint
  const ficoColor =
    compositeScore >= 740 ? 'text-accent' :
    compositeScore >= 670 ? 'text-warning' :
    'text-danger';

  return (
    <div className="rounded-lg border border-border bg-bg-card overflow-hidden">
      {/* Header */}
      <div className="px-4 py-3 border-b border-border">
        <h3 className="text-text-primary text-sm font-semibold tracking-wide uppercase">
          Offchain Credit Attestation (Demo)
        </h3>
        <p className="text-text-secondary text-xs mt-0.5">
          Simulates ZKredit &mdash; in production, these come from ZK proofs
        </p>
      </div>

      {!registry ? (
        <div className="px-4 py-8 text-center text-text-secondary text-sm">
          Connect wallet to submit attestations
        </div>
      ) : (
        <div className="p-4 space-y-4">
          {/* FICO composite */}
          <SliderField
            label="Composite FICO Score"
            value={compositeScore}
            onChange={setCompositeScore}
            min={300}
            max={850}
          />
          <div className="text-center -mt-2">
            <span className={`font-mono text-lg font-bold ${ficoColor}`}>
              {compositeScore}
            </span>
            <span className="text-text-secondary text-xs ml-2">
              {compositeScore >= 740 ? 'Excellent' :
               compositeScore >= 670 ? 'Good' :
               compositeScore >= 580 ? 'Fair' : 'Poor'}
            </span>
          </div>

          <div className="h-px bg-border" />

          {/* Sub-factors */}
          <SliderField
            label="Payment History Score"
            value={paymentHistory}
            onChange={setPaymentHistory}
            min={0}
            max={100}
          />

          <SliderField
            label="Credit Utilization"
            value={creditUtil}
            onChange={setCreditUtil}
            min={0}
            max={100}
            suffix="%"
          />

          <div className="grid grid-cols-3 gap-3">
            <NumberField
              label="History (months)"
              value={historyMonths}
              onChange={setHistoryMonths}
              min={0}
              max={600}
            />
            <NumberField
              label="Accounts"
              value={numAccounts}
              onChange={setNumAccounts}
              min={0}
              max={255}
            />
            <NumberField
              label="Hard Inquiries"
              value={hardInquiries}
              onChange={setHardInquiries}
              min={0}
              max={255}
            />
          </div>

          <div className="h-px bg-border" />

          {/* Identity hash */}
          <div className="space-y-1">
            <label className="text-xs text-text-secondary uppercase tracking-wider block">
              Identity Hash Label
            </label>
            <input
              type="text"
              value={identityLabel}
              onChange={(e) => setIdentityLabel(e.target.value)}
              className="w-full bg-bg-primary border border-border rounded px-3 py-1.5 text-sm text-text-primary focus:outline-none focus:border-accent"
              placeholder="demo-identity-001"
            />
            <p className="font-mono text-[10px] text-text-secondary break-all">
              keccak256: {identityHash}
            </p>
          </div>

          {/* Submit */}
          <button
            onClick={handleSubmit}
            disabled={loading || !walletAddress}
            className={`w-full py-2 rounded font-semibold text-sm tracking-wide uppercase transition-colors ${
              loading
                ? 'bg-border text-text-secondary cursor-wait'
                : 'bg-accent/20 text-accent hover:bg-accent/30 border border-accent/40'
            }`}
          >
            {loading ? 'Confirming...' : 'Submit Attestation'}
          </button>

          <button
            onClick={handleClear}
            disabled={loading || !walletAddress}
            className="w-full py-1.5 rounded text-xs text-text-muted hover:text-danger hover:bg-danger/10 border border-border hover:border-danger/30 transition-colors"
          >
            Clear Attestation
          </button>

          {/* Feedback */}
          {feedback && (
            <div
              className={`text-xs px-3 py-2 rounded font-mono ${
                feedback.type === 'success'
                  ? 'bg-accent/10 text-accent'
                  : feedback.type === 'error'
                  ? 'bg-danger/10 text-danger'
                  : 'bg-warning/10 text-warning'
              }`}
            >
              {feedback.message}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
