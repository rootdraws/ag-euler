import { encodeFunctionData, decodeFunctionResult, zeroAddress, type Address, type Hex, type Abi } from 'viem'
import { EVC_ABI, type BatchItem, type BatchItemResult } from '~/abis/evc'
import { getPublicClient } from '~/utils/public-client'

export type MulticallResult<T = unknown> = {
  success: boolean
  result: T | null
  error?: Error
}

/**
 * Execute multiple contract calls in a single RPC request using EVC batchSimulation.
 * This is more reliable than Multicall3 as EVC is guaranteed to exist on all Euler chains.
 *
 * @param evcAddress - EVC contract address
 * @param items - Array of batch items (target, data, value)
 * @param rpcUrl - JSON-RPC URL
 * @returns Array of BatchItemResult in same order as items
 */
export const evcBatchCall = async (
  evcAddress: string,
  items: BatchItem[],
  rpcUrl: string,
): Promise<BatchItemResult[]> => {
  if (items.length === 0) {
    return []
  }

  const client = getPublicClient(rpcUrl)

  try {
    const callData = encodeFunctionData({
      abi: EVC_ABI,
      functionName: 'batchSimulation',
      args: [items],
    })

    const result = await client.call({
      to: evcAddress as Address,
      data: callData,
      value: 0n,
    })

    if (!result.data) {
      return items.map(() => ({
        success: false,
        result: '0x',
      }))
    }

    const decoded = decodeFunctionResult({
      abi: EVC_ABI,
      functionName: 'batchSimulation',
      data: result.data,
    })

    const batchResults = decoded[0] as unknown as BatchItemResult[]
    return batchResults
  }
  catch (err) {
    console.warn('[evcBatchCall] batchSimulation failed:', err)
    return items.map(() => ({
      success: false,
      result: '0x',
    }))
  }
}

/**
 * Build a batch item for a contract call.
 */
export const buildBatchItem = (
  targetContract: string,
  callData: string,
  value: bigint = 0n,
): BatchItem => ({
  targetContract: targetContract as `0x${string}`,
  onBehalfOfAccount: zeroAddress,
  value,
  data: callData as `0x${string}`,
})

/**
 * Batch multiple lens calls using EVC batchSimulation.
 * Encodes calls, executes batch, and returns raw results for decoding.
 *
 * @param evcAddress - EVC contract address
 * @param lensAddress - Lens contract address
 * @param lensAbi - ABI for the lens contract
 * @param calls - Array of { functionName, args } to call
 * @param rpcUrl - JSON-RPC URL
 * @returns Array of decoded results (or null for failed calls)
 */
export const batchLensCalls = async <T>(
  evcAddress: string,
  lensAddress: string,
  lensAbi: Abi | readonly unknown[],
  calls: Array<{ functionName: string, args: unknown[] }>,
  rpcUrl: string,
): Promise<Array<{ success: boolean, result: T | null }>> => {
  if (calls.length === 0) {
    return []
  }

  // Build batch items
  const items: BatchItem[] = calls.map((call) => {
    const callData = encodeFunctionData({
      abi: lensAbi as Abi,
      functionName: call.functionName,
      args: call.args,
    })
    return buildBatchItem(lensAddress, callData)
  })

  // Execute batch
  const batchResults = await evcBatchCall(evcAddress, items, rpcUrl)

  // Decode results
  return batchResults.map((result, index) => {
    if (!result.success) {
      return { success: false, result: null }
    }

    try {
      const decoded = decodeFunctionResult({
        abi: lensAbi as Abi,
        functionName: calls[index].functionName,
        data: result.result as Hex,
      })
      return { success: true, result: decoded as T }
    }
    catch (err) {
      console.warn(`[batchLensCalls] Failed to decode result for ${calls[index].functionName}:`, err)
      return { success: false, result: null }
    }
  })
}
