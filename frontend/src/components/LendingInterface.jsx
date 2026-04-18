import { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';

function fmt(wei) {
  const val = ethers.formatEther(wei);
  return parseFloat(val).toFixed(4);
}

function StatRow({ label, value, unit = 'tBNB', accent = false }) {
  return (
    <div className="flex items-center justify-between py-1">
      <span className="text-text-secondary text-xs uppercase tracking-wider">{label}</span>
      <span className={`font-mono text-sm ${accent ? 'text-accent' : 'text-text-primary'}`}>
        {value} <span className="text-text-secondary text-xs">{unit}</span>
      </span>
    </div>
  );
}

export default function LendingInterface({ pool, readPool, walletAddress, compositeScore }) {
  // Pool-level stats
  const [totalLiquidity, setTotalLiquidity] = useState(null);
  const [totalBorrowed, setTotalBorrowed] = useState(null);

  // Borrower stats
  const [borrowed, setBorrowed] = useState(null);
  const [collateral, setCollateral] = useState(null);
  const [ratioBps, setRatioBps] = useState(null);

  // Inputs
  const [depositAmt, setDepositAmt] = useState('');
  const [borrowAmt, setBorrowAmt] = useState('');
  const [requiredCollateral, setRequiredCollateral] = useState(null);

  // Action state
  const [actionLoading, setActionLoading] = useState(null); // 'deposit'|'borrow'|'repay'
  const [feedback, setFeedback] = useState(null);

  // --- Data loading ---

  const loadPoolStats = useCallback(async () => {
    if (!readPool) return;
    try {
      const [liq, borr] = await Promise.all([
        readPool.totalLiquidity(),
        readPool.totalBorrowed(),
      ]);
      setTotalLiquidity(liq);
      setTotalBorrowed(borr);
    } catch (err) {
      console.error('Failed to load pool stats:', err);
    }
  }, [readPool]);

  const loadBorrowerStats = useCallback(async () => {
    if (!readPool || !walletAddress) return;
    try {
      const [borr, coll, ratio] = await Promise.all([
        readPool.borrowedAmounts(walletAddress),
        readPool.collateralDeposited(walletAddress),
        readPool.getBorrowerCollateralRatioBps(walletAddress),
      ]);
      setBorrowed(borr);
      setCollateral(coll);
      setRatioBps(Number(ratio));
    } catch (err) {
      console.error('Failed to load borrower stats:', err);
    }
  }, [readPool, walletAddress]);

  useEffect(() => {
    loadPoolStats();
    loadBorrowerStats();
  }, [loadPoolStats, loadBorrowerStats]);

  // Compute required collateral when borrow amount changes
  useEffect(() => {
    async function calc() {
      if (!readPool || !walletAddress || !borrowAmt) {
        setRequiredCollateral(null);
        return;
      }
      try {
        const parsed = ethers.parseEther(borrowAmt);
        const req = await readPool.getRequiredCollateral(walletAddress, parsed);
        setRequiredCollateral(req);
      } catch {
        setRequiredCollateral(null);
      }
    }
    calc();
  }, [readPool, walletAddress, borrowAmt]);

  // --- Actions ---

  async function refresh() {
    await Promise.all([loadPoolStats(), loadBorrowerStats()]);
  }

  async function handleDeposit() {
    if (!pool || !depositAmt) return;
    setActionLoading('deposit');
    setFeedback(null);
    try {
      const value = ethers.parseEther(depositAmt);
      const tx = await pool.deposit({ value });
      setFeedback({ type: 'pending', message: `Deposit tx: ${tx.hash.slice(0, 18)}...` });
      await tx.wait();
      setFeedback({ type: 'success', message: 'Deposit confirmed' });
      setDepositAmt('');
      await refresh();
    } catch (err) {
      setFeedback({ type: 'error', message: err?.reason || err?.shortMessage || err?.message || 'Deposit failed' });
    } finally {
      setActionLoading(null);
    }
  }

  async function handleBorrow() {
    if (!pool || !borrowAmt || !requiredCollateral) return;
    setActionLoading('borrow');
    setFeedback(null);
    try {
      const amount = ethers.parseEther(borrowAmt);
      const tx = await pool.borrow(amount, { value: requiredCollateral });
      setFeedback({ type: 'pending', message: `Borrow tx: ${tx.hash.slice(0, 18)}...` });
      await tx.wait();
      setFeedback({ type: 'success', message: 'Borrow confirmed' });
      setBorrowAmt('');
      await refresh();
    } catch (err) {
      setFeedback({ type: 'error', message: err?.reason || err?.shortMessage || err?.message || 'Borrow failed' });
    } finally {
      setActionLoading(null);
    }
  }

  async function handleRepay() {
    if (!pool || !borrowed || borrowed === 0n) return;
    setActionLoading('repay');
    setFeedback(null);
    try {
      const tx = await pool.repay({ value: borrowed });
      setFeedback({ type: 'pending', message: `Repay tx: ${tx.hash.slice(0, 18)}...` });
      await tx.wait();
      setFeedback({ type: 'success', message: 'Loan fully repaid' });
      await refresh();
    } catch (err) {
      setFeedback({ type: 'error', message: err?.reason || err?.shortMessage || err?.message || 'Repay failed' });
    } finally {
      setActionLoading(null);
    }
  }

  const available =
    totalLiquidity != null && totalBorrowed != null
      ? totalLiquidity - totalBorrowed
      : null;

  const hasLoan = borrowed != null && borrowed > 0n;

  return (
    <div className="rounded-lg border border-border bg-bg-card overflow-hidden">
      {/* Header */}
      <div className="px-4 py-3 border-b border-border">
        <h3 className="text-text-primary text-sm font-semibold tracking-wide uppercase">
          Lending Pool
        </h3>
      </div>

      {/* Pool stats — always visible */}
      <div className="px-4 py-3 border-b border-border space-y-0.5">
        <StatRow
          label="Total Liquidity"
          value={totalLiquidity != null ? fmt(totalLiquidity) : '--'}
        />
        <StatRow
          label="Total Borrowed"
          value={totalBorrowed != null ? fmt(totalBorrowed) : '--'}
        />
        <StatRow
          label="Available"
          value={available != null ? fmt(available) : '--'}
          accent
        />
      </div>

      {!pool ? (
        <div className="px-4 py-8 text-center text-text-secondary text-sm">
          Connect wallet to interact with the lending pool
        </div>
      ) : (
        <div className="p-4 space-y-4">
          {/* Borrower status */}
          <div className="space-y-0.5">
            <div className="text-xs text-text-secondary uppercase tracking-wider mb-1">
              Your Position
            </div>
            <StatRow
              label="Collateral Deposited"
              value={collateral != null ? fmt(collateral) : '--'}
            />
            <StatRow
              label="Outstanding Loan"
              value={borrowed != null ? fmt(borrowed) : '--'}
            />
            <div className="flex items-center justify-between py-1">
              <span className="text-text-secondary text-xs uppercase tracking-wider">
                Required Collateral Ratio
              </span>
              <span className="font-mono text-sm text-text-primary">
                {ratioBps != null ? `${(ratioBps / 100).toFixed(0)}%` : '--'}
              </span>
            </div>
          </div>

          <div className="h-px bg-border" />

          {/* Deposit */}
          <div className="space-y-2">
            <label className="text-xs text-text-secondary uppercase tracking-wider block">
              Deposit Liquidity
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                inputMode="decimal"
                value={depositAmt}
                onChange={(e) => setDepositAmt(e.target.value)}
                placeholder="0.0"
                className="flex-1 bg-bg-primary border border-border rounded px-3 py-1.5 font-mono text-sm text-text-primary focus:outline-none focus:border-accent"
              />
              <button
                onClick={handleDeposit}
                disabled={!!actionLoading || !depositAmt}
                className={`px-4 py-1.5 rounded text-xs font-semibold uppercase tracking-wide transition-colors ${
                  actionLoading === 'deposit'
                    ? 'bg-border text-text-secondary cursor-wait'
                    : 'bg-accent/20 text-accent hover:bg-accent/30 border border-accent/40'
                }`}
              >
                {actionLoading === 'deposit' ? '...' : 'Deposit'}
              </button>
            </div>
          </div>

          <div className="h-px bg-border" />

          {/* Borrow */}
          <div className="space-y-2">
            <label className="text-xs text-text-secondary uppercase tracking-wider block">
              Borrow
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                inputMode="decimal"
                value={borrowAmt}
                onChange={(e) => setBorrowAmt(e.target.value)}
                placeholder="0.0"
                className="flex-1 bg-bg-primary border border-border rounded px-3 py-1.5 font-mono text-sm text-text-primary focus:outline-none focus:border-accent"
              />
              <button
                onClick={handleBorrow}
                disabled={!!actionLoading || !borrowAmt || !requiredCollateral}
                className={`px-4 py-1.5 rounded text-xs font-semibold uppercase tracking-wide transition-colors ${
                  actionLoading === 'borrow'
                    ? 'bg-border text-text-secondary cursor-wait'
                    : 'bg-warning/20 text-warning hover:bg-warning/30 border border-warning/40'
                }`}
              >
                {actionLoading === 'borrow' ? '...' : 'Borrow'}
              </button>
            </div>
            {requiredCollateral != null && borrowAmt && (
              <p className="text-xs text-text-secondary font-mono">
                Required collateral:{' '}
                <span className="text-text-primary">{fmt(requiredCollateral)} tBNB</span>
                {ratioBps != null && (
                  <span className="ml-2 text-text-secondary">
                    ({(ratioBps / 100).toFixed(0)}% ratio)
                  </span>
                )}
              </p>
            )}
          </div>

          {/* Repay */}
          {hasLoan && (
            <>
              <div className="h-px bg-border" />
              <div className="space-y-2">
                <label className="text-xs text-text-secondary uppercase tracking-wider block">
                  Repay Outstanding Loan
                </label>
                <div className="flex items-center justify-between">
                  <span className="font-mono text-sm text-text-primary">
                    {fmt(borrowed)} tBNB
                  </span>
                  <button
                    onClick={handleRepay}
                    disabled={!!actionLoading}
                    className={`px-4 py-1.5 rounded text-xs font-semibold uppercase tracking-wide transition-colors ${
                      actionLoading === 'repay'
                        ? 'bg-border text-text-secondary cursor-wait'
                        : 'bg-danger/20 text-danger hover:bg-danger/30 border border-danger/40'
                    }`}
                  >
                    {actionLoading === 'repay' ? '...' : 'Repay Full'}
                  </button>
                </div>
              </div>
            </>
          )}

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
