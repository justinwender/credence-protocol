/**
 * CreditReport — Expandable full credit report panel.
 *
 * For each of the 10 model features, shows:
 *   - Display name
 *   - Wallet's value (derived from the bin label)
 *   - Qualitative tier badge (Poor / Fair / Good / Excellent)
 *   - Coefficient impact
 *   - Top-decile benchmark
 *   - Action item
 *
 * Bloomberg-terminal dark aesthetic, Tailwind v4 classes.
 */

// ---------------------------------------------------------------------------
// Static data embedded from model/feature_config.json benchmarks + specs
// ---------------------------------------------------------------------------

const BENCHMARKS = {
  lending_active_days: {
    top_decile_mean: 1.2,
    display: '1-2 days',
    action_item:
      'Maintain minimal borrowing activity -- fewer active lending days correlates with lower liquidation risk',
  },
  borrow_repay_ratio: {
    top_decile_mean: 1.02,
    display: '~1.0 (balanced)',
    action_item:
      'Keep repayments closely matched to borrows for a ratio near 1.0',
  },
  repay_count: {
    top_decile_mean: 2.1,
    display: '1-3 repayments',
    action_item:
      'A modest number of successful repayments demonstrates reliability without overexposure',
  },
  unique_borrow_tokens: {
    top_decile_mean: 1.1,
    display: '1 token',
    action_item:
      'Focus borrowing on a single asset type to demonstrate disciplined strategy',
  },
  current_total_usd: {
    top_decile_mean: 3.85,
    display: 'Under $10',
    action_item:
      'Smaller on-chain portfolios carry lower liquidation exposure in the model',
  },
  stablecoin_ratio: {
    top_decile_mean: 0.72,
    display: '~72% stablecoins',
    action_item:
      'Allocate a majority of your portfolio to stablecoins for risk reduction',
  },
  crosschain_total_tx_count: {
    top_decile_mean: 4.3,
    display: '0-5 transactions',
    action_item:
      'Minimal cross-chain activity signals focused, lower-risk BSC usage',
  },
  crosschain_dex_trade_count: {
    top_decile_mean: 1.8,
    display: '0-2 trades',
    action_item:
      'Limited cross-chain DEX trading indicates concentrated, lower-risk behavior',
  },
  chains_active_on: {
    top_decile_mean: 0.15,
    display: '0 chains (BSC only)',
    action_item:
      'Focused activity on BSC signals disciplined portfolio management',
  },
  has_used_bridge: {
    top_decile_mean: 0.52,
    display: '52% have used bridges',
    action_item:
      'Bridge experience provides a small positive signal but is not required for a high score',
  },
};

// Feature display order (lending -> financial -> crosschain)
const FEATURE_ORDER = [
  'lending_active_days',
  'borrow_repay_ratio',
  'repay_count',
  'unique_borrow_tokens',
  'current_total_usd',
  'stablecoin_ratio',
  'crosschain_total_tx_count',
  'crosschain_dex_trade_count',
  'chains_active_on',
  'has_used_bridge',
];

// Category labels for section headers
const FEATURE_CATEGORIES = {
  lending_active_days: 'Lending Behavior',
  current_total_usd: 'Financial Profile',
  crosschain_total_tx_count: 'Cross-Chain Activity',
};

// ---------------------------------------------------------------------------
// Tier assignment logic
// ---------------------------------------------------------------------------
// Reference bin = Excellent (coefficient 0, safest).
// For non-boolean continuous_binned features, bins are ordered from reference
// outward. We rank by absolute coefficient magnitude:
//   - Reference bin -> Excellent
//   - Smallest |coef| non-reference -> Good
//   - Mid |coef| -> Fair
//   - Largest |coef| -> Poor
// For booleans: positive coef + value=1 -> Good, value=0 -> Fair (small impact)

