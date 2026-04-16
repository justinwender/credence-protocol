// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CredenceTestBase} from "./TestHelpers.sol";

contract OffchainAttestationRegistryTest is CredenceTestBase {
    bytes32 constant ID_1 = keccak256("identity-1");
    bytes32 constant ID_2 = keccak256("identity-2");

    // Expected events (for vm.expectEmit)
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

    function setUp() public {
        _deployAll();
    }

    // ─────────────────────────────────────────────────────────────────────
    // setCreditOracle: one-shot authorization
    // ─────────────────────────────────────────────────────────────────────

    function test_SetCreditOracle_CanOnlyBeSetOnce() public {
        // Already set in _deployAll(); any attempt to set again reverts
        vm.prank(admin);
        vm.expectRevert(bytes("Oracle already set"));
        registry.setCreditOracle(address(0xDEAD));
    }

    function test_SetCreditOracle_RevertsOnZeroAddress() public {
        // Deploy a fresh registry without oracle wired up
        OffchainAttestationRegistry fresh = new OffchainAttestationRegistry(admin);
        vm.prank(admin);
        vm.expectRevert(bytes("Zero address"));
        fresh.setCreditOracle(address(0));
    }

    function test_SetCreditOracle_OnlyOwner() public {
        OffchainAttestationRegistry fresh = new OffchainAttestationRegistry(admin);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        fresh.setCreditOracle(address(0xDEAD));
    }

    // ─────────────────────────────────────────────────────────────────────
    // setAttestation: first-time, refresh, and rebinding
    // ─────────────────────────────────────────────────────────────────────

    function test_SetAttestation_FirstTime() public {
        vm.expectEmit(true, true, false, true);
        emit AttestationSet(alice, ID_1, 780);

        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));

        assertTrue(registry.hasAttestation(alice));
        assertEq(registry.getIdentityForWallet(alice), ID_1);
        assertEq(registry.getWalletForIdentity(ID_1), alice);

        OffchainAttestationRegistry.OffchainAttestation memory att = registry.getAttestation(alice);
        assertEq(att.compositeScore, 780);
        assertEq(att.identityHash, ID_1);
        assertTrue(att.timestamp > 0);
    }

    function test_SetAttestation_RefreshSameWalletSameIdentity() public {
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 700));

        // Refresh with a higher FICO on the same identity — no transfer event
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));

        assertEq(registry.getAttestation(alice).compositeScore, 780);
        assertEq(registry.getWalletForIdentity(ID_1), alice);
    }

    function test_SetAttestation_Rebinding_TransfersIdentityAndInheritsScore() public {
        // 1. Alice gets attestation with ID_1
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));

        // 2. Oracle (impersonated) pushes a low historical score for this identity
        vm.prank(address(oracle));
        registry.updateHistoricalScore(ID_1, 15);

        // 3. Rebinding: admin sets the same ID_1 to Bob
        vm.expectEmit(true, true, true, true);
        emit AttestationTransferred(alice, bob, ID_1, 15);
        vm.expectEmit(true, true, false, true);
        emit AttestationSet(bob, ID_1, 780);

        vm.prank(admin);
        registry.setAttestation(bob, _makeAttestation(ID_1, 780));

        // Alice's attestation cleared
        assertFalse(registry.hasAttestation(alice));
        assertEq(registry.getIdentityForWallet(alice), bytes32(0));

        // Bob holds the identity, inheriting the historical score
        assertTrue(registry.hasAttestation(bob));
        assertEq(registry.getIdentityForWallet(bob), ID_1);
        assertEq(registry.getWalletForIdentity(ID_1), bob);
        assertEq(registry.getHistoricalScore(ID_1), 15);
    }

    function test_SetAttestation_SwitchingIdentitiesOnSameWallet_CleansReverseMapping() public {
        // Alice is bound to ID_1, then rebound to ID_2 (e.g., she proves a
        // different offchain identity). The old mapping must be cleaned so
        // ID_1 is no longer pointing at her.
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 700));
        assertEq(registry.getWalletForIdentity(ID_1), alice);

        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_2, 780));

        assertEq(registry.getIdentityForWallet(alice), ID_2);
        assertEq(registry.getWalletForIdentity(ID_2), alice);
        assertEq(registry.getWalletForIdentity(ID_1), address(0)); // cleaned
    }

    function test_SetAttestation_RevertsOnZeroIdentityHash() public {
        OffchainAttestationRegistry.OffchainAttestation memory att = _makeAttestation(ID_1, 780);
        att.identityHash = bytes32(0);
        vm.prank(admin);
        vm.expectRevert(bytes("Zero identityHash"));
        registry.setAttestation(alice, att);
    }

    function test_SetAttestation_RevertsOnZeroWallet() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Zero wallet"));
        registry.setAttestation(address(0), _makeAttestation(ID_1, 780));
    }

    function test_SetAttestation_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        registry.setAttestation(bob, _makeAttestation(ID_1, 780));
    }

    // ─────────────────────────────────────────────────────────────────────
    // clearAttestation
    // ─────────────────────────────────────────────────────────────────────

    function test_ClearAttestation_PreservesHistoricalScore() public {
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));
        vm.prank(address(oracle));
        registry.updateHistoricalScore(ID_1, 75);

        vm.expectEmit(true, true, false, true);
        emit AttestationCleared(alice, ID_1);
        vm.prank(admin);
        registry.clearAttestation(alice);

        assertFalse(registry.hasAttestation(alice));
        assertEq(registry.getIdentityForWallet(alice), bytes32(0));
        assertEq(registry.getWalletForIdentity(ID_1), address(0));
        // Historical score must persist across clear
        assertEq(registry.getHistoricalScore(ID_1), 75);
    }

    function test_ClearAttestation_RevertsIfNoAttestation() public {
        vm.prank(admin);
        vm.expectRevert(bytes("No attestation"));
        registry.clearAttestation(alice);
    }

    function test_ClearAttestation_OnlyOwner() public {
        vm.prank(admin);
        registry.setAttestation(alice, _makeAttestation(ID_1, 780));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        registry.clearAttestation(alice);
    }

    // ─────────────────────────────────────────────────────────────────────
    // updateHistoricalScore: oracle-gated
    // ─────────────────────────────────────────────────────────────────────

    function test_UpdateHistoricalScore_OnlyOracle() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Only oracle"));
        registry.updateHistoricalScore(ID_1, 50);

        vm.prank(alice);
        vm.expectRevert(bytes("Only oracle"));
        registry.updateHistoricalScore(ID_1, 50);
    }

    function test_UpdateHistoricalScore_OracleCanWrite() public {
        vm.expectEmit(true, false, false, true);
        emit HistoricalScoreUpdated(ID_1, 42);

        vm.prank(address(oracle));
        registry.updateHistoricalScore(ID_1, 42);

        assertEq(registry.getHistoricalScore(ID_1), 42);
    }

    function test_UpdateHistoricalScore_RevertsOnScoreGt100() public {
        vm.prank(address(oracle));
        vm.expectRevert(bytes("Score > 100"));
        registry.updateHistoricalScore(ID_1, 101);
    }

    function test_UpdateHistoricalScore_RevertsOnZeroIdentity() public {
        vm.prank(address(oracle));
        vm.expectRevert(bytes("Zero identityHash"));
        registry.updateHistoricalScore(bytes32(0), 50);
    }
}
