"""
Distribution analysis for FICO-style binning (Phase 3 retraining).

Loads the processed feature matrix, prints percentile + class-conditional
statistics for every continuous feature that will be binned, and writes a
compact distribution summary. Does NOT modify any model artifacts.
"""

import numpy as np
import pandas as pd
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"

# --- Load and merge raw CSVs (same as train.py load_data) ---
labels = pd.read_csv(RAW_DIR / "01_venus_borrower_labels.csv").rename(
    columns={"borrower_address": "wallet_address"}
)
activity = pd.read_csv(RAW_DIR / "02_bsc_activity_features.csv")
lending = pd.read_csv(RAW_DIR / "03_bsc_lending_features.csv")
defi = pd.read_csv(RAW_DIR / "04_bsc_defi_features.csv")
financial = pd.read_csv(RAW_DIR / "05_bsc_financial_features.csv")
crosschain = pd.read_csv(RAW_DIR / "06_crosschain_activity_features.csv")

df = labels
for other in [activity, lending, defi, financial, crosschain]:
    df = df.merge(other, on="wallet_address", how="left", suffixes=("", "_dup"))
df = df.drop(columns=[c for c in df.columns if c.endswith("_dup")])

# Fill nulls (same as train.py)
fill_zero = [
    "bsc_total_tx_count", "bsc_unique_active_days", "bsc_wallet_age_days",
    "bsc_unique_to_addresses", "borrow_count", "repay_count",
    "borrow_repay_ratio", "total_borrowed_usd", "total_repaid_usd",
    "unique_borrow_tokens", "unique_markets", "lending_active_days",
    "bsc_dex_trade_count", "current_total_usd", "stablecoin_ratio",
    "token_diversity", "net_flow_usd_90d", "chains_active_on",
    "crosschain_total_tx_count", "crosschain_dex_trade_count",
]
for c in fill_zero:
    df[c] = df[c].fillna(0)
df["has_used_dex"] = df["has_used_dex"].fillna(False).astype(int)
df["has_used_bridge"] = df["has_used_bridge"].fillna(False).astype(int)
df["protocol_diversity_score"] = df["protocol_diversity_score"].fillna(1)
df["net_flow_direction"] = (df["net_flow_usd_90d"] > 0).astype(int)

# NEW feature per user direction
df["total_lending_volume_log"] = np.log1p(df["total_borrowed_usd"] + df["total_repaid_usd"])

# Target: P(NOT liquidated) — positive class
df["target"] = (~df["was_liquidated"]).astype(int)
N = len(df)

print(f"N = {N:,} wallets")
print(f"Positive class (not liquidated): {df['target'].sum():,} ({df['target'].mean()*100:.1f}%)")
print(f"Negative class (liquidated):     {(1 - df['target']).sum():,} ({(1 - df['target'].mean())*100:.1f}%)")
print()

CONTINUOUS = [
    # Activity
    "bsc_total_tx_count",
    "bsc_unique_active_days",
    "bsc_wallet_age_days",
    "bsc_unique_to_addresses",
    # Lending
    "borrow_count",
    "repay_count",
    "borrow_repay_ratio",
    "total_lending_volume_log",
    "unique_borrow_tokens",
    "unique_markets",
    "lending_active_days",
    # DeFi
    "bsc_dex_trade_count",
    # Financial
    "current_total_usd",
    "stablecoin_ratio",
    "token_diversity",
    # Crosschain
    "crosschain_total_tx_count",
    "crosschain_dex_trade_count",
]

# Small-integer features that are natural candidates for categorical treatment
SMALL_INT = ["protocol_diversity_score", "chains_active_on"]

def class_rate_at_threshold(values, target, threshold, direction=">="):
    """Return liquidation rate for rows satisfying a threshold."""
    if direction == ">=":
        mask = values >= threshold
    else:
        mask = values < threshold
    if mask.sum() == 0:
        return None, 0
    liq_rate = 1 - target[mask].mean()
    return liq_rate, mask.sum()

def analyze(col):
    v = df[col].values
    y = df["target"].values
    pcts = np.percentile(v, [0, 10, 25, 50, 75, 90, 95, 99, 100])
    overall_liq = 1 - y.mean()
    print(f"\n--- {col} ---")
    print(f"  min={pcts[0]:,.2f}  p10={pcts[1]:,.2f}  p25={pcts[2]:,.2f}  p50={pcts[3]:,.2f}  p75={pcts[4]:,.2f}  p90={pcts[5]:,.2f}  p95={pcts[6]:,.2f}  p99={pcts[7]:,.2f}  max={pcts[8]:,.2f}")
    n_zero = (v == 0).sum()
    print(f"  zeros: {n_zero:,} ({n_zero/N*100:.1f}%)   mean={v.mean():.2f}   std={v.std():.2f}")
    # Class-conditional means
    liq_mean = v[y == 0].mean()
    nliq_mean = v[y == 1].mean()
    liq_med = np.median(v[y == 0])
    nliq_med = np.median(v[y == 1])
    print(f"  liquidated mean={liq_mean:.2f} median={liq_med:.2f}   not-liq mean={nliq_mean:.2f} median={nliq_med:.2f}")
    # Liquidation rate in each quintile (crude directional check)
    try:
        qs = np.quantile(v, [0.2, 0.4, 0.6, 0.8])
        # dedupe quantile edges (for heavily-zero features)
        qs_unique = sorted(set(qs))
        bins_edges = [-np.inf] + qs_unique + [np.inf]
        bin_ids = np.digitize(v, qs_unique, right=False)
        print(f"  quintile edges: {[f'{q:.2f}' for q in qs]}")
        for bid in sorted(np.unique(bin_ids)):
            mask = bin_ids == bid
            if mask.sum() == 0:
                continue
            liq_rate = 1 - y[mask].mean()
            print(f"    bin {bid}: n={mask.sum():>6,}   liq_rate={liq_rate*100:5.1f}%")
    except Exception as e:
        print(f"  (quintile analysis failed: {e})")

for col in CONTINUOUS:
    analyze(col)

print("\n\n=== SMALL INTEGER FEATURES (natural categorical) ===")
for col in SMALL_INT:
    print(f"\n--- {col} ---")
    vc = df.groupby(col)["target"].agg(["count", "mean"])
    vc.columns = ["n_wallets", "p_not_liq"]
    vc["liq_rate_pct"] = (1 - vc["p_not_liq"]) * 100
    print(vc.to_string())

print("\n\n=== BOOLEAN FEATURES (kept as-is) ===")
for col in ["has_used_dex", "has_used_bridge", "net_flow_direction"]:
    print(f"\n--- {col} ---")
    vc = df.groupby(col)["target"].agg(["count", "mean"])
    vc.columns = ["n_wallets", "p_not_liq"]
    vc["liq_rate_pct"] = (1 - vc["p_not_liq"]) * 100
    print(vc.to_string())
