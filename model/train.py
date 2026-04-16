"""
Credence Protocol — Credit Score Model Training
=================================================
Loads CSVs from data/raw/, engineers features, trains a logistic regression
model to predict Venus Protocol liquidation risk, and outputs:
  - model/model.pkl          (frozen model artifact)
  - model/feature_config.json (feature metadata)
  - model/validation_report.md (metrics + coefficient analysis)

Usage:
    python3 model/train.py

The model outputs P(not liquidated) scaled to 0–100 as a credit score.
Higher score = lower liquidation risk = better creditworthiness.
"""

import json
import pickle
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.metrics import (
    roc_auc_score,
    precision_score,
    recall_score,
    f1_score,
    classification_report,
    confusion_matrix,
)
from sklearn.preprocessing import StandardScaler
from sklearn.calibration import calibration_curve

warnings.filterwarnings("ignore")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
MODEL_DIR = PROJECT_ROOT / "model"

PROCESSED_DIR.mkdir(parents=True, exist_ok=True)


# =============================================================================
# 1. LOAD RAW DATA
# =============================================================================
def load_data() -> pd.DataFrame:
    """Load and merge all 6 CSV files on wallet address."""
    print("Loading raw data...")

    labels = pd.read_csv(RAW_DIR / "01_venus_borrower_labels.csv")
    activity = pd.read_csv(RAW_DIR / "02_bsc_activity_features.csv")
    lending = pd.read_csv(RAW_DIR / "03_bsc_lending_features.csv")
    defi = pd.read_csv(RAW_DIR / "04_bsc_defi_features.csv")
    financial = pd.read_csv(RAW_DIR / "05_bsc_financial_features.csv")
    crosschain = pd.read_csv(RAW_DIR / "06_crosschain_activity_features.csv")

    # Standardize join key name
    labels = labels.rename(columns={"borrower_address": "wallet_address"})

    # Merge all on wallet_address
    df = labels
    for other in [activity, lending, defi, financial, crosschain]:
        df = df.merge(other, on="wallet_address", how="left", suffixes=("", "_dup"))

    # Drop duplicate columns from overlapping features
    dup_cols = [c for c in df.columns if c.endswith("_dup")]
    df = df.drop(columns=dup_cols)

    print(f"  Loaded {len(df):,} wallets with {len(df.columns)} columns")
    return df


# =============================================================================
# 2. FEATURE ENGINEERING
# =============================================================================

# Features to use in the model (column name -> human-readable description)
FEATURE_DEFINITIONS = {
    # Activity features
    "bsc_total_tx_count": "Total BSC transactions sent",
    "bsc_unique_active_days": "Unique active days on BSC",
    "bsc_wallet_age_days": "Wallet age in days (first to last tx)",
    "bsc_unique_to_addresses": "Unique addresses interacted with",
    # Lending behavior features (strongest signal expected)
    "borrow_count": "Venus borrow event count",
    "repay_count": "Venus repay event count",
    "borrow_repay_ratio": "Repay/borrow ratio (>1 = positive)",
    "total_borrowed_usd_log": "Log of lifetime borrowed USD",
    "total_repaid_usd_log": "Log of lifetime repaid USD",
    "unique_borrow_tokens": "Distinct tokens borrowed on Venus",
    "unique_markets": "Distinct Venus markets used",
    "lending_active_days": "Days with any Venus activity",
    # DeFi sophistication
    "has_used_dex": "Has used a DEX on BSC",
    "bsc_dex_trade_count_log": "Log of BSC DEX trade count",
    "has_used_bridge": "Has used a cross-chain bridge",
    "protocol_diversity_score": "DeFi categories used (1-3)",
    # Financial profile
    "current_total_usd_log": "Log of current portfolio value USD",
    "stablecoin_ratio": "Stablecoins as fraction of portfolio",
    "token_diversity": "Distinct tokens held (balance > 0)",
    "net_flow_direction": "Accumulating (1) or depleting (0) over 90d",
    # Crosschain breadth
    "chains_active_on": "Non-BSC chains with activity (0-4)",
    "crosschain_total_tx_count_log": "Log of total non-BSC transactions",
    "crosschain_dex_trade_count_log": "Log of non-BSC DEX trades",
}

FEATURE_COLS = list(FEATURE_DEFINITIONS.keys())


