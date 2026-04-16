// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OffchainAttestationRegistry} from "./OffchainAttestationRegistry.sol";

/**
 * @title CreditOracle
 * @notice Stores onchain credit scores pushed by the offchain scoring pipeline,
 *         reads offchain attestations from the registry, and exposes a
 *         composite score that drives collateral requirements in the
 *         LendingPool.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * COMPOSITE SCORE MATH (asymmetric: offchain baseline + onchain boost)
 * ────────────────────────────────────────────────────────────────────────────
 * The composite expresses a specific value proposition — see below — and uses
 * different logic depending on whether the wallet has an offchain attestation.
 *
 * Without attestation (onchain-only)
 *   composite = (onchainScore * onchainOnlyMultiplier) / 100
 *
 *   With the default multiplier of 50, the MAX composite in this branch is
 *   50, which maps to roughly 120% collateral in the LendingPool curve.
 *   Onchain alone CANNOT unlock undercollateralized terms. This enforces the
 *   thin-file protection: a high onchain score achieved via minimal activity
 *   (1 borrow, 1 repay, move on) produces a high raw score because liquidation
 *   risk is low, but that's not equivalent to proven creditworthiness. We
 *   require the offchain attestation to differentiate "safe because
 *   inexperienced" from "safe because genuinely creditworthy."
 *
 * With attestation (both signals present)
 *   baseline  = (offchainScore * offchainBaselineMultiplier) / 100
 *   boost     = (onchainScore  * onchainBoostMultiplier)      / 100
 *   composite = min(100, baseline + boost)
 *
 *   With defaults (offchainBaseline=70, onchainBoost=40):
 *     - FICO 780 alone (offchain=87, onchain=0):  composite=60  → ~110% collateral
 *       "Competitive with a traditional bank, maybe slightly worse."
 *     - FICO 780 + strong onchain (onchain=98):   composite=99  → ~76%  collateral
 *       "Better than a bank can offer — genuinely undercollateralized."
 *     - Weak onchain + FICO 780 (onchain=20):     composite=68  → ~102% collateral
 *       "FICO floor, bad onchain drags back to parity."
 *
 * VALUE PROPOSITION
 *   - Onchain-only:    better-than-standard-DeFi terms (~120% max), but still
 *                      overcollateralized.
 *   - Offchain-only:   competitive with a traditional lender (~110% at FICO 780).
 *   - Both strong:     undercollateralized (75-90%), beyond what banks offer.
 *   - Bringing offchain credit onchain via ZK proofs unlocks undercollateralized
 *     lending, which is unsolved in DeFi today. Two verified signals compound;
 *     onchain alone is insufficient because a thin onchain file is not
 *     equivalent to proven creditworthiness.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * PERSISTENT CREDIT IDENTITY (Sybil resistance)
 * ────────────────────────────────────────────────────────────────────────────
 * If a wallet has an attestation but no onchain score of its own, the Oracle
 * queries the registry for the historical onchain score tied to that identity
 * hash. This means a user who was liquidated on wallet A (low onchain score),
 * then rebinds their attestation to wallet B (no onchain history), gets B's
 * composite calculated using A's old score — NOT a fresh start.
 *
 * The Oracle also keeps the registry's historical score in sync: whenever
 * setOnchainScore is called for a wallet that has an attestation, the Oracle
 * writes that score into the registry's historical record.
 */
