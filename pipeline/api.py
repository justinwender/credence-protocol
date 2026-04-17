"""
Credence Protocol — Scoring API
================================
FastAPI server exposing a single endpoint:

    POST /score
    Body: {"address": "0x..."} or {"ens": "name.eth"}

Workflow per request:
  1. Run two Allium Explorer SQL queries concurrently (BSC + crosschain)
  2. Merge results into a raw feature dictionary
  3. Apply the frozen FICO-style scorecard model (model/score.py)
  4. Push the onchain score to CreditOracle on BSC testnet
  5. Return the score, factor breakdown, and data completeness indicator

Usage:
    uvicorn pipeline.api:app --host 0.0.0.0 --port 8000 --reload
"""

import sys
import time
import json
import traceback
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# Add project root for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.config import (
    ALLIUM_API_KEY,
    ALLIUM_API_BASE,
    ALLIUM_MAX_ROWS,
    ALLIUM_POLL_INTERVAL,
    ALLIUM_POLL_TIMEOUT,
)
from pipeline.scoring_queries import build_query_a, build_query_b
from pipeline.push_score import push_onchain_score, read_composite_score
from model.score import score_wallet

# ──────────────────────────────────────────────────────────────────────────────
# FastAPI App
# ──────────────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="Credence Protocol Scoring API",
    description="On-demand credit scoring for BNB Chain wallets",
    version="0.1.0",
)

# Allow CORS from any origin (frontend runs on a different port during dev)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ──────────────────────────────────────────────────────────────────────────────
# Request / Response models
# ──────────────────────────────────────────────────────────────────────────────

class ScoreRequest(BaseModel):
    address: str = Field(..., description="Wallet address (0x hex string)")


class FactorItem(BaseModel):
    feature: str
    display_name: str
    bin: str
    coefficient: float
    is_reference: bool


class ScoreResponse(BaseModel):
    address: str
    credit_score: int
    chains_used: int
    data_completeness: str
    factor_breakdown: list[FactorItem]
    # On-chain state after pushing
    composite_score: int | None = None
    collateral_ratio_bps: int | None = None
    tx_hash: str | None = None
    error: str | None = None


# ──────────────────────────────────────────────────────────────────────────────
# Allium Explorer API helpers
# ──────────────────────────────────────────────────────────────────────────────

ALLIUM_HEADERS = {
    "X-API-KEY": ALLIUM_API_KEY,
    "Content-Type": "application/json",
}