def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """Engineer model features from raw data."""
    print("Engineering features...")

    # --- Handle nulls ---
    # Wallets with no BSC tx history (interacted via contracts only)
    df["bsc_total_tx_count"] = df["bsc_total_tx_count"].fillna(0)
    df["bsc_unique_active_days"] = df["bsc_unique_active_days"].fillna(0)
    df["bsc_wallet_age_days"] = df["bsc_wallet_age_days"].fillna(0)
    df["bsc_unique_to_addresses"] = df["bsc_unique_to_addresses"].fillna(0)

    # Lending nulls
    df["borrow_count"] = df["borrow_count"].fillna(0)
    df["repay_count"] = df["repay_count"].fillna(0)
    df["borrow_repay_ratio"] = df["borrow_repay_ratio"].fillna(0)
    df["total_borrowed_usd"] = df["total_borrowed_usd"].fillna(0)
    df["total_repaid_usd"] = df["total_repaid_usd"].fillna(0)
    df["unique_borrow_tokens"] = df["unique_borrow_tokens"].fillna(0)
    df["unique_markets"] = df["unique_markets"].fillna(0)
    df["lending_active_days"] = df["lending_active_days"].fillna(0)

    # DeFi / financial nulls
    df["has_used_dex"] = df["has_used_dex"].fillna(False).astype(int)
    df["has_used_bridge"] = df["has_used_bridge"].fillna(False).astype(int)
    df["bsc_dex_trade_count"] = df["bsc_dex_trade_count"].fillna(0)
    df["protocol_diversity_score"] = df["protocol_diversity_score"].fillna(1)
    df["current_total_usd"] = df["current_total_usd"].fillna(0)
    df["stablecoin_ratio"] = df["stablecoin_ratio"].fillna(0)
    df["token_diversity"] = df["token_diversity"].fillna(0)
    df["net_flow_usd_90d"] = df["net_flow_usd_90d"].fillna(0)

    # Crosschain nulls (many wallets expected to have 0)
    df["chains_active_on"] = df["chains_active_on"].fillna(0)
    df["crosschain_total_tx_count"] = df["crosschain_total_tx_count"].fillna(0)
    df["crosschain_dex_trade_count"] = df["crosschain_dex_trade_count"].fillna(0)

    # --- Derived features ---
    # Log-transform heavy-tailed numeric features (add 1 to handle zeros)
    df["total_borrowed_usd_log"] = np.log1p(df["total_borrowed_usd"])
    df["total_repaid_usd_log"] = np.log1p(df["total_repaid_usd"])
    df["bsc_dex_trade_count_log"] = np.log1p(df["bsc_dex_trade_count"])
    df["current_total_usd_log"] = np.log1p(df["current_total_usd"])
    df["crosschain_total_tx_count_log"] = np.log1p(df["crosschain_total_tx_count"])
    df["crosschain_dex_trade_count_log"] = np.log1p(df["crosschain_dex_trade_count"])

    # Net flow direction: binary (accumulating vs depleting)
    df["net_flow_direction"] = (df["net_flow_usd_90d"] > 0).astype(int)

    # --- Target variable ---
    # was_liquidated is our label; model predicts P(NOT liquidated)
    df["target"] = (~df["was_liquidated"]).astype(int)

    # Validate no NaN in features
    for col in FEATURE_COLS:
        null_count = df[col].isnull().sum()
        if null_count > 0:
            print(f"  WARNING: {col} has {null_count} nulls after engineering, filling with 0")
            df[col] = df[col].fillna(0)

    print(f"  Engineered {len(FEATURE_COLS)} features")
    return df


