// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CredenceTestBase} from "./TestHelpers.sol";

/**
 * @title Integration tests for the full Credence Protocol demo flow.
 *
 * Exercises the end-to-end narrative a judge will see during the pitch:
 *   1. Onchain-only (capped at overcollateralized)
 *   2. Add offchain attestation (unlocks undercollateralized)
 *   3. Full composite (both signals = best terms)
 *   4. Sybil resistance: rebinding preserves onchain history
 */
contract IntegrationTest is CredenceTestBase {
    bytes32 constant IDENTITY_ALICE = keccak256("alice-offchain-identity");

    function setUp() public {
        _deployAll();
        vm.deal(lp, 100 ether);
        vm.deal(alice, 50 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);

        // Seed pool with ample liquidity
        vm.prank(lp);
        pool.deposit{value: 50 ether}();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Demo beat 1-3: onchain-only → + attestation → full composite
    // ─────────────────────────────────────────────────────────────────────

    function test_DemoFlow_FullCompositeUnlocksUndercollateralized() public {
        // Beat 1: Alice has a strong onchain-only score (98) — thin-file cap
        vm.prank(admin);
        oracle.setOnchainScore(alice, 98, 5);

        assertEq(oracle.getCompositeScore(alice), 49);
        uint16 ratioBeforeAttest = pool.getBorrowerCollateralRatioBps(alice);
        assertTrue(ratioBeforeAttest >= 10000, "Onchain-only must stay overcollateralized");
        // Composite 49 → interpolated curve: 20→50 segment, 150→120. At 49: ~120.67% ≈ 12100bps
        assertApproxEqAbs(uint256(ratioBeforeAttest), 12100, 100);

        // Alice borrows 1 BNB at the overcollateralized rate
        uint256 requiredOnchainOnly = pool.getRequiredCollateral(alice, 1 ether);
        assertTrue(requiredOnchainOnly > 1 ether);

        vm.prank(alice);
        pool.borrow{value: requiredOnchainOnly}(1 ether);
        assertEq(pool.borrowedAmounts(alice), 1 ether);

        // Alice repays to clear the slate
        vm.prank(alice);
        pool.repay{value: 1 ether}();
        assertEq(pool.borrowedAmounts(alice), 0);

        // Beat 2: Admin submits a strong FICO attestation (780) for Alice
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(IDENTITY_ALICE, 780));

        // Composite jumps from 49 to 99 (baseline 60 + boost 39)
        assertEq(oracle.getCompositeScore(alice), 99);
        uint16 ratioWithAttest = pool.getBorrowerCollateralRatioBps(alice);
        assertTrue(ratioWithAttest < 10000, "Full composite must unlock undercollateralized");
        // Composite 99 → 85→100 segment, 8500→7500. At 99: 7567 bps
        assertLe(uint256(ratioWithAttest), 8000);

        // Beat 3: Alice borrows again, this time at the undercollateralized rate
        uint256 requiredFull = pool.getRequiredCollateral(alice, 1 ether);
        assertTrue(requiredFull < 1 ether, "Collateral must be less than borrow");
        assertTrue(requiredFull < requiredOnchainOnly, "Full composite must beat onchain-only");

        vm.prank(alice);
        pool.borrow{value: requiredFull}(1 ether);
        assertEq(pool.borrowedAmounts(alice), 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Demo beat 4: Sybil resistance via identity rebinding
    // ─────────────────────────────────────────────────────────────────────

    function test_DemoFlow_SybilResistance_NewWalletInheritsBadHistory() public {
        // Order matters: attestation first, then score-push syncs historical.
        // 1. Alice attests with strong FICO
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(IDENTITY_ALICE, 780));
        // 2. Pipeline pushes her (bad) onchain score — syncs to registry historical
        vm.prank(admin);
        oracle.setOnchainScore(alice, 15, 3);

        // Composite = baseline 60 + boost 6 = 66
        assertEq(oracle.getCompositeScore(alice), 66);
        // Historical was synced by setOnchainScore because attestation was already present
        assertEq(registry.getHistoricalScore(IDENTITY_ALICE), 15);

        // 2. Sybil attempt: user creates fresh wallet Bob and rebinds identity
        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(IDENTITY_ALICE, 780));

        // Alice's attestation is cleared
        assertFalse(registry.hasAttestation(alice));

        // Bob's composite should use the INHERITED historical score (15), NOT a fresh 0
        assertEq(oracle.getCompositeScore(bob), 66); // exact same as Alice had

        CreditOracle.CreditProfile memory pBob = oracle.getFullProfile(bob);
        assertEq(pBob.onchainScore, 0);
        assertEq(pBob.historicalOnchainScore, 15);
        assertTrue(pBob.isUsingInheritedScore);
        assertTrue(pBob.hasOffchainAttestation);

        // Bob tries to borrow — gets the same unfavorable rate Alice would have
        uint16 bobRatio = pool.getBorrowerCollateralRatioBps(bob);
        assertTrue(bobRatio >= 10000, "Sybil must NOT unlock undercollateralized");
    }

    function test_DemoFlow_PostRebind_PipelineScoreUpdatesIdentityInPlace() public {
        // Seed: Alice attests, pipeline pushes bad onchain score → historical synced to 15
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(IDENTITY_ALICE, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 15, 3);

        // Rebind to Bob
        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(IDENTITY_ALICE, 780));

        // Pipeline later scores Bob (maybe Bob builds up new activity)
        vm.prank(admin);
        oracle.setOnchainScore(bob, 80, 3);

        // Bob's own score overrides historical
        assertFalse(oracle.getFullProfile(bob).isUsingInheritedScore);
        // composite = 60 + 80*0.4 = 92
        assertEq(oracle.getCompositeScore(bob), 92);
        // Historical updated to Bob's new score
        assertEq(registry.getHistoricalScore(IDENTITY_ALICE), 80);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Additional integration checks
    // ─────────────────────────────────────────────────────────────────────

    function test_RiskyBorrower_CannotBorrowUndercollateralized() public {
        // Risky wallet: low onchain, moderate FICO
        vm.prank(admin);
        oracle.setOnchainScore(carol, 3, 1);
        vm.prank(admin);
        registry.setAttestation(carol, _makeAttestation(keccak256("carol"), 650));

        // composite = 63*70/100 + 3*40/100 = 44 + 1 = 45 → still overcollateralized
        uint8 composite = oracle.getCompositeScore(carol);
        uint16 ratio = pool.getBorrowerCollateralRatioBps(carol);

        assertTrue(composite < 50, "Risky borrower composite should be below 50");
        assertTrue(ratio >= 12000, "Risky borrower must stay >= 120%");
    }

    function test_NoAttestation_NoOnchainScore_GetsStandardDeFi() public {
        // A brand-new wallet with no credit data
        assertEq(oracle.getCompositeScore(carol), 0);
        assertEq(pool.getBorrowerCollateralRatioBps(carol), 15000); // 150%, standard DeFi
    }

    function test_ClearAttestation_RevertsToOnchainOnly() public {
        // Attestation first so setOnchainScore syncs historical
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(IDENTITY_ALICE, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 98, 5);
        assertEq(oracle.getCompositeScore(alice), 99);

        vm.prank(admin);
        registry.clearAttestation(alice);
        // Back to onchain-only: 98 * 50 / 100 = 49
        assertEq(oracle.getCompositeScore(alice), 49);
        // Historical score preserved (not cleared)
        assertEq(registry.getHistoricalScore(IDENTITY_ALICE), 98);
    }

    function test_ReattestationAfterClear_UsesPreservedHistorical() public {
        // 1. Alice attests, pipeline pushes onchain score — historical recorded
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(IDENTITY_ALICE, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 50, 3);

        // 2. Clear Alice's attestation — historical score stays
        vm.prank(admin);
        registry.clearAttestation(alice);
        assertEq(registry.getHistoricalScore(IDENTITY_ALICE), 50);

        // 3. Attestation re-submitted for Bob with the same identity → no transfer event (no current holder)
        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(IDENTITY_ALICE, 780));

        // Bob inherits the 50 (no own score yet). composite = 60 + 20 = 80
        assertEq(oracle.getCompositeScore(bob), 80);
        assertTrue(oracle.getFullProfile(bob).isUsingInheritedScore);
    }
}
