-- =============================================================================
-- QUERY 02: BSC On-Chain Activity Features
-- =============================================================================
-- PURPOSE: Compute wallet-level activity features from BSC raw transactions
--          for all wallets in the Venus borrower set (Query 01).
--
-- DEPENDENCY: Run Query 01 first. This query uses the same borrower_address
--             population by joining against bsc.lending.loans.
--
-- OUTPUT COLUMNS:
--   wallet_address            VARCHAR   — wallet address
--   bsc_total_tx_count        INT       — total transactions sent on BSC
--   bsc_unique_active_days    INT       — distinct days with >= 1 tx
--   bsc_avg_tx_per_active_day FLOAT     — total_tx / active_days
--   bsc_wallet_age_days       INT       — days between first and last tx
--   bsc_first_tx_ts           TIMESTAMP — first transaction timestamp
--   bsc_last_tx_ts            TIMESTAMP — most recent transaction timestamp
--   bsc_unique_to_addresses   INT       — distinct addresses interacted with
--
-- EXPECTED ROW COUNT: Same as Query 01 (~10K–100K wallets)
--
-- NOTES:
--   - Only counts SENT transactions (from_address = wallet).
--   - Only successful transactions (receipt_status = 1).
--   - bsc.raw.transactions is a large table. Filtering on a wallet set via
--     an IN subquery may be slow; Allium Explorer should handle this but
--     expect this query to take longer than the others.
--   - If this query times out, we can split it: first export the wallet list
--     from Q01, then run this with an explicit WHERE IN (...) clause on a
--     smaller batch. Flag if needed.
-- =============================================================================

WITH venus_wallets AS (
    SELECT DISTINCT borrower_address AS wallet_address
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
)

SELECT
    vw.wallet_address,
    COUNT(t.hash)                                           AS bsc_total_tx_count,
    COUNT(DISTINCT DATE(t.block_timestamp))                 AS bsc_unique_active_days,
    CASE
        WHEN COUNT(DISTINCT DATE(t.block_timestamp)) > 0
        THEN COUNT(t.hash)::FLOAT / COUNT(DISTINCT DATE(t.block_timestamp))
        ELSE 0
    END                                                     AS bsc_avg_tx_per_active_day,
    DATEDIFF('day', MIN(t.block_timestamp), MAX(t.block_timestamp)) AS bsc_wallet_age_days,
    MIN(t.block_timestamp)                                  AS bsc_first_tx_ts,
    MAX(t.block_timestamp)                                  AS bsc_last_tx_ts,
    COUNT(DISTINCT t.to_address)                            AS bsc_unique_to_addresses
FROM venus_wallets vw
LEFT JOIN bsc.raw.transactions t
    ON vw.wallet_address = t.from_address
    AND t.receipt_status = 1
GROUP BY vw.wallet_address
ORDER BY bsc_total_tx_count DESC;
