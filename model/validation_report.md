# Credence Protocol — Model Validation Report

## Model Summary

- **Model type**: Logistic Regression (L2 regularized, class_weight='balanced')
- **Training samples**: 115,687
- **Features**: 23
- **Target**: P(not liquidated on Venus) scaled to 0–100 credit score
- **Positive class (not liquidated)**: 99,798 (86.3%)
- **Negative class (liquidated)**: 15,889 (13.7%)

## Cross-Validated Performance (5-fold stratified)

| Metric | Value |
|--------|-------|
| **AUC-ROC** | 0.8107 |
| Precision | 0.9410 |
| Recall | 0.7910 |
| F1 Score | 0.8595 |

### Confusion Matrix

```
                  Predicted
                  Liquidated  Not Liquidated
Actual Liquidated     10937          4952
Actual Not Liq.       20855         78943
```

### Classification Report

```
                precision    recall  f1-score   support

    Liquidated       0.34      0.69      0.46     15889
Not Liquidated       0.94      0.79      0.86     99798

      accuracy                           0.78    115687
     macro avg       0.64      0.74      0.66    115687
  weighted avg       0.86      0.78      0.80    115687

```

## Feature Coefficients (sorted by importance)

Positive coefficient = increases credit score (reduces liquidation risk).
Negative coefficient = decreases credit score (increases liquidation risk).

| Rank | Feature | Description | Coefficient |
|------|---------|-------------|-------------|
| 1 | `total_borrowed_usd_log` | Log of lifetime borrowed USD | +2.1182 |
| 2 | `total_repaid_usd_log` | Log of lifetime repaid USD | -1.9190 |
| 3 | `borrow_repay_ratio` | Repay/borrow ratio (>1 = positive) | -1.6743 |
| 4 | `lending_active_days` | Days with any Venus activity | -1.0265 |
| 5 | `repay_count` | Venus repay event count | +0.6230 |
| 6 | `bsc_total_tx_count` | Total BSC transactions sent | +0.3916 |
| 7 | `bsc_wallet_age_days` | Wallet age in days (first to last tx) | -0.3583 |
| 8 | `borrow_count` | Venus borrow event count | -0.3480 |
| 9 | `token_diversity` | Distinct tokens held (balance > 0) | +0.3055 |
| 10 | `current_total_usd_log` | Log of current portfolio value USD | -0.2867 |
| 11 | `chains_active_on` | Non-BSC chains with activity (0-4) | +0.2205 |
| 12 | `net_flow_direction` | Accumulating (1) or depleting (0) over 90d | +0.2087 |
| 13 | `bsc_unique_active_days` | Unique active days on BSC | +0.1983 |
| 14 | `stablecoin_ratio` | Stablecoins as fraction of portfolio | +0.1905 |
| 15 | `unique_borrow_tokens` | Distinct tokens borrowed on Venus | -0.1224 |
| 16 | `unique_markets` | Distinct Venus markets used | -0.1224 |
| 17 | `bsc_unique_to_addresses` | Unique addresses interacted with | -0.1139 |
| 18 | `crosschain_total_tx_count_log` | Log of total non-BSC transactions | -0.0941 |
| 19 | `crosschain_dex_trade_count_log` | Log of non-BSC DEX trades | -0.0854 |
| 20 | `has_used_bridge` | Has used a cross-chain bridge | +0.0612 |
| 21 | `protocol_diversity_score` | DeFi categories used (1-3) | +0.0398 |
| 22 | `has_used_dex` | Has used a DEX on BSC | -0.0213 |
| 23 | `bsc_dex_trade_count_log` | Log of BSC DEX trade count | +0.0199 |

## Credit Score Distribution

| Statistic | Liquidated Wallets | Non-Liquidated Wallets |
|-----------|-------------------|----------------------|
| Mean | 36.7 | 62.3 |
| Median | 37.0 | 66.0 |
| Std Dev | 22.2 | 18.9 |
| Min | 0 | 0 |
| Max | 99 | 100 |

### Score Percentiles (all wallets)

| Percentile | Score |
|------------|-------|
| 5th | 14 |
| 25th | 47 |
| 50th (median) | 64 |
| 75th | 74 |
| 95th | 86 |

## Calibration

How well do predicted probabilities match actual outcomes?

| Predicted P(not liquidated) | Actual P(not liquidated) |
|---------------------------|-------------------------|
| 0.137 | 0.514 |
| 0.358 | 0.703 |
| 0.477 | 0.797 |
| 0.554 | 0.874 |
| 0.614 | 0.910 |
| 0.664 | 0.941 |
| 0.708 | 0.960 |
| 0.748 | 0.971 |
| 0.796 | 0.975 |
| 0.874 | 0.982 |

## Interpretation Notes

- The model was trained on **all-time Venus Protocol data on BSC**.
- Lending behavior features (borrow/repay patterns) are expected to dominate.
- Log-transformed features (USD amounts, tx counts) handle the heavy-tailed distributions.
- `class_weight='balanced'` adjusts for the 86/14 class split.
- The credit score is `P(not liquidated) * 100`, so higher = better.
- **This model is now FROZEN.** No further iteration during the hackathon.