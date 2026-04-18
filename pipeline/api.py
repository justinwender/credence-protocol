"""
Credence Protocol — Scoring API
================================
FastAPI server exposing a single endpoint:

    POST /score
    Body: {"address": "0x..."}

Tiered data source:
  Tier 0: Live Allium queries (if ALLIUM_API_KEY is set — ~90s per wallet)
  Tier 1: Cached real wallet data (from demo_wallets.json — instant)
  Tier 2: Deterministic synthetic features from address hash (instant)

The model runs on every request regardless of data source. The score is
pushed to the CreditOracle on BSC testnet. The response includes a
`data_source` field: "live", "cached", or "synthetic".

Usage:
    uvicorn pipeline.api:app --host 0.0.0.0 --port 8000 --reload
"""

import sys
import time
import json
import hashlib
import traceback
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests as http_requests
from fastapi import FastAPI, HTTPException, Request
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

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ──────────────────────────────────────────────────────────────────────────────
# Rate Limiting (in-memory, hackathon-grade)
# ──────────────────────────────────────────────────────────────────────────────

_rate_limit_per_ip: dict[str, list[float]] = defaultdict(list)
_rate_limit_global: list[float] = []
RATE_LIMIT_PER_IP_HOUR = 20
RATE_LIMIT_GLOBAL_DAY = 100


def _check_rate_limit(client_ip: str):
    """Raise HTTP 429 if rate limits are exceeded."""
    now = time.time()
    hour_ago = now - 3600
    day_ago = now - 86400

    # Clean up old entries
    _rate_limit_per_ip[client_ip] = [t for t in _rate_limit_per_ip[client_ip] if t > hour_ago]
    _rate_limit_global[:] = [t for t in _rate_limit_global if t > day_ago]

    if len(_rate_limit_per_ip[client_ip]) >= RATE_LIMIT_PER_IP_HOUR:
        raise HTTPException(429, "Scoring rate limit reached. Please try again in a few minutes.")
    if len(_rate_limit_global) >= RATE_LIMIT_GLOBAL_DAY:
        raise HTTPException(429, "Scoring rate limit reached. Please try again in a few minutes.")

    _rate_limit_per_ip[client_ip].append(now)
    _rate_limit_global.append(now)


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
    data_source: str = "live"  # "live", "cached", or "synthetic"
    factor_breakdown: list[FactorItem]
    composite_score: int | None = None
    collateral_ratio_bps: int | None = None
    tx_hash: str | None = None
    error: str | None = None


# ──────────────────────────────────────────────────────────────────────────────
# Demo fallback: cached wallets + synthetic features
# ──────────────────────────────────────────────────────────────────────────────

_demo_wallets_cache: dict | None = None


def _load_demo_wallets() -> dict:
    """Load cached real wallet features from demo_wallets.json (loaded once)."""
    global _demo_wallets_cache
    if _demo_wallets_cache is not None:
        return _demo_wallets_cache

    demo_path = Path(__file__).parent / "demo_wallets.json"
    if demo_path.exists():
        with open(demo_path) as f:
            _demo_wallets_cache = json.load(f)
    else:
        _demo_wallets_cache = {}
    return _demo_wallets_cache


def _generate_synthetic_features(address: str) -> dict:
    """
    Generate deterministic pseudo-random features from a wallet address.
    Same address always produces the same features (SHA-256 hash-based).
    """
    h = hashlib.sha256(address.lower().encode()).digest()
    return {
        "lending_active_days": (h[0] % 30) + 1,
        "borrow_repay_ratio": round(0.5 + (h[1] % 150) / 100, 2),
        "repay_count": h[2] % 20,
        "unique_borrow_tokens": (h[3] % 3) + 1,
        "current_total_usd": float(h[4] * h[5]),
        "stablecoin_ratio": round((h[6] % 100) / 100, 2),
        "net_flow_usd_90d": float((h[7] - 128) * 100),
        "crosschain_total_tx_count": h[8] * h[9],
        "crosschain_dex_trade_count": h[10] * 2,
        "chains_active_on": h[11] % 5,
        "has_used_bridge": 1 if h[12] > 128 else 0,
    }


