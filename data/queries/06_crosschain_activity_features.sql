-- =============================================================================
-- QUERY 06: Crosschain Activity Features
-- =============================================================================
-- PURPOSE: Compute activity features across Ethereum, Arbitrum, Polygon, and
--          Optimism for each Venus borrower. These wallets may have ZERO
--          activity on other chains — that's expected and informative.
--
-- DEPENDENCY: Uses the same Venus borrower population as Query 01.
--
-- OUTPUT COLUMNS:
--   wallet_address              VARCHAR  — wallet address (from Venus borrower set)
--   chains_active_on            INT      — count of non-BSC chains with >= 1 tx (0–4)
--   eth_tx_count                INT      — Ethereum transaction count (0 if no activity)
--   eth_active_days             INT      — Ethereum unique active days
--   arbitrum_tx_count           INT      — Arbitrum transaction count
--   arbitrum_active_days        INT      — Arbitrum unique active days
--   polygon_tx_count            INT      — Polygon transaction count
--   polygon_active_days         INT      — Polygon unique active days
--   optimism_tx_count           INT      — Optimism transaction count
--   optimism_active_days        INT      — Optimism unique active days
--   crosschain_total_tx_count   INT      — sum of all non-BSC chain tx counts
--   crosschain_total_active_days INT     — sum of active days across all non-BSC chains
--   crosschain_dex_trade_count  INT      — DEX trades across all non-BSC chains
--   crosschain_dex_volume_usd   FLOAT    — DEX volume across all non-BSC chains
--
-- EXPECTED ROW COUNT: Same as Query 01 (every Venus borrower appears, even
--                     if they have zero crosschain activity)
--
-- CRITICAL DESIGN NOTE:
--   Many Venus borrowers will have ZERO activity on other chains. This query
--   uses LEFT JOINs from the venus_wallets CTE so that these wallets appear
--   in the output with zeroes rather than being dropped by an inner join.
--   The model needs to see these zero-activity wallets to learn the signal
--   (or lack thereof) from crosschain presence.
--
-- PERFORMANCE NOTE:
--   This query joins the Venus wallet list against raw.transactions on 4
--   different chains. Each join scans a large table. If Explorer times out:
--   Option A: Split into 4 separate queries (one per chain) and merge in Python.
--   Option B: Use crosschain.assets.transfers (unified table) instead of
--             per-chain raw.transactions — smaller table, may miss some txs
--             but covers the transfer activity we care about.
--   Flag if this query fails and we'll adapt.
-- =============================================================================

WITH venus_wallets AS (
    SELECT DISTINCT borrower_address AS wallet_address
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
),

-- Ethereum activity
eth_activity AS (
    SELECT
        from_address                            AS wallet_address,
        COUNT(*)                                AS tx_count,
        COUNT(DISTINCT DATE(block_timestamp))   AS active_days
    FROM ethereum.raw.transactions
    WHERE from_address IN (SELECT wallet_address FROM venus_wallets)
      AND receipt_status = 1
    GROUP BY from_address
),

-- Arbitrum activity
arb_activity AS (
    SELECT
        from_address                            AS wallet_address,
        COUNT(*)                                AS tx_count,
        COUNT(DISTINCT DATE(block_timestamp))   AS active_days
    FROM arbitrum.raw.transactions
    WHERE from_address IN (SELECT wallet_address FROM venus_wallets)
      AND receipt_status = 1
    GROUP BY from_address
),

-- Polygon activity
poly_activity AS (
    SELECT
        from_address                            AS wallet_address,
        COUNT(*)                                AS tx_count,
        COUNT(DISTINCT DATE(block_timestamp))   AS active_days
    FROM polygon.raw.transactions
    WHERE from_address IN (SELECT wallet_address FROM venus_wallets)
      AND receipt_status = 1
    GROUP BY from_address
),

-- Optimism activity
op_activity AS (
    SELECT
        from_address                            AS wallet_address,
        COUNT(*)                                AS tx_count,
        COUNT(DISTINCT DATE(block_timestamp))   AS active_days
    FROM optimism.raw.transactions
    WHERE from_address IN (SELECT wallet_address FROM venus_wallets)
      AND receipt_status = 1
    GROUP BY from_address
),

-- Crosschain DEX trades (non-BSC chains)
xchain_dex AS (
    SELECT
        transaction_from_address                AS wallet_address,
        COUNT(*)                                AS dex_trade_count,
        SUM(usd_amount)                         AS dex_volume_usd
    FROM crosschain.dex.trades
    WHERE chain IN ('ethereum', 'arbitrum', 'polygon', 'optimism')
      AND transaction_from_address IN (SELECT wallet_address FROM venus_wallets)
    GROUP BY transaction_from_address
)

SELECT
    vw.wallet_address,

    -- Count of chains with any activity (0–4)
    (CASE WHEN COALESCE(e.tx_count, 0)  > 0 THEN 1 ELSE 0 END
   + CASE WHEN COALESCE(a.tx_count, 0)  > 0 THEN 1 ELSE 0 END
   + CASE WHEN COALESCE(p.tx_count, 0)  > 0 THEN 1 ELSE 0 END
   + CASE WHEN COALESCE(o.tx_count, 0)  > 0 THEN 1 ELSE 0 END)
                                                AS chains_active_on,

    -- Per-chain breakdowns (zeroed if no activity)
    COALESCE(e.tx_count, 0)                     AS eth_tx_count,
    COALESCE(e.active_days, 0)                  AS eth_active_days,
    COALESCE(a.tx_count, 0)                     AS arbitrum_tx_count,
    COALESCE(a.active_days, 0)                  AS arbitrum_active_days,
    COALESCE(p.tx_count, 0)                     AS polygon_tx_count,
    COALESCE(p.active_days, 0)                  AS polygon_active_days,
    COALESCE(o.tx_count, 0)                     AS optimism_tx_count,
    COALESCE(o.active_days, 0)                  AS optimism_active_days,

    -- Aggregated crosschain totals
    (COALESCE(e.tx_count, 0) + COALESCE(a.tx_count, 0)
   + COALESCE(p.tx_count, 0) + COALESCE(o.tx_count, 0))
                                                AS crosschain_total_tx_count,
    (COALESCE(e.active_days, 0) + COALESCE(a.active_days, 0)
   + COALESCE(p.active_days, 0) + COALESCE(o.active_days, 0))
                                                AS crosschain_total_active_days,

    -- Crosschain DEX activity
    COALESCE(xd.dex_trade_count, 0)             AS crosschain_dex_trade_count,
    COALESCE(xd.dex_volume_usd, 0)              AS crosschain_dex_volume_usd

FROM venus_wallets vw
LEFT JOIN eth_activity e   ON vw.wallet_address = e.wallet_address
LEFT JOIN arb_activity a   ON vw.wallet_address = a.wallet_address
LEFT JOIN poly_activity p  ON vw.wallet_address = p.wallet_address
LEFT JOIN op_activity o    ON vw.wallet_address = o.wallet_address
LEFT JOIN xchain_dex xd    ON vw.wallet_address = xd.wallet_address
ORDER BY chains_active_on DESC, crosschain_total_tx_count DESC;
