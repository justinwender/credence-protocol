// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/**
 * @title Deploy — deploys all three Credence Protocol contracts and wires them up.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url bsc_testnet \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Requires in .env:
 *   BSC_TESTNET_RPC
 *   BSC_TESTNET_PRIVATE_KEY
 *   ETHERSCAN_API_KEY (for --verify)
 *
 * After deploy, copy the three addresses logged at the bottom into .env as
 *   ATTESTATION_REGISTRY_ADDRESS
 *   CREDIT_ORACLE_ADDRESS
 *   LENDING_POOL_ADDRESS
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("BSC_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        require(deployer.balance > 0.05 ether, "Deployer needs >= 0.05 tBNB");

        vm.startBroadcast(deployerPk);

        // 1. Registry — no dependencies
        OffchainAttestationRegistry registry = new OffchainAttestationRegistry(deployer);
        console.log("OffchainAttestationRegistry:", address(registry));

        // 2. CreditOracle — takes registry address
        CreditOracle oracle = new CreditOracle(deployer, registry);
        console.log("CreditOracle:             ", address(oracle));

        // 3. Wire oracle authorization (one-shot)
        registry.setCreditOracle(address(oracle));
        console.log("Registry authorized Oracle for updateHistoricalScore");

        // 4. LendingPool — takes oracle address
        LendingPool pool = new LendingPool(deployer, oracle);
        console.log("LendingPool:              ", address(pool));

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Copy these into .env:");
        console.log("ATTESTATION_REGISTRY_ADDRESS=", address(registry));
        console.log("CREDIT_ORACLE_ADDRESS=       ", address(oracle));
        console.log("LENDING_POOL_ADDRESS=        ", address(pool));
    }
}