def _try_fallback(address: str) -> tuple[dict, str, int, str]:
    """
    Tier 1: Check demo_wallets.json for cached real features.
    Tier 2: Generate deterministic synthetic features from address hash.
    """
    cached = _load_demo_wallets()
    addr_lower = address.lower()

    if addr_lower in cached:
        entry = cached[addr_lower]
        return (
            entry["features"],
            entry.get("data_completeness", "5-chain history (cached)"),
            entry.get("chains_used", 5),
            "cached",
        )

    features = _generate_synthetic_features(address)
    chains = 1 + features["chains_active_on"]
    return features, "synthetic profile", chains, "synthetic"


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
    """
    if start_delay > 0:
        time.sleep(start_delay)

    try:
        for attempt in range(3):
            resp = http_requests.post(
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

        for attempt in range(3):
            resp = http_requests.post(
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

        start = time.time()
        while time.time() - start < ALLIUM_POLL_TIMEOUT:
            resp = http_requests.get(
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
    """Run Query A (BSC) and Query B (crosschain) concurrently."""
    sql_a = build_query_a(address)
    sql_b = build_query_b(address)

    results = {"a": None, "b": None}

    with ThreadPoolExecutor(max_workers=2) as pool:
        future_a = pool.submit(_run_allium_query, sql_a, "bsc", 0)
        future_b = pool.submit(_run_allium_query, sql_b, "crosschain", 3)

        for future in as_completed([future_a, future_b]):
            if future == future_a:
                results["a"] = future.result()
            else:
                results["b"] = future.result()

    if results["a"] is None:
        raise RuntimeError("BSC data query failed. Falling back to demo mode.")

    a = results["a"]
    b = results["b"]

    raw = {
        "lending_active_days": int(a.get("lending_active_days", 0) or 0),
        "borrow_repay_ratio": float(a.get("borrow_repay_ratio", 0) or 0),
        "repay_count": int(a.get("repay_count", 0) or 0),
        "unique_borrow_tokens": max(int(a.get("unique_borrow_tokens", 0) or 0), 1),
        "current_total_usd": float(a.get("current_total_usd", 0) or 0),
        "stablecoin_ratio": float(a.get("stablecoin_ratio", 0) or 0),
        "net_flow_usd_90d": float(a.get("net_flow_usd_90d", 0) or 0),
    }

    if b is not None:
        raw["crosschain_total_tx_count"] = int(b.get("crosschain_total_tx_count", 0) or 0)
        raw["crosschain_dex_trade_count"] = int(b.get("crosschain_dex_trade_count", 0) or 0)
        raw["chains_active_on"] = int(b.get("chains_active_on", 0) or 0)
        raw["has_used_bridge"] = int(b.get("has_used_bridge", 0) or 0)
        chains_used = 1 + raw["chains_active_on"]
        completeness = f"{chains_used}-chain history"
    else:
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
async def score_endpoint(req: ScoreRequest, request: Request):
    """
    Score a wallet: query data → run model → push to CreditOracle → return.
    Data source is tiered: live Allium → cached → synthetic.
    """
    address = req.address.strip()
    if not address.startswith("0x") or len(address) != 42:
        raise HTTPException(400, "Invalid address format (expected 0x + 40 hex chars)")

    # Rate limiting
    client_ip = request.client.host if request.client else "unknown"
    _check_rate_limit(client_ip)

    print(f"\n{'='*60}")
    print(f"Scoring wallet: {address}")
    print(f"{'='*60}")

    # Step 1: Get features (tiered: live → cached → synthetic)
    t0 = time.time()
    data_source = "live"

    if ALLIUM_API_KEY:
        # Tier 0: Try live Allium queries
        try:
            raw_features, completeness, chains_used = _query_wallet_features(address)
            data_source = "live"
        except RuntimeError:
            # Allium failed — fall through to demo mode
            print("  [1/3] Allium query failed, falling back to demo mode")
            raw_features, completeness, chains_used, data_source = _try_fallback(address)
    else:
        # No API key — go straight to demo fallback
        print("  [1/3] No Allium API key, using demo mode")
        raw_features, completeness, chains_used, data_source = _try_fallback(address)

    t_query = time.time() - t0
    print(f"  [1/3] Features ready in {t_query:.1f}s (source: {data_source})")
    print(f"        Data completeness: {completeness}")

    # Step 2: Run the frozen model (always real, regardless of data source)
    t1 = time.time()
    try:
        result = score_wallet(raw_features)
    except Exception as e:
        raise HTTPException(500, f"Model inference failed: {e}")
    credit_score = result["credit_score"]
    t_model = time.time() - t1
    print(f"  [2/3] Model inference in {t_model*1000:.0f}ms → score {credit_score}")

    # Step 3: Push score to CreditOracle (always real contract interaction)
    tx_hash = None
    composite = None
    collateral_bps = None
    push_error = None

    t2 = time.time()
    try:
        tx_hash = push_onchain_score(address, credit_score, chains_used)
        print(f"  [3/3] Pushed to CreditOracle: tx {tx_hash}")

        profile = read_composite_score(address)
        composite = profile["composite_score"]

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
    print(f"  Total time: {t_total:.1f}s (data={t_query:.1f}s, model={t_model*1000:.0f}ms, push={t_push:.1f}s)")

    # Build response — no Allium details, SQL, or API keys exposed
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
        data_source=data_source,
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
