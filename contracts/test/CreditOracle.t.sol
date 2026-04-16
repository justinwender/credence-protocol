// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CredenceTestBase} from "./TestHelpers.sol";

contract CreditOracleTest is CredenceTestBase {
    bytes32 constant ID_1 = keccak256("identity-1");

    event OnchainScoreSet(address indexed wallet, uint8 score, uint8 chainsUsed);
    event MultipliersUpdated(
        uint8 onchainOnlyMultiplier,
        uint8 offchainBaselineMultiplier,
        uint8 onchainBoostMultiplier
    );

    function setUp() public {
        _deployAll();
    }

    // ─────────────────────────────────────────────────────────────────────
    // setOnchainScore: auth, validation, and identity sync
    // ─────────────────────────────────────────────────────────────────────

    function test_SetOnchainScore_Basic() public {
        vm.expectEmit(true, false, false, true);
        emit OnchainScoreSet(alice, 75, 3);

        vm.prank(admin);
        oracle.setOnchainScore(alice, 75, 3);

        CreditOracle.CreditProfile memory p = oracle.getFullProfile(alice);
        assertEq(p.onchainScore, 75);
        assertEq(p.chainsUsed, 3);
        assertFalse(p.hasOffchainAttestation);
        assertFalse(p.isUsingInheritedScore);
    }

    function test_SetOnchainScore_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        oracle.setOnchainScore(alice, 50, 1);
    }

    function test_SetOnchainScore_RevertsOnScoreGt100() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Score > 100"));
        oracle.setOnchainScore(alice, 101, 1);
    }

    function test_SetOnchainScore_RevertsOnInvalidChainsUsed() public {
        vm.prank(admin);
        vm.expectRevert(bytes("chainsUsed out of range"));
        oracle.setOnchainScore(alice, 50, 0);

        vm.prank(admin);
        vm.expectRevert(bytes("chainsUsed out of range"));
        oracle.setOnchainScore(alice, 50, 6);
    }

    function test_SetOnchainScore_RevertsOnZeroWallet() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Zero wallet"));
        oracle.setOnchainScore(address(0), 50, 1);
    }

    function test_SetOnchainScore_SyncsHistoricalWhenAttested() public {
        // Attestation first
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        // Historical starts at 0
        assertEq(registry.getHistoricalScore(ID_1), 0);

        // Oracle pushes a score → should propagate into registry
        vm.prank(admin);
        oracle.setOnchainScore(alice, 82, 5);
        assertEq(registry.getHistoricalScore(ID_1), 82);
    }

    function test_SetOnchainScore_DoesNotSyncWhenNoAttestation() public {
        vm.prank(admin);
        oracle.setOnchainScore(alice, 75, 5);
        // No attestation exists → registry not touched for any identity
        assertEq(registry.getIdentityForWallet(alice), bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    // FICO → 0-100 linear mapping
    // ─────────────────────────────────────────────────────────────────────

    function test_MapFicoToZero100_Boundaries() public view {
        assertEq(oracle.mapFicoToZero100(300), 0);
        assertEq(oracle.mapFicoToZero100(850), 100);
        assertEq(oracle.mapFicoToZero100(250), 0);   // clamps below
        assertEq(oracle.mapFicoToZero100(900), 100); // clamps above
    }

    function test_MapFicoToZero100_KnownAnchors() public view {
        // (fico - 300) * 100 / 550
        assertEq(oracle.mapFicoToZero100(500), 36);
        assertEq(oracle.mapFicoToZero100(575), 50);
        assertEq(oracle.mapFicoToZero100(650), 63); // 350*100/550 = 63.63 → 63
        assertEq(oracle.mapFicoToZero100(700), 72); // 400*100/550 = 72.72 → 72
        assertEq(oracle.mapFicoToZero100(750), 81);
        assertEq(oracle.mapFicoToZero100(780), 87);
        assertEq(oracle.mapFicoToZero100(820), 94);
    }

    // ─────────────────────────────────────────────────────────────────────
    // getCompositeScore: onchain-only path (thin-file cap)
    // ─────────────────────────────────────────────────────────────────────

    function test_Composite_OnchainOnly_AppliesMultiplier() public {
        // Default multiplier = 50. score 98 → composite 49.
        vm.prank(admin);
        oracle.setOnchainScore(alice, 98, 5);
        assertEq(oracle.getCompositeScore(alice), 49);
    }

    function test_Composite_OnchainOnly_ZeroScoreZeroComposite() public {
        assertEq(oracle.getCompositeScore(alice), 0);
    }

    function test_Composite_OnchainOnly_MaxIs50AtDefaults() public {
        // Max possible onchain score is 100. With multiplier 50 → composite 50.
        vm.prank(admin);
        oracle.setOnchainScore(alice, 100, 5);
        assertEq(oracle.getCompositeScore(alice), 50);
    }

    // ─────────────────────────────────────────────────────────────────────
    // getCompositeScore: both-signals path
    // ─────────────────────────────────────────────────────────────────────

    function test_Composite_WithAttestation_FicoAloneBaseline() public {
        // onchain=0, FICO 780 (→87) → baseline = 87*70/100 = 60; boost = 0; composite = 60
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        assertEq(oracle.getCompositeScore(alice), 60);
    }

    function test_Composite_WithAttestation_StrongOnchainPlusStrongOffchain() public {
        // onchain=98, FICO 780(→87): baseline 60 + boost 39 = 99
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 98, 5);
        assertEq(oracle.getCompositeScore(alice), 99);
    }

    function test_Composite_WithAttestation_ClampsAt100() public {
        // FICO 850 (→100) baseline 70 + onchain 100 boost 40 = 110 → clamped to 100
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 850));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 100, 5);
        assertEq(oracle.getCompositeScore(alice), 100);
    }

    function test_Composite_WithAttestation_WeakOnchainStrongFico() public {
        // onchain=20, FICO 780(→87): baseline 60 + boost 8 = 68
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 20, 5);
        assertEq(oracle.getCompositeScore(alice), 68);
    }

    // ─────────────────────────────────────────────────────────────────────
    // getCompositeScore: historical score inheritance (Sybil resistance)
    // ─────────────────────────────────────────────────────────────────────

    function test_Composite_InheritsHistoricalWhenOwnScoreIsZero() public {
        // 1. Alice has attestation and onchain score; oracle syncs historical
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 15, 3); // got liquidated, low onchain

        // Composite = baseline 60 + boost (15*40/100=6) = 66
        assertEq(oracle.getCompositeScore(alice), 66);
        assertEq(registry.getHistoricalScore(ID_1), 15);

        // 2. User rebinds attestation to Bob (fresh wallet, no score)
        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(ID_1, 780));

        // Bob has no own score but inherits 15 via identity → composite = 66 too
        assertEq(oracle.getCompositeScore(bob), 66);

        CreditOracle.CreditProfile memory p = oracle.getFullProfile(bob);
        assertEq(p.onchainScore, 0);
        assertEq(p.historicalOnchainScore, 15);
        assertTrue(p.isUsingInheritedScore);
    }

    function test_Composite_PrefersOwnScoreOverHistorical() public {
        // Seed historical = 15 for ID_1
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        vm.prank(admin);
        oracle.setOnchainScore(alice, 15, 3);

        // Rebind to Bob
        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(ID_1, 780));
        assertEq(oracle.getCompositeScore(bob), 66); // inherited 15

        // Pipeline later pushes Bob's own score = 70 (also syncs historical)
        vm.prank(admin);
        oracle.setOnchainScore(bob, 70, 3);
        // Composite now uses Bob's own 70: baseline 60 + boost 28 = 88
        assertEq(oracle.getCompositeScore(bob), 88);

        CreditOracle.CreditProfile memory p = oracle.getFullProfile(bob);
        assertEq(p.onchainScore, 70);
        assertFalse(p.isUsingInheritedScore);
        // Historical is kept in sync with own score
        assertEq(registry.getHistoricalScore(ID_1), 70);
    }

    function test_Composite_NoInheritance_WhenOwnScoreIsZeroButNoHistorical() public {
        // Attestation exists but no historical ever recorded → composite uses 0
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        // No setOnchainScore call → Alice own=0, historical=0

        // Composite = baseline 60 + boost 0 = 60
        assertEq(oracle.getCompositeScore(alice), 60);
        CreditOracle.CreditProfile memory p = oracle.getFullProfile(alice);
        assertFalse(p.isUsingInheritedScore);
    }

    // ─────────────────────────────────────────────────────────────────────
    // setMultipliers
    // ─────────────────────────────────────────────────────────────────────

    function test_SetMultipliers_Updates() public {
        vm.expectEmit(false, false, false, true);
        emit MultipliersUpdated(30, 80, 50);

        vm.prank(admin);
        oracle.setMultipliers(30, 80, 50);

        assertEq(oracle.onchainOnlyMultiplier(), 30);
        assertEq(oracle.offchainBaselineMultiplier(), 80);
        assertEq(oracle.onchainBoostMultiplier(), 50);

        // Verify new math applies: onchain 100 → composite 30 (onchain-only)
        vm.prank(admin);
        oracle.setOnchainScore(alice, 100, 5);
        assertEq(oracle.getCompositeScore(alice), 30);
    }

    function test_SetMultipliers_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        oracle.setMultipliers(30, 80, 50);
    }

    function test_SetMultipliers_RevertsOnGt100() public {
        vm.prank(admin);
        vm.expectRevert(bytes("onchainOnly > 100"));
        oracle.setMultipliers(101, 70, 40);

        vm.prank(admin);
        vm.expectRevert(bytes("offchainBaseline > 100"));
        oracle.setMultipliers(50, 101, 40);

        vm.prank(admin);
        vm.expectRevert(bytes("onchainBoost > 100"));
        oracle.setMultipliers(50, 70, 101);
    }
}