const TIER_CONFIG = {
  // Maps feature -> { binLabel: tier }
  // Built from the coefficient table in feature_config.json.
  lending_active_days: {
    '[1, 1]': 'Excellent',       // reference, coef 0
    '[2, 4]': 'Good',            // coef -0.80
    '[5, 14]': 'Fair',           // coef -1.05
    '[15, inf)': 'Poor',         // coef -1.23
  },
  borrow_repay_ratio: {
    '(0.9, 1.1]': 'Excellent',  // reference, coef 0
    '[0, 0.9]': 'Good',         // coef -0.25
    '(1.1, 2.0]': 'Fair',       // coef -0.54
    '(2.0, inf)': 'Poor',       // coef -0.60
  },
  repay_count: {
    '[0, 3]': 'Excellent',       // reference, coef 0
    '[4, 9]': 'Excellent',       // coef +0.02 (positive, very small)
    '[10, inf)': 'Good',         // coef +0.04 (positive)
  },
  unique_borrow_tokens: {
    '[1, 1]': 'Excellent',       // reference, coef 0
    '[2, 2]': 'Good',            // coef -0.016
    '[3, inf)': 'Fair',          // coef -0.057
  },
  current_total_usd: {
    '[0, 10]': 'Excellent',      // reference, coef 0
    '(10, 100]': 'Good',        // coef -0.075
    '(100, 1000]': 'Fair',      // coef -0.17
    '(1000, inf)': 'Fair',      // coef -0.11
  },
  stablecoin_ratio: {
    '(0.5, 1.0]': 'Excellent',  // reference, coef 0
    '(0.05, 0.5]': 'Good',      // coef -0.17
    '[0, 0.05]': 'Fair',        // coef -0.26
  },
  crosschain_total_tx_count: {
    '[0, 0]': 'Excellent',       // reference, coef 0
    '[1, 100]': 'Excellent',     // coef +0.02 (positive)
    '[101, 1000]': 'Good',       // coef +0.01
    '[1001, inf)': 'Good',       // coef +0.03
  },
  crosschain_dex_trade_count: {
    '[0, 0]': 'Excellent',       // reference, coef 0
    '[1, 100]': 'Good',          // coef -0.06
    '[101, inf)': 'Fair',        // coef -0.08
  },
  chains_active_on: {
    '0': 'Excellent',            // reference, coef 0
    '1-3': 'Excellent',          // coef -0.003 (near zero)
    '4': 'Good',                 // coef +0.067
  },
  has_used_bridge: {
    '1': 'Good',                 // coef +0.14
    '0': 'Good',                 // small impact either way
  },
};

// Map bin labels to human-readable wallet value strings
function formatBinValue(feature, bin) {
  const formatters = {
    lending_active_days: {
      '[1, 1]': '1 day',
      '[2, 4]': '2-4 days',
      '[5, 14]': '5-14 days',
      '[15, inf)': '15+ days',
    },
    borrow_repay_ratio: {
      '[0, 0.9]': 'Ratio: under 0.9 (under-repaid)',
      '(0.9, 1.1]': 'Ratio: 0.9-1.1 (balanced)',
      '(1.1, 2.0]': 'Ratio: 1.1-2.0 (over-repaid)',
      '(2.0, inf)': 'Ratio: over 2.0 (excess repayment)',
    },
    repay_count: {
      '[0, 3]': '0-3 repayments',
      '[4, 9]': '4-9 repayments',
      '[10, inf)': '10+ repayments',
    },
    unique_borrow_tokens: {
      '[1, 1]': '1 token',
      '[2, 2]': '2 tokens',
      '[3, inf)': '3+ tokens',
    },
    current_total_usd: {
      '[0, 10]': '$0-$10',
      '(10, 100]': '$10-$100',
      '(100, 1000]': '$100-$1,000',
      '(1000, inf)': '$1,000+',
    },
    stablecoin_ratio: {
      '[0, 0.05]': 'Under 5%',
      '(0.05, 0.5]': '5%-50%',
      '(0.5, 1.0]': 'Over 50%',
    },
    crosschain_total_tx_count: {
      '[0, 0]': 'None',
      '[1, 100]': '1-100 transactions',
      '[101, 1000]': '101-1,000 transactions',
      '[1001, inf)': '1,000+ transactions',
    },
    crosschain_dex_trade_count: {
      '[0, 0]': 'None',
      '[1, 100]': '1-100 trades',
      '[101, inf)': '101+ trades',
    },
    chains_active_on: {
      '0': 'BSC only',
      '1-3': '1-3 other chains',
      '4': 'All 4 other chains',
    },
    has_used_bridge: {
      '1': 'Yes',
      '0': 'No',
    },
  };

  return formatters[feature]?.[bin] ?? bin;
}

// ---------------------------------------------------------------------------
// Tier badge component
// ---------------------------------------------------------------------------
const TIER_STYLES = {
  Poor: 'text-danger border-danger/30 bg-danger/10',
  Fair: 'text-warning border-warning/30 bg-warning/10',
  Good: 'text-accent border-accent/30 bg-accent/10',
  Excellent: 'text-accent-bright border-accent-bright/30 bg-accent-bright/10',
};

