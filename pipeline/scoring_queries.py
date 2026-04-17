"""
Credence Protocol — Single-Wallet Scoring SQL Queries
=====================================================
Two parameterized SQL queries run concurrently via the Allium Explorer API
to compute all 10 model features for a single wallet address.

Query A: BSC-specific (Venus lending + balances + net flow)
Query B: Crosschain (tx counts, DEX trades, bridge usage)

Both use CTE-based aggregation to minimize round trips.
"""

# ──────────────────────────────────────────────────────────────────────────────
# QUERY A: BSC Features (Venus lending + balances + 90-day net flow)
# ──────────────────────────────────────────────────────────────────────────────
# Returns a SINGLE ROW with all BSC features for the given wallet.
# If the wallet has never used Venus, lending features will be NULL/0.

QUERY_A_BSC = """
WITH params AS (
    SELECT LOWER('{wallet_address}') AS wallet
),

borrow_stats AS (
    SELECT
        COUNT(*) AS borrow_count,
        COUNT(DISTINCT token_address) AS unique_borrow_tokens
    FROM bsc.lending.loans
    WHERE project = 'venus_finance'
      AND borrower_address = (SELECT wallet FROM params)
),

repay_stats AS (
    SELECT COUNT(*) AS repay_count
    FROM bsc.lending.repayments
    WHERE project = 'venus_finance'
      AND borrower_address = (SELECT wallet FROM params)
),

lending_days AS (
    SELECT COUNT(DISTINCT activity_date) AS lending_active_days
    FROM (
        SELECT DATE(block_timestamp) AS activity_date
        FROM bsc.lending.loans
        WHERE project = 'venus_finance'
          AND borrower_address = (SELECT wallet FROM params)
        UNION ALL
        SELECT DATE(block_timestamp) AS activity_date
        FROM bsc.lending.repayments
        WHERE project = 'venus_finance'
          AND borrower_address = (SELECT wallet FROM params)
    )
),

balances AS (
    SELECT
        COALESCE(SUM(usd_balance_current), 0) AS current_total_usd,
        COALESCE(SUM(CASE
            WHEN LOWER(token_address) IN (
                '0x55d398326f99059ff775485246999027b3197955',
                '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',
                '0xe9e7cea3dedca5984780bafc599bd69add087d56',
                '0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3'
            ) THEN usd_balance_current ELSE 0
        END), 0) AS current_stablecoin_usd
    FROM bsc.assets.fungible_balances_latest
    WHERE address = (SELECT wallet FROM params)
),

net_flow AS (
    SELECT
        COALESCE(SUM(CASE WHEN to_address = p.wallet THEN COALESCE(usd_amount, 0) ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN from_address = p.wallet THEN COALESCE(usd_amount, 0) ELSE 0 END), 0)
        AS net_flow_usd_90d
    FROM crosschain.assets.transfers t
    CROSS JOIN params p
    WHERE chain = 'bsc'
      AND (t.from_address = p.wallet OR t.to_address = p.wallet)
      AND t.block_timestamp >= CURRENT_TIMESTAMP - INTERVAL '90 days'
)

SELECT
    (SELECT wallet FROM params) AS wallet_address,
    COALESCE(bs.borrow_count, 0) AS borrow_count,
    COALESCE(rs.repay_count, 0) AS repay_count,
    CASE
        WHEN COALESCE(bs.borrow_count, 0) > 0
        THEN COALESCE(rs.repay_count, 0)::FLOAT / bs.borrow_count
        ELSE 0
    END AS borrow_repay_ratio,
    COALESCE(bs.unique_borrow_tokens, 0) AS unique_borrow_tokens,
    COALESCE(ld.lending_active_days, 0) AS lending_active_days,
    bl.current_total_usd,
    bl.current_stablecoin_usd,
    CASE
        WHEN bl.current_total_usd > 0
        THEN bl.current_stablecoin_usd / bl.current_total_usd
        ELSE 0
    END AS stablecoin_ratio,
    nf.net_flow_usd_90d
FROM borrow_stats bs
CROSS JOIN repay_stats rs
CROSS JOIN lending_days ld
CROSS JOIN balances bl
CROSS JOIN net_flow nf
"""


# ──────────────────────────────────────────────────────────────────────────────
# QUERY B: Crosschain Features
# ──────────────────────────────────────────────────────────────────────────────
# Returns a SINGLE ROW with crosschain activity metrics.
# Uses crosschain.* unified tables (slight undercount vs raw.transactions
# for tx_count — accepted tradeoff, <1 point impact on score).

QUERY_B_CROSSCHAIN = """
WITH params AS (
    SELECT LOWER('{wallet_address}') AS wallet
),

chain_transfers AS (
    SELECT
        chain,
        COUNT(*) AS transfer_count
    FROM crosschain.assets.transfers
    WHERE from_address = (SELECT wallet FROM params)
      AND chain IN ('ethereum', 'arbitrum', 'polygon', 'optimism')
    GROUP BY chain
),

chain_summary AS (
    SELECT
        COALESCE(SUM(transfer_count), 0) AS crosschain_total_tx_count,
        COUNT(DISTINCT chain) AS chains_active_on
    FROM chain_transfers
),

dex_stats AS (
    SELECT COUNT(*) AS crosschain_dex_trade_count
    FROM crosschain.dex.trades
    WHERE transaction_from_address = (SELECT wallet FROM params)
      AND chain IN ('ethereum', 'arbitrum', 'polygon', 'optimism')
),

bridge_stats AS (
    SELECT
        CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS has_used_bridge
    FROM crosschain.bridges.transfers
    WHERE transaction_from_address = (SELECT wallet FROM params)
)

SELECT
    (SELECT wallet FROM params) AS wallet_address,
    cs.crosschain_total_tx_count,
    cs.chains_active_on,
    COALESCE(ds.crosschain_dex_trade_count, 0) AS crosschain_dex_trade_count,
    br.has_used_bridge
FROM chain_summary cs
CROSS JOIN dex_stats ds
CROSS JOIN bridge_stats br
"""


def build_query_a(wallet_address: str) -> str:
    """Parameterize Query A with a wallet address."""
    return QUERY_A_BSC.format(wallet_address=wallet_address.lower().strip())


def build_query_b(wallet_address: str) -> str:
    """Parameterize Query B with a wallet address."""
    return QUERY_B_CROSSCHAIN.format(wallet_address=wallet_address.lower().strip())
