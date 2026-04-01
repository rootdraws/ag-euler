import { useConfig, useSignTypedData, useWriteContract } from '@wagmi/vue'
import type { OperationsContext } from './types'
import { createPermit2Helpers } from './permit2'
import { createAllowanceHelpers } from './allowance'
import { createOperationHelpers } from './helpers'
import { createExecutionHelpers } from './execution'
import { createVaultBuilders } from './vault'
import { createRepayBuilders } from './repay'
import { createSwapBuilders } from './swaps'
import { useVaultRegistry } from '~/composables/useVaultRegistry'
import { getPublicClient } from '~/utils/public-client'

export const useEulerOperations = () => {
  const { address, chainId } = useWagmi()
  const { writeContractAsync } = useWriteContract()
  const { signTypedDataAsync } = useSignTypedData()
  const config = useConfig()
  const { eulerCoreAddresses, eulerPeripheryAddresses, eulerLensAddresses } = useEulerAddresses()
  const { enableTosSignature: enableTermsOfUseSignature } = useDeployConfig()
  const { EVM_PROVIDER_URL, PYTH_HERMES_URL, SUBGRAPH_URL } = useEulerConfig()
  const { get: registryGet, getVault: registryGetVault } = useVaultRegistry()
  const { permit2Enabled } = usePermit2Preference()

  const rpcProvider = getPublicClient(EVM_PROVIDER_URL)

  const ctx: OperationsContext = {
    address,
    chainId,
    writeContractAsync,
    signTypedDataAsync,
    config,
    eulerCoreAddresses,
    eulerPeripheryAddresses,
    eulerLensAddresses,
    enableTermsOfUseSignature,
    EVM_PROVIDER_URL,
    PYTH_HERMES_URL,
    SUBGRAPH_URL,
    registryGet,
    registryGetVault,
    permit2Enabled,
    rpcProvider,
  }

  const permit2 = createPermit2Helpers(ctx)
  const allowance = createAllowanceHelpers(ctx, permit2)
  const helpers = createOperationHelpers(ctx, permit2, allowance)
  const execution = createExecutionHelpers(ctx, allowance)

  const vault = createVaultBuilders(ctx, helpers, permit2, allowance)
  const repay = createRepayBuilders(ctx, helpers)
  const swaps = createSwapBuilders(ctx, helpers)

  return {
    ...execution,
    buildSimulationStateOverride: allowance.buildSimulationStateOverride,
    ...vault,
    ...repay,
    ...swaps,
  }
}