contract CreditOracle is Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────

    struct CreditProfile {
        uint8  onchainScore;            // 0-100, pushed by Python pipeline
        uint8  historicalOnchainScore;  // 0-100, from registry (for display: inherited from identity if own score is 0)
        uint8  offchainScore;           // 0-100, derived from attestation FICO
        uint8  compositeScore;          // 0-100, computed on read
        uint8  chainsUsed;               // 1-5; surfaced in UI as "based on N-chain history"
        bool   hasOffchainAttestation;
        bool   isUsingInheritedScore;   // true iff composite was computed from historical score
        uint256 lastUpdated;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    OffchainAttestationRegistry public immutable registry;

    /// @dev wallet → onchain score (0-100) pushed by the pipeline
    mapping(address => uint8) private _onchainScores;
    mapping(address => uint8) private _chainsUsed;
    mapping(address => uint256) private _lastUpdated;

    // Composite score tuning params. All admin-adjustable.
    uint8 public onchainOnlyMultiplier       = 50;  // thin-file cap
    uint8 public offchainBaselineMultiplier  = 70;  // FICO → baseline (when attestation present)
    uint8 public onchainBoostMultiplier      = 40;  // onchain → boost above baseline

    // FICO mapping: linear from 300-850 → 0-100 for the hackathon.
    // See CLAUDE.md Phase 7 note for production improvement.
    uint16 public constant FICO_MIN = 300;
    uint16 public constant FICO_MAX = 850;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event OnchainScoreSet(address indexed wallet, uint8 score, uint8 chainsUsed);
    event MultipliersUpdated(
        uint8 onchainOnlyMultiplier,
        uint8 offchainBaselineMultiplier,
        uint8 onchainBoostMultiplier
    );

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner, OffchainAttestationRegistry _registry) Ownable(initialOwner) {
        require(address(_registry) != address(0), "Zero registry");
        registry = _registry;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin: push onchain score (from Python scoring pipeline)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Called by the offchain scoring pipeline to push a wallet's
     *         current onchain credit score (0-100).
     *
     *         If the wallet has an attestation, this function also updates the
     *         registry's historical score for that identity, ensuring the
     *         Sybil protection stays in sync: if the user later rebinds the
     *         attestation to a new wallet, the new wallet inherits THIS score.
     *
     * @param wallet       Target wallet.
     * @param score        Onchain credit score (0-100).
     * @param chainsUsed   Count of chains that contributed data (1-5).
     */
    function setOnchainScore(address wallet, uint8 score, uint8 chainsUsed) external onlyOwner {
        require(wallet != address(0), "Zero wallet");
        require(score <= 100, "Score > 100");
        require(chainsUsed >= 1 && chainsUsed <= 5, "chainsUsed out of range");

        _onchainScores[wallet] = score;
        _chainsUsed[wallet] = chainsUsed;
        _lastUpdated[wallet] = block.timestamp;

        // Sync the persistent identity record if this wallet has an attestation
        if (registry.hasAttestation(wallet)) {
            bytes32 id = registry.getIdentityForWallet(wallet);
            if (id != bytes32(0)) {
                registry.updateHistoricalScore(id, score);
            }
        }

        emit OnchainScoreSet(wallet, score, chainsUsed);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin: parameter tuning (configurable multipliers)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update all three composite-score multipliers.
     *         `onchainOnlyMultiplier`        — cap for onchain-only path (default 50)
     *         `offchainBaselineMultiplier`   — FICO baseline when both present (default 70)
     *         `onchainBoostMultiplier`       — onchain boost when both present (default 40)
     *
     *         Individually each is 0-100. Their sum (for the both-present path)
     *         may exceed 100 — the composite is clamped to 100 on read.
     */
    function setMultipliers(
        uint8 _onchainOnlyMultiplier,
        uint8 _offchainBaselineMultiplier,
        uint8 _onchainBoostMultiplier
    ) external onlyOwner {
        require(_onchainOnlyMultiplier <= 100, "onchainOnly > 100");
        require(_offchainBaselineMultiplier <= 100, "offchainBaseline > 100");
        require(_onchainBoostMultiplier <= 100, "onchainBoost > 100");
        onchainOnlyMultiplier = _onchainOnlyMultiplier;
        offchainBaselineMultiplier = _offchainBaselineMultiplier;
        onchainBoostMultiplier = _onchainBoostMultiplier;
        emit MultipliersUpdated(
            _onchainOnlyMultiplier,
            _offchainBaselineMultiplier,
            _onchainBoostMultiplier
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core read API
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Compute the composite credit score (0-100) for a wallet.
     *         This is the single number the LendingPool consumes to determine
     *         required collateral.
     * @dev See the top-of-file comment block for the math and rationale.
     */
    function getCompositeScore(address wallet) public view returns (uint8) {
        (uint8 onchainForCalc, , bool hasAttest, ) = _effectiveOnchainScore(wallet);

        if (!hasAttest) {
            // Onchain-only path: thin-file cap enforced
            return uint8((uint256(onchainForCalc) * onchainOnlyMultiplier) / 100);
        }

        // Both signals present: asymmetric baseline + boost
        OffchainAttestationRegistry.OffchainAttestation memory att = registry.getAttestation(wallet);
        uint8 offchainScore = mapFicoToZero100(att.compositeScore);

        uint256 baseline = (uint256(offchainScore) * offchainBaselineMultiplier) / 100;
        uint256 boost    = (uint256(onchainForCalc) * onchainBoostMultiplier)     / 100;
        uint256 total    = baseline + boost;
        return total > 100 ? 100 : uint8(total);
    }

    /**
     * @notice Returns the full credit profile for a wallet, including the
     *         inheritance flag so the UI can display "based on inherited
     *         credit history" when applicable.
     */
    function getFullProfile(address wallet) external view returns (CreditProfile memory p) {
        (uint8 onchainForCalc, uint8 ownScore, bool hasAttest, bool usingInherited) =
            _effectiveOnchainScore(wallet);

        uint8 offchainScore = 0;
        if (hasAttest) {
            OffchainAttestationRegistry.OffchainAttestation memory att = registry.getAttestation(wallet);
            offchainScore = mapFicoToZero100(att.compositeScore);
        }

        p = CreditProfile({
            onchainScore:           ownScore,
            historicalOnchainScore: onchainForCalc,
            offchainScore:          offchainScore,
            compositeScore:         getCompositeScore(wallet),
            chainsUsed:             _chainsUsed[wallet],
            hasOffchainAttestation: hasAttest,
            isUsingInheritedScore:  usingInherited,
            lastUpdated:            _lastUpdated[wallet]
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Determines the onchain score to feed into composite calculation.
     *
     *      Precedence:
     *        1. Wallet's own `_onchainScores[wallet]` if set (>0)
     *        2. Historical score from registry (if wallet has attestation
     *           and an identity is bound, and own score is 0)
     *        3. 0 (no signal)
     *
     * @return onchainForCalc  Score to use in composite math
     * @return ownScore        Wallet's own score (before inheritance fallback)
     * @return hasAttest       Whether the wallet has an active attestation
     * @return usingInherited  Whether `onchainForCalc` came from inheritance
     */
    function _effectiveOnchainScore(address wallet)
        internal
        view
        returns (uint8 onchainForCalc, uint8 ownScore, bool hasAttest, bool usingInherited)
    {
        ownScore = _onchainScores[wallet];
        hasAttest = registry.hasAttestation(wallet);
        onchainForCalc = ownScore;
        usingInherited = false;

        if (hasAttest && ownScore == 0) {
            bytes32 id = registry.getIdentityForWallet(wallet);
            if (id != bytes32(0)) {
                uint8 historical = registry.getHistoricalScore(id);
                if (historical > 0) {
                    onchainForCalc = historical;
                    usingInherited = true;
                }
            }
        }
    }

    /**
     * @notice Linear FICO (300-850) → 0-100 mapping.
     *         Production note (see CLAUDE.md Phase 7): this linear mapping has
     *         ~35% of its domain in FICO 300-500 where DeFi borrowers are rare.
     *         A production deployment should use a nonlinear mapping that
     *         concentrates resolution in FICO 600-800.
     */
    function mapFicoToZero100(uint16 fico) public pure returns (uint8) {
        if (fico <= FICO_MIN) return 0;
        if (fico >= FICO_MAX) return 100;
        // (fico - 300) * 100 / (850 - 300) = (fico - 300) * 100 / 550
        uint256 scaled = (uint256(fico - FICO_MIN) * 100) / (FICO_MAX - FICO_MIN);
        return uint8(scaled);
    }
}
