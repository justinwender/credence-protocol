// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OffchainAttestationRegistry
 * @notice Stores offchain credit attestations (FICO-equivalent) for wallets,
 *         with a persistent identity layer that prevents Sybil attacks via
 *         wallet rebinding.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * PRODUCTION MECHANISM
 * ────────────────────────────────────────────────────────────────────────────
 * In production, attestations are submitted by a ZK verifier contract that
 * validates Brevis/Primus proofs from the ZKredit pipeline. The verifier
 * derives the `identityHash` deterministically from the proof: the same
 * offchain account (e.g., a user's Experian/Equifax record) always produces
 * the same `identityHash`, regardless of which wallet submits the proof.
 *
 * DEMO MECHANISM
 * ────────────────────────────────────────────────────────────────────────────
 * For the hackathon, the admin sets attestations directly via `setAttestation`.
 * The admin picks `identityHash` values to simulate the production behavior.
 *
 * SYBIL RESISTANCE
 * ────────────────────────────────────────────────────────────────────────────
 * When a wallet rebinds an existing `identityHash` to a new wallet, the new
 * wallet inherits the old wallet's historical onchain score. A user who is
 * liquidated on wallet A and rebinds their attestation to wallet B does not
 * get a fresh start: B's composite credit score is computed with A's old
 * onchain score, because the offchain identity carries the onchain history
 * forward.
 *
 * The CreditOracle keeps historical scores in sync by calling
 * `updateHistoricalScore` whenever a new onchain score is pushed for any
 * wallet that has an attestation.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * PRODUCTION CONSIDERATIONS (not implemented in this demo)
 * ────────────────────────────────────────────────────────────────────────────
 * - Active loans on the old wallet during rebinding: force-repay, freeze, or
 *   transfer debt. Not handled here.
 * - Rebinding cooldowns: enforced at the ZK proof layer in production.
 * - Privacy of `identityHash`: in production, use commit-reveal or Poseidon
 *   hashes to prevent correlation across ecosystems.
 */
contract OffchainAttestationRegistry is Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────

    struct OffchainAttestation {
        bytes32 identityHash;         // Persistent identity across wallets (see comment block above)
        uint8   paymentHistoryScore;  // 0-100
        uint8   creditUtilizationPct; // 0-100 (lower is better)
        uint16  creditHistoryMonths;  // Length of credit history
        uint8   numberOfAccounts;     // Number of credit accounts
        uint8   hardInquiries;        // Recent hard pulls (lower is better)
        uint16  compositeScore;       // 300-850 (FICO-equivalent)
        bool    isVerified;           // In production: set by ZK verifier; in demo: admin-set
        uint256 timestamp;            // When attestation was submitted
    }

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    /// @dev wallet → most recent attestation
    mapping(address => OffchainAttestation) private _attestations;

    /// @dev wallet → whether an attestation is currently active
    mapping(address => bool) private _hasAttestation;

    /// @dev identityHash → most recent onchain score, persistent across wallet rebindings
    mapping(bytes32 => uint8) private _historicalOnchainScores;

    /// @dev identityHash → wallet that currently holds this identity
    mapping(bytes32 => address) private _identityToCurrentWallet;

    /// @dev wallet → identityHash currently bound to it (0x0 if no attestation)
    mapping(address => bytes32) private _walletToIdentity;

    /// @dev CreditOracle contract authorized to call updateHistoricalScore.
    ///      Set once via `setCreditOracle`, then immutable (one-shot).
    address public creditOracle;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event AttestationSet(address indexed wallet, bytes32 indexed identityHash, uint16 ficoScore);
    event AttestationCleared(address indexed wallet, bytes32 indexed identityHash);
    event AttestationTransferred(
        address indexed oldWallet,
        address indexed newWallet,
        bytes32 indexed identityHash,
        uint8 inheritedOnchainScore
    );
    event HistoricalScoreUpdated(bytes32 indexed identityHash, uint8 newScore);
    event CreditOracleSet(address indexed oracle);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────────────────────
    // Admin: one-shot CreditOracle linkage
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Authorizes the CreditOracle to call `updateHistoricalScore`.
     *         Can only be set once (from address(0)), then immutable.
     * @param  oracle  Address of the deployed CreditOracle contract.
     */
    function setCreditOracle(address oracle) external onlyOwner {
        require(creditOracle == address(0), "Oracle already set");
        require(oracle != address(0), "Zero address");
        creditOracle = oracle;
        emit CreditOracleSet(oracle);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin: attestation lifecycle
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Set (or rebind) an offchain credit attestation for a wallet.
     *
     * Behavior:
     *   - If `attestation.identityHash` is new (never seen before):
     *       • First-time attestation. No historical score to inherit.
     *   - If `identityHash` is currently bound to a DIFFERENT wallet:
     *       • Rebinding. The old wallet's attestation is cleared. The
     *         historical onchain score `_historicalOnchainScores[identityHash]`
     *         is preserved and will be used by the Oracle when computing the
     *         new wallet's composite score (until the new wallet accumulates
     *         its own score on Venus).
     *       • Emits `AttestationTransferred(oldWallet, newWallet, identityHash,
     *         inheritedScore)`.
     *   - If `identityHash` is already bound to `wallet`:
     *       • Simple attestation refresh (no rebinding logic triggered).
     *
     * @param wallet       Target wallet receiving the attestation.
     * @param attestation  Full attestation struct including identityHash.
     */
    function setAttestation(
        address wallet,
        OffchainAttestation calldata attestation
    ) external onlyOwner {
        require(wallet != address(0), "Zero wallet");
        require(attestation.identityHash != bytes32(0), "Zero identityHash");

        bytes32 id = attestation.identityHash;
        address currentHolder = _identityToCurrentWallet[id];

        // Rebinding case: identity was bound to a different wallet
        if (currentHolder != address(0) && currentHolder != wallet) {
            uint8 inheritedScore = _historicalOnchainScores[id];

            // Clear old wallet's attestation state
            delete _attestations[currentHolder];
            _hasAttestation[currentHolder] = false;
            delete _walletToIdentity[currentHolder];

            emit AttestationTransferred(currentHolder, wallet, id, inheritedScore);
        }

        // If `wallet` previously held a DIFFERENT identity, clean up that
        // mapping so the identity isn't pointing at this wallet any longer.
        bytes32 previousId = _walletToIdentity[wallet];
        if (previousId != bytes32(0) && previousId != id) {
            if (_identityToCurrentWallet[previousId] == wallet) {
                delete _identityToCurrentWallet[previousId];
            }
        }

        // Set / refresh the new (or existing) wallet-identity binding
        _attestations[wallet] = OffchainAttestation({
            identityHash:         id,
            paymentHistoryScore:  attestation.paymentHistoryScore,
            creditUtilizationPct: attestation.creditUtilizationPct,
            creditHistoryMonths:  attestation.creditHistoryMonths,
            numberOfAccounts:     attestation.numberOfAccounts,
            hardInquiries:        attestation.hardInquiries,
            compositeScore:       attestation.compositeScore,
            isVerified:           attestation.isVerified,
            timestamp:            block.timestamp
        });
        _hasAttestation[wallet] = true;
        _identityToCurrentWallet[id] = wallet;
        _walletToIdentity[wallet] = id;

        emit AttestationSet(wallet, id, attestation.compositeScore);
    }

    /**
     * @notice Clear the attestation for a specific wallet (demo/debug only).
     *         The historical onchain score for the identity is PRESERVED
     *         so that if the identity is later re-attested to any wallet,
     *         the history is not lost.
     */
    function clearAttestation(address wallet) external onlyOwner {
        require(_hasAttestation[wallet], "No attestation");
        bytes32 id = _walletToIdentity[wallet];

        delete _attestations[wallet];
        _hasAttestation[wallet] = false;
        delete _walletToIdentity[wallet];

        if (id != bytes32(0) && _identityToCurrentWallet[id] == wallet) {
            delete _identityToCurrentWallet[id];
        }

        emit AttestationCleared(wallet, id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Oracle-only: historical score updates
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the persistent onchain score for an offchain identity.
     *         Called by the CreditOracle whenever a new onchain score is
     *         pushed for a wallet that currently holds an attestation.
     * @param identityHash  The identity to update.
     * @param score         New onchain score (0-100).
     */
    function updateHistoricalScore(bytes32 identityHash, uint8 score) external {
        require(msg.sender == creditOracle, "Only oracle");
        require(identityHash != bytes32(0), "Zero identityHash");
        require(score <= 100, "Score > 100");
        _historicalOnchainScores[identityHash] = score;
        emit HistoricalScoreUpdated(identityHash, score);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View: public queries
    // ─────────────────────────────────────────────────────────────────────

    function getAttestation(address wallet) external view returns (OffchainAttestation memory) {
        return _attestations[wallet];
    }

    function hasAttestation(address wallet) external view returns (bool) {
        return _hasAttestation[wallet];
    }

    function getHistoricalScore(bytes32 identityHash) external view returns (uint8) {
        return _historicalOnchainScores[identityHash];
    }

    function getIdentityForWallet(address wallet) external view returns (bytes32) {
        return _walletToIdentity[wallet];
    }

    function getWalletForIdentity(bytes32 identityHash) external view returns (address) {
        return _identityToCurrentWallet[identityHash];
    }
}
