-- =============================================================================
-- QUERY 01: Venus Protocol Borrower Labels
-- =============================================================================
-- PURPOSE: Build the labeled dataset of all wallets that have ever borrowed on
--          Venus Protocol (BSC). The label is binary: was this wallet ever
--          liquidated on Venus?
--
-- OUTPUT COLUMNS:
--   borrower_address  VARCHAR   — wallet address (lowercase hex)
--   total_borrows     INT       — lifetime borrow event count on Venus
--   total_repays      INT       — lifetime repay event count on Venus
--   total_liquidations INT      — lifetime liquidation count (0 = never liquidated)
--   was_liquidated    BOOLEAN   — TRUE if total_liquidations > 0 (our label)
--   first_borrow_ts   TIMESTAMP — earliest borrow timestamp
--   last_borrow_ts    TIMESTAMP — most recent borrow timestamp
--   total_borrowed_usd FLOAT   — lifetime borrowed USD (sum across all borrows)
--   total_repaid_usd   FLOAT   — lifetime repaid USD
--   total_liquidated_usd FLOAT — lifetime liquidated collateral USD (0 if never liquidated)
--
-- EXPECTED ROW COUNT: ~10K–100K wallets (depends on Venus's total borrower base)
--
-- NOTES:
--   - We pull borrow, repay, and liquidation counts in a single query via
--     subquery aggregation + LEFT JOINs so that wallets with zero liquidations
--     still appear (they are our negative class).
--   - Filter: project = 'venus_finance' on all three tables.
--   - Run this query FIRST. The output wallet list is the join key for all
--     subsequent feature queries (02–06).
-- =============================================================================

WITH borrows AS (
    SELECT
        borrower_address,
        COUNT(*)                    AS total_borrows,
        MIN(block_timestamp)        AS first_borrow_ts,
        MAX(block_timestamp)        AS last_borrow_ts,
        SUM(usd_amount)             AS total_borrowed_usd
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
    GROUP BY borrower_address
),

repays AS (
    SELECT
        borrower_address,
        COUNT(*)        AS total_repays,
        SUM(usd_amount) AS total_repaid_usd
    FROM bsc.lending.repayments
    WHERE project = 'venus_finance'
    GROUP BY borrower_address
),

liquidations AS (
    SELECT
        borrower_address,
        COUNT(*)        AS total_liquidations,
        SUM(usd_amount) AS total_liquidated_usd
    FROM bsc.lending.liquidations
    WHERE project = 'venus_finance'
    GROUP BY borrower_address
)

SELECT
    b.borrower_address,
    b.total_borrows,
    COALESCE(r.total_repays, 0)          AS total_repays,
    COALESCE(l.total_liquidations, 0)    AS total_liquidations,
    (COALESCE(l.total_liquidations, 0) > 0) AS was_liquidated,
    b.first_borrow_ts,
    b.last_borrow_ts,
    b.total_borrowed_usd,
    COALESCE(r.total_repaid_usd, 0)      AS total_repaid_usd,
    COALESCE(l.total_liquidated_usd, 0)  AS total_liquidated_usd
FROM borrows b
LEFT JOIN repays r       ON b.borrower_address = r.borrower_address
LEFT JOIN liquidations l ON b.borrower_address = l.borrower_address
ORDER BY b.total_borrows DESC;
