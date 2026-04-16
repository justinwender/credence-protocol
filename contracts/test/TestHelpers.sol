// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @dev Shared fixtures for Credence contract tests.
abstract contract CredenceTestBase is Test {
    address internal admin   = address(0xA11CE);
    address internal alice   = address(0xA1);
    address internal bob     = address(0xB0B);
    address internal carol   = address(0xCA10);
    address internal lp      = address(0xBEEF);

    OffchainAttestationRegistry internal registry;
    CreditOracle                internal oracle;
    LendingPool                 internal pool;

    function _deployAll() internal {
        registry = new OffchainAttestationRegistry(admin);
        oracle   = new CreditOracle(admin, registry);
        pool     = new LendingPool(admin, oracle);

        vm.prank(admin);
        registry.setCreditOracle(address(oracle));
    }

    function _makeAttestation(
        bytes32 identityHash,
        uint16 ficoScore
    ) internal pure returns (OffchainAttestationRegistry.OffchainAttestation memory) {
        return OffchainAttestationRegistry.OffchainAttestation({
            identityHash:         identityHash,
            paymentHistoryScore:  85,
            creditUtilizationPct: 25,
            creditHistoryMonths:  60,
            numberOfAccounts:     5,
            hardInquiries:        1,
            compositeScore:       ficoScore,
            isVerified:           true,
            timestamp:            0       // overwritten by the contract
        });
    }
}
