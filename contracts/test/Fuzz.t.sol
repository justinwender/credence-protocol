// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {CredenceTestBase} from "./TestHelpers.sol";

contract FuzzTest is CredenceTestBase {
    function setUp() public {
        _deployAll();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Composite score invariants
    // ─────────────────────────────────────────────────────────────────────

    /// Composite score must always be in [0, 100] for any onchain score, with
    /// or without attestation and any valid multiplier settings.
    function testFuzz_CompositeAlwaysInRange_OnchainOnly(uint8 score, uint8 mult) public {
        score = uint8(bound(uint256(score), 0, 100));
        mult = uint8(bound(uint256(mult), 0, 100));

        vm.prank(admin);
        oracle.setMultipliers(mult, 70, 40);
        vm.prank(admin);
        oracle.setOnchainScore(alice, score, 1);

        uint8 composite = oracle.getCompositeScore(alice);
        assertLe(uint256(composite), 100);
    }

    function testFuzz_CompositeAlwaysInRange_WithAttestation(
        uint8 score,
        uint16 fico,
        uint8 baseline,
        uint8 boost
    ) public {
        score = uint8(bound(uint256(score), 0, 100));
        fico = uint16(bound(uint256(fico), 300, 850));
        baseline = uint8(bound(uint256(baseline), 0, 100));
        boost = uint8(bound(uint256(boost), 0, 100));

        vm.prank(admin);
        oracle.setMultipliers(50, baseline, boost);
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(keccak256("fuzz"), fico));
        vm.prank(admin);
        oracle.setOnchainScore(alice, score, 1);

        uint8 composite = oracle.getCompositeScore(alice);
        assertLe(uint256(composite), 100);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Thin-file cap invariant: onchain-only composite never unlocks <100% collateral
    // at the default multiplier (50). This is the core safety property.
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_ThinFileCap_OnchainOnlyStaysOvercollateralized(uint8 score) public {
        score = uint8(bound(uint256(score), 0, 100));

        vm.prank(admin);
        oracle.setOnchainScore(alice, score, 1);

        uint8 composite = oracle.getCompositeScore(alice); // onchain-only
        uint16 ratioBps = pool.getCollateralRatioBps(composite);
        assertGe(uint256(ratioBps), 10000, "Onchain-only must stay >= 100%");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Collateral curve monotonicity (non-increasing in score)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_CurveMonotonic(uint8 s1, uint8 s2) public view {
        s1 = uint8(bound(uint256(s1), 0, 100));
        s2 = uint8(bound(uint256(s2), 0, 100));
        if (s1 > s2) (s1, s2) = (s2, s1);

        uint16 r1 = pool.getCollateralRatioBps(s1);
        uint16 r2 = pool.getCollateralRatioBps(s2);
        assertGe(uint256(r1), uint256(r2)); // score ↑ ⇒ ratio ↓ (non-increasing)
    }

    function testFuzz_CurveRatioBounds(uint8 score) public view {
        score = uint8(bound(uint256(score), 0, 100));
        uint16 r = pool.getCollateralRatioBps(score);
        assertGe(uint256(r), 7500);   // default floor (75%)
        assertLe(uint256(r), 15000);  // default ceiling (150%)
    }

    // ─────────────────────────────────────────────────────────────────────
    // FICO mapping: linear and bounded
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_FicoMappingBounds(uint16 fico) public view {
        uint8 mapped = oracle.mapFicoToZero100(fico);
        assertLe(uint256(mapped), 100);
    }

    function testFuzz_FicoMappingMonotonic(uint16 f1, uint16 f2) public view {
        if (f1 > f2) (f1, f2) = (f2, f1);
        uint8 m1 = oracle.mapFicoToZero100(f1);
        uint8 m2 = oracle.mapFicoToZero100(f2);
        assertLe(uint256(m1), uint256(m2)); // higher FICO ⇒ higher mapped value
    }
}
