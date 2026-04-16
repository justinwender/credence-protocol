-- =============================================================================
-- QUERY 03: BSC Lending Behavior Features (Venus Protocol)
-- =============================================================================
-- PURPOSE: Compute detailed lending behavior features for each Venus borrower.
--          These are expected to be the STRONGEST predictors of liquidation risk.
--
-- DEPENDENCY: Uses the same Venus borrower population as Query 01.
--
-- OUTPUT COLUMNS:
--   wallet_address              VARCHAR   — wallet address
--   borrow_count                INT       — total borrow events
--   repay_count                 INT       — total repay events
--   borrow_repay_ratio          FLOAT     — repay_count / borrow_count (>1 = positive signal)
--   total_borrowed_usd          FLOAT     — lifetime borrowed USD
--   total_repaid_usd            FLOAT     — lifetime repaid USD
--   avg_borrow_usd              FLOAT     — average borrow size in USD
--   max_borrow_usd              FLOAT     — largest single borrow in USD
--   unique_borrow_tokens        INT       — distinct tokens borrowed
--   unique_markets              INT       — distinct lending markets used
--   avg_loan_duration_days      FLOAT     — avg days between sequential borrow and repay
--   lending_active_days         INT       — distinct days with any lending activity
--   first_lending_ts            TIMESTAMP — first lending interaction
--   last_lending_ts             TIMESTAMP — most recent lending interaction
--
-- EXPECTED ROW COUNT: Same as Query 01
--
-- NOTES:
--   - borrow_repay_ratio > 1 indicates the wallet repays more often than it
--     borrows — a strong positive signal for creditworthiness.
--   - avg_loan_duration_days is an approximation: we compute the average gap
--     between a wallet's borrow events and repay events chronologically.
--     This is NOT a perfect loan-level duration (would need position tracking),
--     but it's a reasonable proxy at the wallet level.
--   - Some features originally planned (health factor, liquidation approaches)
--     require position-level data that Allium's lending tables don't directly
--     expose. We capture what's available; the model will determine which
--     features carry signal.
-- =============================================================================

WITH venus_wallets AS (
    SELECT DISTINCT borrower_address AS wallet_address
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
),

borrow_stats AS (
    SELECT
        borrower_address                AS wallet_address,
        COUNT(*)                        AS borrow_count,
        SUM(usd_amount)                 AS total_borrowed_usd,
        AVG(usd_amount)                 AS avg_borrow_usd,
        MAX(usd_amount)                 AS max_borrow_usd,
        COUNT(DISTINCT token_address)   AS unique_borrow_tokens,
        COUNT(DISTINCT market_address)  AS unique_markets,
        MIN(block_timestamp)            AS first_borrow_ts,
        MAX(block_timestamp)            AS last_borrow_ts
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
    GROUP BY borrower_address
),

repay_stats AS (
    SELECT
        borrower_address                AS wallet_address,
        COUNT(*)                        AS repay_count,
        SUM(usd_amount)                 AS total_repaid_usd,
        MIN(block_timestamp)            AS first_repay_ts,
        MAX(block_timestamp)            AS last_repay_ts
    FROM bsc.lending.repayments
    WHERE project = 'venus_finance'
    GROUP BY borrower_address
),

-- Compute lending active days from both borrow and repay events
lending_days AS (
    SELECT wallet_address, COUNT(DISTINCT activity_date) AS lending_active_days
    FROM (
        SELECT borrower_address AS wallet_address, DATE(block_timestamp) AS activity_date
        FROM bsc.lending.loans WHERE project = 'venus_finance'
        UNION ALL
        SELECT borrower_address AS wallet_address, DATE(block_timestamp) AS activity_date
        FROM bsc.lending.repayments WHERE project = 'venus_finance'
    )
    GROUP BY wallet_address
)

SELECT
    vw.wallet_address,
    COALESCE(bs.borrow_count, 0)          AS borrow_count,
    COALESCE(rs.repay_count, 0)           AS repay_count,
    CASE
        WHEN COALESCE(bs.borrow_count, 0) > 0
        THEN COALESCE(rs.repay_count, 0)::FLOAT / bs.borrow_count
        ELSE 0
    END                                    AS borrow_repay_ratio,
    COALESCE(bs.total_borrowed_usd, 0)    AS total_borrowed_usd,
    COALESCE(rs.total_repaid_usd, 0)      AS total_repaid_usd,
    bs.avg_borrow_usd,
    bs.max_borrow_usd,
    COALESCE(bs.unique_borrow_tokens, 0)  AS unique_borrow_tokens,
    COALESCE(bs.unique_markets, 0)        AS unique_markets,
    -- Approximate average loan duration: days between first borrow and first repay,
    -- averaged with days between last borrow and last repay
    CASE
        WHEN rs.first_repay_ts IS NOT NULL AND bs.first_borrow_ts IS NOT NULL
        THEN DATEDIFF('day', bs.first_borrow_ts, rs.last_repay_ts)::FLOAT
             / GREATEST(COALESCE(rs.repay_count, 1), 1)
        ELSE NULL
    END                                    AS avg_loan_duration_days,
    COALESCE(ld.lending_active_days, 0)   AS lending_active_days,
    LEAST(bs.first_borrow_ts, rs.first_repay_ts) AS first_lending_ts,
    GREATEST(bs.last_borrow_ts, rs.last_repay_ts) AS last_lending_ts
FROM venus_wallets vw
LEFT JOIN borrow_stats bs ON vw.wallet_address = bs.wallet_address
LEFT JOIN repay_stats rs  ON vw.wallet_address = rs.wallet_address
LEFT JOIN lending_days ld ON vw.wallet_address = ld.wallet_address
ORDER BY borrow_count DESC;
