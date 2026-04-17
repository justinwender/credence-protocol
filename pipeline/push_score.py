"""
Credence Protocol — Push Score to CreditOracle
===============================================
Pushes an onchain credit score to the deployed CreditOracle contract
on BSC testnet via web3.py.

Usage (standalone):
    python3 pipeline/push_score.py 0xWALLET_ADDRESS 75 3

Usage (programmatic):
    from pipeline.push_score import push_onchain_score
    tx_hash = push_onchain_score("0x...", score=75, chains_used=3)
"""

import sys
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

# Add project root to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from pipeline.config import (
    BSC_TESTNET_RPC,
    BSC_TESTNET_PRIVATE_KEY,
    BSC_TESTNET_CHAIN_ID,
    CREDIT_ORACLE_ADDRESS,
    get_oracle_abi,
)


def get_web3() -> Web3:
    """Create a Web3 instance connected to BSC testnet with PoA middleware."""
    w3 = Web3(Web3.HTTPProvider(BSC_TESTNET_RPC))
    # BSC (and other PoA chains) need this middleware to handle
    # extraData fields longer than 32 bytes in block headers.
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    if not w3.is_connected():
        raise ConnectionError(f"Cannot connect to BSC testnet at {BSC_TESTNET_RPC}")
    return w3


def push_onchain_score(
    wallet_address: str,
    score: int,
    chains_used: int,
    *,
    dry_run: bool = False,
) -> str | None:
    """
    Push an onchain credit score to the CreditOracle contract.

    Args:
        wallet_address: The wallet being scored (0x hex string)
        score: Credit score 0-100
        chains_used: Number of chains that contributed data (1-5)
        dry_run: If True, simulate without broadcasting

    Returns:
        Transaction hash (hex string) if broadcast, None if dry_run.
    """
    if not CREDIT_ORACLE_ADDRESS:
        raise ValueError("CREDIT_ORACLE_ADDRESS not set in .env")
    if not BSC_TESTNET_PRIVATE_KEY:
        raise ValueError("BSC_TESTNET_PRIVATE_KEY not set in .env")

    w3 = get_web3()
    oracle = w3.eth.contract(
        address=Web3.to_checksum_address(CREDIT_ORACLE_ADDRESS),
        abi=get_oracle_abi(),
    )
    account = w3.eth.account.from_key(BSC_TESTNET_PRIVATE_KEY)

    # Build the transaction
    tx = oracle.functions.setOnchainScore(
        Web3.to_checksum_address(wallet_address),
        score,
        chains_used,
    ).build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 200_000,
        "gasPrice": w3.to_wei(5, "gwei"),
        "chainId": BSC_TESTNET_CHAIN_ID,
    })

    if dry_run:
        print(f"[DRY RUN] setOnchainScore({wallet_address}, {score}, {chains_used})")
        print(f"  From: {account.address}")
        print(f"  Oracle: {CREDIT_ORACLE_ADDRESS}")
        return None

    # Sign and send
    signed = w3.eth.account.sign_transaction(tx, BSC_TESTNET_PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

    if receipt["status"] != 1:
        raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")

    return tx_hash.hex()


def read_composite_score(wallet_address: str) -> dict:
    """Read the composite score and full profile from the CreditOracle."""
    w3 = get_web3()
    oracle = w3.eth.contract(
        address=Web3.to_checksum_address(CREDIT_ORACLE_ADDRESS),
        abi=get_oracle_abi(),
    )
    composite = oracle.functions.getCompositeScore(
        Web3.to_checksum_address(wallet_address)
    ).call()

    profile = oracle.functions.getFullProfile(
        Web3.to_checksum_address(wallet_address)
    ).call()

    # profile is a tuple matching CreditProfile struct:
    # (onchainScore, historicalOnchainScore, offchainScore, compositeScore,
    #  chainsUsed, hasOffchainAttestation, isUsingInheritedScore, lastUpdated)
    return {
        "composite_score": composite,
        "onchain_score": profile[0],
        "historical_onchain_score": profile[1],
        "offchain_score": profile[2],
        "chains_used": profile[4],
        "has_offchain_attestation": profile[5],
        "is_using_inherited_score": profile[6],
        "last_updated": profile[7],
    }


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python3 pipeline/push_score.py <wallet> <score> <chains_used>")
        sys.exit(1)

    wallet = sys.argv[1]
    score = int(sys.argv[2])
    chains = int(sys.argv[3])

    print(f"Pushing score {score} (chains={chains}) for {wallet}...")
    tx = push_onchain_score(wallet, score, chains)
    print(f"Transaction: {tx}")
    print(f"BscScan: https://testnet.bscscan.com/tx/{tx}")

    profile = read_composite_score(wallet)
    print(f"On-chain composite: {profile['composite_score']}")
