import { useMemo, useState, useEffect } from 'react';
import { ethers } from 'ethers';
import CreditOracleABI from '../contracts/CreditOracle.json';
import LendingPoolABI from '../contracts/LendingPool.json';
import OffchainAttestationRegistryABI from '../contracts/OffchainAttestationRegistry.json';
import { CONTRACTS, BSC_TESTNET_RPC } from '../config.js';

/**
 * React hook that creates ethers.js v6 Contract instances for all three
 * Credence Protocol contracts.
 *
 * Read-only instances are always available via JsonRpcProvider.
 * Signer-connected instances are created when `walletProvider` is available
 * (from Web3Modal's useWeb3ModalProvider hook).
 *
 * In ethers v6, write operations require contracts connected to a Signer,
 * not a Provider. Since getSigner() is async, we resolve it in a useEffect
 * and store the signer-connected contracts in state.
 */
export default function useContracts(account, walletProvider) {
  // Read-only provider — always available
  const readProvider = useMemo(
    () => new ethers.JsonRpcProvider(BSC_TESTNET_RPC),
    [],
  );

  // Read-only contract instances
  const readOracle = useMemo(
    () => new ethers.Contract(CONTRACTS.oracle, CreditOracleABI.abi, readProvider),
    [readProvider],
  );

  const readPool = useMemo(
    () => new ethers.Contract(CONTRACTS.pool, LendingPoolABI.abi, readProvider),
    [readProvider],
  );

  const readRegistry = useMemo(
    () => new ethers.Contract(CONTRACTS.registry, OffchainAttestationRegistryABI.abi, readProvider),
    [readProvider],
  );

  // Signer-connected instances — resolved async when wallet connects
  const [writeContracts, setWriteContracts] = useState({
    oracle: null, pool: null, registry: null, signer: null,
  });

  useEffect(() => {
    if (!account || !walletProvider) {
      setWriteContracts({ oracle: null, pool: null, registry: null, signer: null });
      return;
    }

    let cancelled = false;

    async function init() {
      try {
        const browserProvider = new ethers.BrowserProvider(walletProvider);
        const signer = await browserProvider.getSigner();

        if (cancelled) return;

        setWriteContracts({
          oracle: new ethers.Contract(CONTRACTS.oracle, CreditOracleABI.abi, signer),
          pool: new ethers.Contract(CONTRACTS.pool, LendingPoolABI.abi, signer),
          registry: new ethers.Contract(CONTRACTS.registry, OffchainAttestationRegistryABI.abi, signer),
          signer,
        });
      } catch (err) {
        console.error('Failed to get signer:', err);
        if (!cancelled) {
          setWriteContracts({ oracle: null, pool: null, registry: null, signer: null });
        }
      }
    }

    init();
    return () => { cancelled = true; };
  }, [account, walletProvider]);

  return {
    oracle: writeContracts.oracle,
    pool: writeContracts.pool,
    registry: writeContracts.registry,
    readOracle,
    readPool,
    readRegistry,
    signer: writeContracts.signer,
  };
}
