import type { Address, Hash, Hex, StateOverride } from 'viem'
import { simulateContract } from '@wagmi/vue/actions'
import type { OperationsContext, AllowanceHelpers } from './types'
import type { TxPlan } from '~/entities/txPlan'
import { catchToFallback } from '~/utils/errorHandling'
import { isNonBlockingSimulationError } from '~/utils/tx-errors'

export const createExecutionHelpers = (ctx: OperationsContext, allowanceHelpers: AllowanceHelpers) => {
  const waitForTxReceipt = async (txHash?: Hash) => {
    if (!txHash) {
      return
    }

    const receipt = await ctx.rpcProvider.waitForTransactionReceipt({ hash: txHash })
    if (receipt.status === 'reverted') {
      throw new Error('Transaction reverted')
    }
  }

  const executeTxPlan = async (plan: TxPlan) => {
    if (!ctx.address.value) {
      throw new Error('Wallet not connected')
    }

    let lastHash: Hex | undefined

    for (const step of plan.steps) {
      const txHash = await ctx.writeContractAsync({
        address: step.to,
        abi: step.abi,
        functionName: step.functionName as any,
        args: step.args as any,
        value: step.value ?? 0n,
      })

      lastHash = txHash
      await waitForTxReceipt(txHash)
    }

    return lastHash
  }

  const simulateTxPlan = async (plan: TxPlan) => {
    if (!ctx.address.value) {
      throw new Error('Wallet not connected')
    }

    const hasApprovalSteps = plan.steps.some(step => step.type === 'approve' || step.type === 'permit2-approve')
    const usesPermit2 = plan.steps.some(step => step.type === 'permit2-approve' || (step.label && step.label.includes('Permit2')))
    const stepsToSimulate = plan.steps.filter(step => step.type !== 'approve' && step.type !== 'permit2-approve')

    const stateOverride = await catchToFallback(
      async () => {
        const overrides = await allowanceHelpers.buildSimulationStateOverride(plan, ctx.address.value as Address)
        return overrides.length ? overrides as StateOverride : undefined
      },
      undefined,
      'simulateTxPlan/stateOverrides',
    )

    for (const step of stepsToSimulate) {
      try {
        await simulateContract(ctx.config, {
          account: ctx.address.value as Address,
          address: step.to,
          abi: step.abi,
          functionName: step.functionName as any,
          args: step.args as any,
          value: step.value ?? 0n,
          stateOverride,
        })
      }
      catch (err) {
        const isNonBlocking = (hasApprovalSteps || usesPermit2) && isNonBlockingSimulationError(err)
        if (isNonBlocking) {
          continue
        }
        throw err
      }
    }
  }

  return {
    executeTxPlan,
    simulateTxPlan,
  }
}
