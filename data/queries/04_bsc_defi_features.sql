-- =============================================================================
-- QUERY 04: BSC DeFi Sophistication Features
-- =============================================================================
-- PURPOSE: Measure how broadly each Venus borrower engages with the DeFi
--          ecosystem on BSC — DEX usage, bridge usage, protocol diversity.
--
-- DEPENDENCY: Uses the same Venus borrower population as Query 01.
--
-- OUTPUT COLUMNS:
--   wallet_address                VARCHAR  — wallet address
--   has_used_dex                  BOOLEAN  — any DEX swap on BSC
--   bsc_dex_trade_count           INT      — total DEX trades on BSC
--   bsc_dex_volume_usd            FLOAT    — total DEX volume in USD
--   bsc_unique_dex_projects       INT      — distinct DEX projects used
--   has_used_bridge               BOOLEAN  — any bridge transfer involving BSC
--   bsc_bridge_tx_count           INT      — bridge transfer count
--   bsc_unique_protocols          INT      — distinct contract addresses interacted with
--                                            (proxy for protocol diversity)
--   protocol_diversity_score      INT      — count of distinct DeFi categories used
--                                            (dex, lending, bridge = max 3 from our data)
--
-- EXPECTED ROW COUNT: Same as Query 01
--
-- NOTES:
--   - DEX data from crosschain.dex.trades filtered to chain = 'bsc'.
--   - Bridge data from crosschain.bridges.transfers.
--   - Protocol diversity is approximated by counting which categories the
--     wallet has activity in (DEX, lending, bridge). We already know all
--     wallets have lending activity (they're Venus borrowers), so the score
--     is 1 + has_used_dex + has_used_bridge.
--   - bsc_unique_protocols counts distinct to_address values from raw
--     transactions that are contract interactions (value of the contract
--     diversity). This is an expensive subquery; if it times out, we can
--     drop this column and rely on the category-based diversity score.
-- =============================================================================

WITH venus_wallets AS (
    SELECT DISTINCT borrower_address AS wallet_address
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
),

dex_stats AS (
    SELECT
        transaction_from_address        AS wallet_address,
        COUNT(*)                        AS bsc_dex_trade_count,
        SUM(usd_amount)                 AS bsc_dex_volume_usd,
        COUNT(DISTINCT project)         AS bsc_unique_dex_projects
    FROM crosschain.dex.trades
    WHERE chain = 'bsc'
      AND transaction_from_address IN (SELECT wallet_address FROM venus_wallets)
    GROUP BY transaction_from_address
),

bridge_stats AS (
    SELECT
        transaction_from_address        AS wallet_address,
        COUNT(*)                        AS bsc_bridge_tx_count
    FROM crosschain.bridges.transfers
    WHERE transaction_from_address IN (SELECT wallet_address FROM venus_wallets)
    GROUP BY transaction_from_address
)

SELECT
    vw.wallet_address,
    (COALESCE(d.bsc_dex_trade_count, 0) > 0) AS has_used_dex,
    COALESCE(d.bsc_dex_trade_count, 0)        AS bsc_dex_trade_count,
    COALESCE(d.bsc_dex_volume_usd, 0)         AS bsc_dex_volume_usd,
    COALESCE(d.bsc_unique_dex_projects, 0)    AS bsc_unique_dex_projects,
    (COALESCE(br.bsc_bridge_tx_count, 0) > 0) AS has_used_bridge,
    COALESCE(br.bsc_bridge_tx_count, 0)       AS bsc_bridge_tx_count,
    -- Protocol diversity score: count of DeFi categories used.
    -- All wallets have lending (=1), plus DEX and bridge if applicable.
    1
    + CASE WHEN COALESCE(d.bsc_dex_trade_count, 0) > 0 THEN 1 ELSE 0 END
    + CASE WHEN COALESCE(br.bsc_bridge_tx_count, 0) > 0 THEN 1 ELSE 0 END
                                               AS protocol_diversity_score
FROM venus_wallets vw
LEFT JOIN dex_stats d    ON vw.wallet_address = d.wallet_address
LEFT JOIN bridge_stats br ON vw.wallet_address = br.wallet_address
ORDER BY bsc_dex_trade_count DESC;