# =============================================================================
# 3. MODEL TRAINING
# =============================================================================
def train_model(df: pd.DataFrame) -> dict:
    """Train logistic regression with cross-validation. Returns results dict."""
    print("Training logistic regression model...")

    X = df[FEATURE_COLS].values
    y = df["target"].values

    # Standardize features (logistic regression is sensitive to scale)
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    # 5-fold stratified cross-validation for honest evaluation
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

    # Train logistic regression with L2 regularization
    model = LogisticRegression(
        penalty="l2",
        C=1.0,  # regularization strength (default)
        solver="lbfgs",
        max_iter=1000,
        random_state=42,
        class_weight="balanced",  # handle class imbalance
    )

    # Get cross-validated predictions for evaluation
    y_prob_cv = cross_val_predict(model, X_scaled, y, cv=cv, method="predict_proba")[:, 1]
    y_pred_cv = (y_prob_cv >= 0.5).astype(int)

    # Compute metrics on cross-validated predictions
    auc = roc_auc_score(y, y_prob_cv)
    precision = precision_score(y, y_pred_cv)
    recall = recall_score(y, y_pred_cv)
    f1 = f1_score(y, y_pred_cv)
    cm = confusion_matrix(y, y_pred_cv)
    report = classification_report(y, y_pred_cv, target_names=["Liquidated", "Not Liquidated"])

    print(f"  Cross-validated AUC: {auc:.4f}")
    print(f"  Precision: {precision:.4f}  Recall: {recall:.4f}  F1: {f1:.4f}")

    # Calibration curve
    prob_true, prob_pred = calibration_curve(y, y_prob_cv, n_bins=10, strategy="quantile")

    # Fit final model on ALL data (for deployment)
    model.fit(X_scaled, y)

    # Extract coefficients
    coef_df = pd.DataFrame({
        "feature": FEATURE_COLS,
        "description": [FEATURE_DEFINITIONS[f] for f in FEATURE_COLS],
        "coefficient": model.coef_[0],
        "abs_coefficient": np.abs(model.coef_[0]),
    }).sort_values("abs_coefficient", ascending=False)

    print("\n  Top 10 features by absolute coefficient:")
    for _, row in coef_df.head(10).iterrows():
        direction = "+" if row["coefficient"] > 0 else "-"
        print(f"    {direction} {row['feature']:40s} = {row['coefficient']:+.4f}")

    # Credit score distribution
    y_prob_final = model.predict_proba(X_scaled)[:, 1]
    credit_scores = (y_prob_final * 100).astype(int)

    results = {
        "model": model,
        "scaler": scaler,
        "auc": auc,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "confusion_matrix": cm,
        "classification_report": report,
        "calibration": {"prob_true": prob_true, "prob_pred": prob_pred},
        "coefficients": coef_df,
        "credit_scores": credit_scores,
        "feature_cols": FEATURE_COLS,
        "y_true": y,
        "y_prob_cv": y_prob_cv,
    }

    return results


