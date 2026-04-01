import { useAccount, useConfig } from '@wagmi/vue'
import { estimateGas } from '@wagmi/vue/actions'
import { formatEther, type Address, encodeFunctionData } from 'viem'
import { useEulerConfig } from '~/composables/useEulerConfig'
import type { TxPlan, TxStep } from '~/entities/txPlan'
import { getPublicClient } from '~/utils/public-client'
import { catchToFallback } from '~/utils/errorHandling'

export const useEstimatePlanFees = () => {
  const { address } = useAccount()
  const config = useConfig()
  const { EVM_PROVIDER_URL } = useEulerConfig()

  const getFallbackGasLimit = (step: TxStep) => {
    if (step.type === 'approve' || step.type === 'permit2-approve') {
      return 65000n
    }

    if (step.type === 'evc-batch') {
      const calls = Array.isArray(step.args?.[0]) ? step.args[0].length : 1
      return 200000n + (70000n * BigInt(calls))
    }

    return 200000n
  }

  const estimatePlanFees = async (plan: TxPlan) => {
    if (!address.value) {
      throw new Error('Wallet not connected')
    }

    const client = getPublicClient(EVM_PROVIDER_URL)
    const fees = await client.estimateFeesPerGas()
    const gasPrice = fees.maxFeePerGas ?? fees.gasPrice
    if (!gasPrice) {
      throw new Error('Failed to fetch gas price')
    }

    const results: {
      step: TxStep
      gasLimit: bigint
      feeWei: bigint
      feeNative: string
    }[] = []

    for (const step of plan.steps) {
      const data = encodeFunctionData({
        abi: step.abi,
        functionName: step.functionName as any,
        args: step.args as any,
      })

      const gasLimit = await catchToFallback(
        () => estimateGas(config, {
          account: address.value as Address,
          to: step.to,
          value: step.value ?? 0n,
          data,
        }),
        getFallbackGasLimit(step),
        'estimatePlanFees/gasEstimate',
      )

      const feeWei = gasLimit * gasPrice
      results.push({
        step,
        gasLimit,
        feeWei,
        feeNative: formatEther(feeWei),
      })
    }

    const totalWei = results.reduce((acc, r) => acc + r.feeWei, 0n)
    const totalNative = formatEther(totalWei)

    return {
      steps: results,
      totalWei,
      totalNative,
    }
  }

  return { estimatePlanFees }
}
