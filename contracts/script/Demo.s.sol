// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/**
 * @title Demo — post-deployment test transaction exercising the full demo flow.
 *
 * Usage (after running Deploy.s.sol and populating .env addresses):
 *   forge script script/Demo.s.sol:Demo \
 *     --rpc-url bsc_testnet \
 *     --broadcast \
 *     -vvv
 *
 * What it does:
 *   1. Deposits 0.05 tBNB into the LendingPool as the deployer (acts as LP)
 *   2. Pushes an onchain score (98) for a demo borrower address
 *   3. Reads the composite score — should be 49 (onchain-only cap)
 *   4. Submits a strong FICO attestation (780) for the same address
 *   5. Reads the composite score — should be 99 (baseline 60 + boost 39)
 *
 * Nothing is left in a risky state: no borrow is executed, the 0.05 tBNB
 * stays in the pool for later demo use.
 *
 * The "demo borrower" is a deterministic vanity address derived from a fixed
 * seed so the demo is reproducible and you can look it up on BscScan.
 */
contract Demo is Script {
    // Deterministic demo borrower — derived from a fixed-hash seed so the
    // address is the same every run. Not controlled by anyone; just a label.
    address constant DEMO_BORROWER = address(uint160(uint256(keccak256("credence-demo-borrower-001"))));

    bytes32 constant DEMO_IDENTITY = keccak256("credence-demo-identity-001");

    function run() external {
        uint256 deployerPk = vm.envUint("BSC_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address registryAddr = vm.envAddress("ATTESTATION_REGISTRY_ADDRESS");
        address oracleAddr   = vm.envAddress("CREDIT_ORACLE_ADDRESS");
        address poolAddr     = vm.envAddress("LENDING_POOL_ADDRESS");

        OffchainAttestationRegistry registry = OffchainAttestationRegistry(registryAddr);
        CreditOracle               oracle   = CreditOracle(oracleAddr);
        LendingPool                pool     = LendingPool(payable(poolAddr));

        console.log("Demo borrower (deterministic):", DEMO_BORROWER);
        console.log("Deployer (admin+LP):          ", deployer);
        console.log("");

        vm.startBroadcast(deployerPk);

        // -------------------- Beat 0: seed liquidity --------------------
        pool.deposit{value: 0.05 ether}();
        console.log("[1/5] Seeded 0.05 tBNB into LendingPool");

        // -------------------- Beat 1: onchain-only --------------------
        oracle.setOnchainScore(DEMO_BORROWER, 98, 5);
        uint8 c1 = oracle.getCompositeScore(DEMO_BORROWER);
        console.log("[2/5] Set onchain score 98; composite now:", c1);
        require(c1 == 49, "Expected composite 49 after onchain-only");

        uint16 r1 = pool.getBorrowerCollateralRatioBps(DEMO_BORROWER);
        console.log("      Collateral ratio (bps):", uint256(r1));
        console.log("      Collateral ratio (pct):", uint256(r1) / 100);

        // -------------------- Beat 2: add attestation --------------------
        OffchainAttestationRegistry.OffchainAttestation memory att =
            OffchainAttestationRegistry.OffchainAttestation({
                identityHash:         DEMO_IDENTITY,
                paymentHistoryScore:  90,
                creditUtilizationPct: 20,
                creditHistoryMonths:  84,
                numberOfAccounts:     5,
                hardInquiries:        1,
                compositeScore:       780,
                isVerified:           true,
                timestamp:            0
            });
        registry.setAttestation(DEMO_BORROWER, att);
        console.log("[3/5] Set FICO 780 attestation for demo borrower");

        // -------------------- Beat 3: re-push score so historical syncs --------------------
        // (Required because the Beat-1 push happened before the attestation existed.)
        oracle.setOnchainScore(DEMO_BORROWER, 98, 5);
        console.log("[4/5] Re-pushed onchain score to sync historical");

        uint8 c2 = oracle.getCompositeScore(DEMO_BORROWER);
        uint16 r2 = pool.getBorrowerCollateralRatioBps(DEMO_BORROWER);
        console.log("[5/5] Composite now (expected ~99):", c2);
        console.log("      Collateral ratio (bps):", uint256(r2));
        console.log("      Collateral ratio (pct):", uint256(r2) / 100);
        require(c2 >= 98 && c2 <= 100, "Expected composite ~99 after attestation");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEMO COMPLETE ===");
        console.log("Verify on BscScan:");
        console.log("  Registry: https://testnet.bscscan.com/address/", registryAddr);
        console.log("  Oracle:   https://testnet.bscscan.com/address/", oracleAddr);
        console.log("  Pool:     https://testnet.bscscan.com/address/", poolAddr);
    }
}
