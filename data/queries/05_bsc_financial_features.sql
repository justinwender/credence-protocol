-- =============================================================================
-- QUERY 05: BSC Financial Profile Features
-- =============================================================================
-- PURPOSE: Compute financial profile features for each Venus borrower using
--          token balance snapshots and transfer data on BSC.
--
-- DEPENDENCY: Uses the same Venus borrower population as Query 01.
--
-- OUTPUT COLUMNS:
--   wallet_address          VARCHAR  — wallet address
--   current_total_usd       FLOAT    — current total portfolio value in USD
--   current_native_usd      FLOAT    — current native BNB balance in USD
--   current_stablecoin_usd  FLOAT    — current stablecoin holdings in USD
--   stablecoin_ratio        FLOAT    — stablecoins as fraction of total holdings
--   token_diversity          INT     — count of distinct tokens currently held (balance > 0)
--   net_flow_usd_90d        FLOAT    — net token flow in USD over trailing 90 days
--                                      (positive = accumulating, negative = depleting)
--
-- EXPECTED ROW COUNT: Same as Query 01
--
-- NOTES:
--   - Uses bsc.assets.fungible_balances_latest for current portfolio snapshot.
--   - Stablecoin identification: we match on well-known BSC stablecoin addresses.
--     Major BSC stablecoins:
--       USDT: 0x55d398326f99059fF775485246999027B3197955
--       USDC: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d
--       BUSD: 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56
--       DAI:  0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3
--   - Native BNB token_address is typically 0x0000...0000 in Allium's schema.
--   - Net flow is computed from crosschain.assets.transfers over the last 90 days:
--     sum of inflows minus outflows. If this subquery is too slow, we can drop
--     the 90-day net flow column and compute it in Python from the raw CSV.
--   - token_diversity only counts tokens with a positive balance.
-- =============================================================================

WITH venus_wallets AS (
    SELECT DISTINCT borrower_address AS wallet_address
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
),

-- Current portfolio from latest balances
portfolio AS (
    SELECT
        bl.address                                              AS wallet_address,
        SUM(bl.usd_balance_current)                             AS current_total_usd,
        SUM(CASE
            WHEN bl.token_address = '0x0000000000000000000000000000000000000000'
            THEN bl.usd_balance_current ELSE 0
        END)                                                    AS current_native_usd,
        SUM(CASE
            WHEN LOWER(bl.token_address) IN (
                '0x55d398326f99059ff775485246999027b3197955',  -- USDT
                '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',  -- USDC
                '0xe9e7cea3dedca5984780bafc599bd69add087d56',  -- BUSD
                '0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3'   -- DAI
            )
            THEN bl.usd_balance_current ELSE 0
        END)                                                    AS current_stablecoin_usd,
        COUNT(DISTINCT CASE
            WHEN bl.balance > 0 THEN bl.token_address
        END)                                                    AS token_diversity
    FROM bsc.assets.fungible_balances_latest bl
    WHERE bl.address IN (SELECT wallet_address FROM venus_wallets)
    GROUP BY bl.address
),

-- Net token flow over trailing 90 days (inflows minus outflows)
net_flow AS (
    SELECT
        wallet_address,
        SUM(inflow_usd) - SUM(outflow_usd) AS net_flow_usd_90d
    FROM (
        -- Inflows: wallet is the recipient
        SELECT
            to_address AS wallet_address,
            SUM(COALESCE(usd_amount, 0)) AS inflow_usd,
            0 AS outflow_usd
        FROM crosschain.assets.transfers
        WHERE chain = 'bsc'
          AND to_address IN (SELECT wallet_address FROM venus_wallets)
          AND block_timestamp >= CURRENT_TIMESTAMP - INTERVAL '90 days'
        GROUP BY to_address

        UNION ALL

        -- Outflows: wallet is the sender
        SELECT
            from_address AS wallet_address,
            0 AS inflow_usd,
            SUM(COALESCE(usd_amount, 0)) AS outflow_usd
        FROM crosschain.assets.transfers
        WHERE chain = 'bsc'
          AND from_address IN (SELECT wallet_address FROM venus_wallets)
          AND block_timestamp >= CURRENT_TIMESTAMP - INTERVAL '90 days'
        GROUP BY from_address
    )
    GROUP BY wallet_address
)

SELECT
    vw.wallet_address,
    COALESCE(p.current_total_usd, 0)        AS current_total_usd,
    COALESCE(p.current_native_usd, 0)       AS current_native_usd,
    COALESCE(p.current_stablecoin_usd, 0)   AS current_stablecoin_usd,
    CASE
        WHEN COALESCE(p.current_total_usd, 0) > 0
        THEN COALESCE(p.current_stablecoin_usd, 0) / p.current_total_usd
        ELSE 0
    END                                      AS stablecoin_ratio,
    COALESCE(p.token_diversity, 0)           AS token_diversity,
    COALESCE(nf.net_flow_usd_90d, 0)        AS net_flow_usd_90d
FROM venus_wallets vw
LEFT JOIN portfolio p   ON vw.wallet_address = p.wallet_address
LEFT JOIN net_flow nf   ON vw.wallet_address = nf.wallet_address
ORDER BY current_total_usd DESC;