function TierBadge({ tier }) {
  const style = TIER_STYLES[tier] || TIER_STYLES.Fair;
  return (
    <span
      className={`inline-block px-2 py-0.5 rounded text-xs font-medium border ${style}`}
    >
      {tier}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Single feature card
// ---------------------------------------------------------------------------
function FeatureCard({ factor }) {
  const { feature, display_name, bin, coefficient, is_reference } = factor;
  const benchmark = BENCHMARKS[feature];
  const tierMap = TIER_CONFIG[feature] || {};
  const tier = tierMap[bin] || 'Fair';
  const walletValue = formatBinValue(feature, bin);

  return (
    <div className="bg-bg-primary/60 border border-border rounded-lg p-4 space-y-3">
      {/* Header row: name + tier badge */}
      <div className="flex items-start justify-between gap-3">
        <h4 className="text-sm font-medium text-text-primary leading-tight">
          {display_name}
        </h4>
        <TierBadge tier={tier} />
      </div>

      {/* Wallet value */}
      <div className="flex items-baseline gap-2">
        <span className="text-xs text-text-muted uppercase tracking-wider">
          Your value
        </span>
        <span className="font-mono text-sm text-text-secondary">
          {walletValue}
        </span>
      </div>

      {/* Coefficient impact */}
      <div className="flex items-baseline gap-2">
        <span className="text-xs text-text-muted uppercase tracking-wider">
          Impact
        </span>
        {is_reference ? (
          <span className="font-mono text-sm text-text-muted">(baseline)</span>
        ) : (
          <span
            className={`font-mono text-sm ${
              coefficient > 0 ? 'text-accent' : 'text-danger'
            }`}
          >
            {coefficient > 0 ? '+' : ''}
            {coefficient.toFixed(4)}
          </span>
        )}
      </div>

      {/* Benchmark */}
      {benchmark && (
        <div className="flex items-baseline gap-2">
          <span className="text-xs text-text-muted uppercase tracking-wider">
            Top wallets
          </span>
          <span className="text-xs text-info">{benchmark.display}</span>
        </div>
      )}

      {/* Action item */}
      {benchmark && (
        <div className="border-t border-border/50 pt-2 mt-2">
          <p className="text-xs text-text-muted leading-relaxed">
            {benchmark.action_item}
          </p>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------
export default function CreditReport({ factors = [], isExpanded, onToggle }) {
  // Build a lookup from feature name to factor data
  const factorMap = {};
  for (const f of factors) {
    factorMap[f.feature] = f;
  }

  // Filter to only the 10 source features (exclude net_flow_direction from
  // the detailed report -- it's a derived boolean with minimal actionability)
  const orderedFactors = FEATURE_ORDER.map((feat) => factorMap[feat]).filter(
    Boolean
  );

  if (orderedFactors.length === 0) return null;

  return (
    <div className="bg-bg-card border border-border rounded-xl overflow-hidden">
      {/* Toggle button */}
      <button
        onClick={onToggle}
        className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-bg-card-hover transition-colors"
      >
        <div className="flex items-center gap-3">
          <svg
            className="w-5 h-5 text-info"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"
            />
          </svg>
          <span className="text-sm font-medium text-text-primary">
            {isExpanded ? 'Hide Full Credit Report' : 'View Full Credit Report'}
          </span>
        </div>
        <svg
          className={`w-4 h-4 text-text-muted transition-transform duration-200 ${
            isExpanded ? 'rotate-180' : ''
          }`}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M19 9l-7 7-7-7"
          />
        </svg>
      </button>

      {/* Expanded content */}
      {isExpanded && (
        <div className="px-6 pb-6 space-y-6">
          {/* Preamble */}
          <div className="border-t border-border pt-4">
            <p className="text-xs text-text-muted leading-relaxed">
              Detailed breakdown of all 10 credit factors. Each factor shows
              your wallet's assessed tier, coefficient impact on the logistic
              model, and how top-scoring wallets compare. Tiers: Poor / Fair /
              Good / Excellent.
            </p>
          </div>

          {/* Render cards grouped by category */}
          {FEATURE_ORDER.map((feat) => {
            const factor = factorMap[feat];
            if (!factor) return null;

            const categoryLabel = FEATURE_CATEGORIES[feat];

            return (
              <div key={feat}>
                {categoryLabel && (
                  <h3 className="text-xs font-medium text-text-muted uppercase tracking-wider mb-3 mt-2">
                    {categoryLabel}
                  </h3>
                )}
                <FeatureCard factor={factor} />
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