def _run_allium_query(sql: str, label: str, start_delay: float = 0) -> dict | None:
    """
    Create → run → poll → fetch results for a single SQL query.
    Returns the first row as a dict, or None if no rows or error.

    `start_delay` staggers concurrent requests to avoid rate limits.
    """
    if start_delay > 0:
        time.sleep(start_delay)

    try:
        # 1. Create saved query (with retry on 429)
        for attempt in range(3):
            resp = requests.post(
                f"{ALLIUM_API_BASE}/queries",
                headers=ALLIUM_HEADERS,
                json={
                    "title": f"credence_live_{label}_{int(time.time())}",
                    "config": {"sql": sql, "limit": ALLIUM_MAX_ROWS},
                },
                timeout=30,
            )
            if resp.status_code == 429:
                wait = 5 * (attempt + 1)
                print(f"  [{label}] Rate limited (429), retrying in {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            break
        else:
            print(f"  [{label}] Rate limited after 3 retries")
            return None
        query_id = resp.json().get("query_id") or resp.json().get("id")

        # 2. Run async (with retry on 429)
        for attempt in range(3):
            resp = requests.post(
                f"{ALLIUM_API_BASE}/queries/{query_id}/run-async",
                headers=ALLIUM_HEADERS,
                json={"parameters": {}, "run_config": {"limit": ALLIUM_MAX_ROWS}},
                timeout=30,
            )
            if resp.status_code == 429:
                wait = 5 * (attempt + 1)
                print(f"  [{label}] Rate limited on run (429), retrying in {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            break
        else:
            print(f"  [{label}] Rate limited on run after 3 retries")
            return None
        run_id = resp.json().get("run_id") or resp.json().get("id")

        # 3. Poll for completion
        start = time.time()
        while time.time() - start < ALLIUM_POLL_TIMEOUT:
            resp = requests.get(
                f"{ALLIUM_API_BASE}/query-runs/{run_id}/results",
                headers={"X-API-KEY": ALLIUM_API_KEY},
                params={"f": "json"},
                timeout=30,
            )
            if resp.status_code == 200:
                raw = resp.text
                if raw and raw.strip() != "null" and len(raw) > 10:
                    data = resp.json()
                    if data and isinstance(data, dict) and data.get("data"):
                        rows = data["data"]
                        return rows[0] if rows else None
            time.sleep(ALLIUM_POLL_INTERVAL)

        print(f"[{label}] Timed out after {ALLIUM_POLL_TIMEOUT}s")
        return None

    except Exception as e:
        print(f"[{label}] Error: {e}")
        traceback.print_exc()
        return None


def _query_wallet_features(address: str) -> tuple[dict, str, int]:
    """
    Run Query A (BSC) and Query B (crosschain) concurrently.

    Returns:
        (raw_features_dict, data_completeness_label, chains_used_count)
    """
    sql_a = build_query_a(address)
    sql_b = build_query_b(address)

    results = {"a": None, "b": None}

    with ThreadPoolExecutor(max_workers=2) as pool:
        future_a = pool.submit(_run_allium_query, sql_a, "bsc", 0)
        future_b = pool.submit(_run_allium_query, sql_b, "crosschain", 3)  # stagger 3s to avoid rate limit

        for future in as_completed([future_a, future_b]):
            if future == future_a:
                results["a"] = future.result()
            else:
                results["b"] = future.result()

    # BSC query is required
    if results["a"] is None:
        raise RuntimeError("BSC query failed — cannot score without Venus lending data")

    a = results["a"]
    b = results["b"]

    # Build raw feature dict from query results
    raw = {
        # From Query A (BSC)
        "lending_active_days": int(a.get("lending_active_days", 0) or 0),
        "borrow_repay_ratio": float(a.get("borrow_repay_ratio", 0) or 0),
        "repay_count": int(a.get("repay_count", 0) or 0),
        "unique_borrow_tokens": max(int(a.get("unique_borrow_tokens", 0) or 0), 1),
        "current_total_usd": float(a.get("current_total_usd", 0) or 0),
        "stablecoin_ratio": float(a.get("stablecoin_ratio", 0) or 0),
        "net_flow_usd_90d": float(a.get("net_flow_usd_90d", 0) or 0),
    }

    # Determine crosschain data availability
    if b is not None:
        raw["crosschain_total_tx_count"] = int(b.get("crosschain_total_tx_count", 0) or 0)
        raw["crosschain_dex_trade_count"] = int(b.get("crosschain_dex_trade_count", 0) or 0)
        raw["chains_active_on"] = int(b.get("chains_active_on", 0) or 0)
        raw["has_used_bridge"] = int(b.get("has_used_bridge", 0) or 0)
        # chains_used = BSC (always 1) + non-BSC chains with activity
        chains_used = 1 + raw["chains_active_on"]
        completeness = f"{chains_used}-chain history"
    else:
        # Crosschain degraded — default to reference bins (0)
        raw["crosschain_total_tx_count"] = 0
        raw["crosschain_dex_trade_count"] = 0
        raw["chains_active_on"] = 0
        raw["has_used_bridge"] = 0
        chains_used = 1
        completeness = "BNB Chain only (crosschain data unavailable)"

    return raw, completeness, chains_used


# ──────────────────────────────────────────────────────────────────────────────
# Main endpoint
# ──────────────────────────────────────────────────────────────────────────────

@app.post("/score", response_model=ScoreResponse)
async def score_endpoint(req: ScoreRequest):
    """
    Score a wallet: query Allium → run model → push to CreditOracle → return.
    """
    address = req.address.strip()
    if not address.startswith("0x") or len(address) != 42:
        raise HTTPException(400, "Invalid address format (expected 0x + 40 hex chars)")

    print(f"\n{'='*60}")
    print(f"Scoring wallet: {address}")
    print(f"{'='*60}")

    # Step 1: Query features from Allium
    t0 = time.time()
    try:
        raw_features, completeness, chains_used = _query_wallet_features(address)
    except RuntimeError as e:
        raise HTTPException(503, str(e))
    t_query = time.time() - t0
    print(f"  [1/3] Allium queries completed in {t_query:.1f}s")
    print(f"        Data completeness: {completeness}")
    print(f"        Raw features: {json.dumps(raw_features, indent=2)}")

    # Step 2: Run the frozen model
    t1 = time.time()
    try:
        result = score_wallet(raw_features)
    except Exception as e:
        raise HTTPException(500, f"Model inference failed: {e}")
    credit_score = result["credit_score"]
    t_model = time.time() - t1
    print(f"  [2/3] Model inference in {t_model*1000:.0f}ms → score {credit_score}")

    # Step 3: Push score to CreditOracle
    tx_hash = None
    composite = None
    collateral_bps = None
    push_error = None

    t2 = time.time()
    try:
        tx_hash = push_onchain_score(address, credit_score, chains_used)
        print(f"  [3/3] Pushed to CreditOracle: tx {tx_hash}")

        # Read back the composite + collateral from on-chain
        profile = read_composite_score(address)
        composite = profile["composite_score"]

        # Read collateral ratio from LendingPool
        from pipeline.config import LENDING_POOL_ADDRESS, get_pool_abi
        from web3 import Web3
        from pipeline.push_score import get_web3
        w3 = get_web3()
        pool_contract = w3.eth.contract(
            address=Web3.to_checksum_address(LENDING_POOL_ADDRESS),
            abi=get_pool_abi(),
        )
        collateral_bps = pool_contract.functions.getBorrowerCollateralRatioBps(
            Web3.to_checksum_address(address)
        ).call()

        print(f"        On-chain composite: {composite}")
        print(f"        Collateral ratio: {collateral_bps} bps ({collateral_bps/100:.1f}%)")
    except Exception as e:
        push_error = str(e)
        print(f"  [3/3] Push failed: {push_error}")

    t_push = time.time() - t2
    t_total = time.time() - t0
    print(f"  Total time: {t_total:.1f}s (query={t_query:.1f}s, model={t_model*1000:.0f}ms, push={t_push:.1f}s)")

    # Build response
    breakdown = [
        FactorItem(
            feature=f["feature"],
            display_name=f["display_name"],
            bin=f["bin"],
            coefficient=f["coefficient"],
            is_reference=f["is_reference"],
        )
        for f in result["factor_breakdown"]
    ]

    return ScoreResponse(
        address=address,
        credit_score=credit_score,
        chains_used=chains_used,
        data_completeness=completeness,
        factor_breakdown=breakdown,
        composite_score=composite,
        collateral_ratio_bps=collateral_bps,
        tx_hash=tx_hash,
        error=push_error,
    )


# ──────────────────────────────────────────────────────────────────────────────
# Health check
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_loaded": True,
        "allium_configured": bool(ALLIUM_API_KEY),
        "oracle_configured": bool(
            __import__("pipeline.config", fromlist=["CREDIT_ORACLE_ADDRESS"]).CREDIT_ORACLE_ADDRESS
        ),
    }
