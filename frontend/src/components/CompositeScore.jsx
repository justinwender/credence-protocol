import ScoreGauge from './ScoreGauge.jsx';
import { getCollateralLabel } from '../config.js';

/**
 * Hero element: Composite Credit Score as a large radial gauge with
 * the collateral ratio and tier badge below. This is what determines
 * lending terms — the number the user cares about most.
 */
export default function CompositeScore({
  compositeScore = 0,
  collateralRatioBps = 15000,
}) {
  const collateral = getCollateralLabel(collateralRatioBps);
  const collateralPct = (collateralRatioBps / 100).toFixed(0);

  return (
    <div className="bg-bg-card border border-border rounded-xl p-6 flex flex-col items-center">
      <h2 className="text-xs font-medium text-text-muted uppercase tracking-wider mb-4">
        Composite Credit Score
      </h2>

      <ScoreGauge score={compositeScore} />

      {/* Collateral ratio + tier badge */}
      <div className="mt-5 flex items-center gap-3">
        <div className="text-center">
          <span className="text-text-muted text-xs uppercase tracking-wider">
            Collateral Required
          </span>
          <div className="font-mono text-2xl font-bold text-text-primary mt-0.5">
            {collateralPct}%
          </div>
        </div>
        <span
          className={`text-xs font-semibold px-3 py-1.5 rounded ${collateral.color} bg-bg-primary/60 border border-border`}
        >
          {collateral.text}
        </span>
      </div>
    </div>
  );
}