# =============================================================================
# 4. SAVE ARTIFACTS
# =============================================================================
def save_artifacts(results: dict, df: pd.DataFrame):
    """Save model, feature config, and validation report."""
    print("\nSaving artifacts...")

    # --- model.pkl ---
    artifact = {
        "model": results["model"],
        "scaler": results["scaler"],
        "feature_cols": results["feature_cols"],
        "feature_definitions": FEATURE_DEFINITIONS,
    }
    pkl_path = MODEL_DIR / "model.pkl"
    with open(pkl_path, "wb") as f:
        pickle.dump(artifact, f)
    print(f"  Saved model to {pkl_path}")

    # --- feature_config.json ---
    config = {
        "features": [
            {
                "name": name,
                "description": FEATURE_DEFINITIONS[name],
                "coefficient": float(results["coefficients"].loc[
                    results["coefficients"]["feature"] == name, "coefficient"
                ].values[0]),
            }
            for name in results["feature_cols"]
        ],
        "model_type": "LogisticRegression",
        "regularization": "L2",
        "target": "P(not liquidated) -> credit score 0-100",
        "training_samples": len(df),
        "positive_class_rate": float((df["target"] == 1).mean()),
        "auc": float(results["auc"]),
    }
    config_path = MODEL_DIR / "feature_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"  Saved feature config to {config_path}")

    # --- validation_report.md ---
    coef_df = results["coefficients"]
    cm = results["confusion_matrix"]
    scores = results["credit_scores"]
    y_true = results["y_true"]

    # Score distribution by class
    liquidated_scores = scores[y_true == 0]
    not_liquidated_scores = scores[y_true == 1]

    # Calibration data
    cal = results["calibration"]

    report_lines = [
        "# Credence Protocol — Model Validation Report",
        "",
        "## Model Summary",
        "",
        f"- **Model type**: Logistic Regression (L2 regularized, class_weight='balanced')",
        f"- **Training samples**: {len(df):,}",
        f"- **Features**: {len(FEATURE_COLS)}",
        f"- **Target**: P(not liquidated on Venus) scaled to 0–100 credit score",
        f"- **Positive class (not liquidated)**: {(df['target']==1).sum():,} ({(df['target']==1).mean()*100:.1f}%)",
        f"- **Negative class (liquidated)**: {(df['target']==0).sum():,} ({(df['target']==0).mean()*100:.1f}%)",
        "",
        "## Cross-Validated Performance (5-fold stratified)",
        "",
        f"| Metric | Value |",
        f"|--------|-------|",
        f"| **AUC-ROC** | {results['auc']:.4f} |",
        f"| Precision | {results['precision']:.4f} |",
        f"| Recall | {results['recall']:.4f} |",
        f"| F1 Score | {results['f1']:.4f} |",
        "",
        "### Confusion Matrix",
        "",
        "```",
        f"                  Predicted",
        f"                  Liquidated  Not Liquidated",
        f"Actual Liquidated    {cm[0][0]:>6}        {cm[0][1]:>6}",
        f"Actual Not Liq.      {cm[1][0]:>6}        {cm[1][1]:>6}",
        "```",
        "",
        "### Classification Report",
        "",
        "```",
        results["classification_report"],
        "```",
        "",
        "## Feature Coefficients (sorted by importance)",
        "",
        "Positive coefficient = increases credit score (reduces liquidation risk).",
        "Negative coefficient = decreases credit score (increases liquidation risk).",
        "",
        "| Rank | Feature | Description | Coefficient |",
        "|------|---------|-------------|-------------|",
    ]

    for i, (_, row) in enumerate(coef_df.iterrows(), 1):
        sign = "+" if row["coefficient"] > 0 else ""
        report_lines.append(
            f"| {i} | `{row['feature']}` | {row['description']} | {sign}{row['coefficient']:.4f} |"
        )

    report_lines.extend([
        "",
        "## Credit Score Distribution",
        "",
        f"| Statistic | Liquidated Wallets | Non-Liquidated Wallets |",
        f"|-----------|-------------------|----------------------|",
        f"| Mean | {liquidated_scores.mean():.1f} | {not_liquidated_scores.mean():.1f} |",
        f"| Median | {np.median(liquidated_scores):.1f} | {np.median(not_liquidated_scores):.1f} |",
        f"| Std Dev | {liquidated_scores.std():.1f} | {not_liquidated_scores.std():.1f} |",
        f"| Min | {liquidated_scores.min()} | {not_liquidated_scores.min()} |",
        f"| Max | {liquidated_scores.max()} | {not_liquidated_scores.max()} |",
        "",
        "### Score Percentiles (all wallets)",
        "",
        f"| Percentile | Score |",
        f"|------------|-------|",
        f"| 5th | {np.percentile(scores, 5):.0f} |",
        f"| 25th | {np.percentile(scores, 25):.0f} |",
        f"| 50th (median) | {np.percentile(scores, 50):.0f} |",
        f"| 75th | {np.percentile(scores, 75):.0f} |",
        f"| 95th | {np.percentile(scores, 95):.0f} |",
        "",
        "## Calibration",
        "",
        "How well do predicted probabilities match actual outcomes?",
        "",
        f"| Predicted P(not liquidated) | Actual P(not liquidated) |",
        f"|---------------------------|-------------------------|",
    ])

    for pt, pp in zip(cal["prob_true"], cal["prob_pred"]):
        report_lines.append(f"| {pp:.3f} | {pt:.3f} |")

    report_lines.extend([
        "",
        "## Interpretation Notes",
        "",
        "- The model was trained on **all-time Venus Protocol data on BSC**.",
        "- Lending behavior features (borrow/repay patterns) are expected to dominate.",
        "- Log-transformed features (USD amounts, tx counts) handle the heavy-tailed distributions.",
        "- `class_weight='balanced'` adjusts for the 86/14 class split.",
        "- The credit score is `P(not liquidated) * 100`, so higher = better.",
        "- **This model is now FROZEN.** No further iteration during the hackathon.",
    ])

    report_path = MODEL_DIR / "validation_report.md"
    with open(report_path, "w") as f:
        f.write("\n".join(report_lines))
    print(f"  Saved validation report to {report_path}")

    # --- Save processed feature matrix for reference ---
    processed_path = PROCESSED_DIR / "feature_matrix.csv"
    df[["wallet_address", "target"] + FEATURE_COLS].to_csv(processed_path, index=False)
    print(f"  Saved feature matrix to {processed_path}")


# =============================================================================
# MAIN
# =============================================================================
def main():
    print("=" * 60)
    print("Credence Protocol — Model Training Pipeline")
    print("=" * 60)

    df = load_data()
    df = engineer_features(df)
    results = train_model(df)
    save_artifacts(results, df)

    print("\n" + "=" * 60)
    print("TRAINING COMPLETE")
    print("=" * 60)
    print(f"  AUC: {results['auc']:.4f}")
    print(f"  Model saved to model/model.pkl")
    print(f"  Report saved to model/validation_report.md")
    print(f"  Model is now FROZEN — do not retrain during hackathon.")


if __name__ == "__main__":
    main()
