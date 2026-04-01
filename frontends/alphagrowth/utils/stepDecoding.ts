import { formatUnits, getAddress, toFunctionSelector } from 'viem'
import type { TxPlan } from '~/entities/txPlan'
import type { EVCCall } from '~/utils/evc-converter'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface StepAssetInfo {
  symbol: string
  address?: string
  amount?: number | string
  iconUrl?: string
}

export interface DisplayStep {
  index: number
  label: string
  labelSuffix?: string
  isSeparateTx: boolean
  assetInfo?: StepAssetInfo
  toAssetInfo?: StepAssetInfo
  iconOnly?: boolean
}

/** Structurally matches useVaultRegistry().getVault */
export type VaultLookup = (address: string) => {
  asset: { symbol: string, address: string, decimals: bigint }
} | undefined

/** All prop-derived context needed by the decoding functions */
export interface StepDecodingContext {
  type?: string
  asset: { symbol: string, address: string, decimals?: bigint }
  assetIconUrl?: string
  amount: number | string
  supplyingAssetForBorrow?: { symbol: string, address: string }
  supplyingAmount?: number | string
  swapToAsset?: { symbol: string, address: string, decimals: bigint }
  swapToAmount?: number | string
  transferAmounts?: Record<string, string>
}

// ---------------------------------------------------------------------------
// Constants (internal)
// ---------------------------------------------------------------------------

const SELECTOR_LABELS: Record<string, string> = {
  [toFunctionSelector('function deposit(uint256,address)')]: 'Supply',
  [toFunctionSelector('function borrow(uint256,address)')]: 'Borrow',
  [toFunctionSelector('function repay(uint256,address)')]: 'Repay',
  [toFunctionSelector('function withdraw(uint256,address,address)')]: 'Withdraw',
  [toFunctionSelector('function redeem(uint256,address,address)')]: 'Withdraw',
  [toFunctionSelector('function enableController(address,address)')]: 'Enable controller',
  [toFunctionSelector('function enableCollateral(address,address)')]: 'Enable collateral',
  [toFunctionSelector('function disableController()')]: 'Disable controller',
  [toFunctionSelector('function disableCollateral(address,address)')]: 'Disable collateral',
  [toFunctionSelector('function transfer(address,uint256)')]: 'Transfer',
  [toFunctionSelector('function transferFromMax(address,address)')]: 'Transfer to account',
  [toFunctionSelector('function skim(uint256,address)')]: 'Deposit',
  [toFunctionSelector('function repayWithShares(uint256,address)')]: 'Repay',
  [toFunctionSelector('function signTermsOfUse(string,bytes32)')]: 'Sign terms of use',
  [toFunctionSelector('function multicall(bytes[])')]: 'Swap',
  [toFunctionSelector('function verifyAmountMinAndSkim(address,address,uint256,uint256)')]: 'Verify min received',
  [toFunctionSelector('function verifyAmountMinAndTransfer(address,address,uint256,uint256)')]: 'Verify min received',
  [toFunctionSelector('function verifyDebtMax(address,address,uint256,uint256)')]: 'Verify max debt',
  [toFunctionSelector('function updatePriceFeeds(bytes[])')]: 'Update price feeds',
  [toFunctionSelector('function transferFromSender(address,uint256,address)')]: 'Transfer from wallet',
}

const MAX_UINT256 = 2n ** 256n - 1n

// ---------------------------------------------------------------------------
// Exported helpers
// ---------------------------------------------------------------------------

export const decodeBatchItemLabel = (data: string): string => {
  const selector = data.slice(0, 10).toLowerCase()
  return SELECTOR_LABELS[selector] || 'Unknown operation'
}

export const cleanStepLabel = (label: string): string => {
  return label
    .replace(/\s*via EVC$/i, '')
    .replace(/^Permit2\s+/i, '')
}

/** Extract the second address param from enableCollateral/enableController calldata */
export const decodeVaultAddressFromData = (data: string): string | undefined => {
  if (data.length < 138) return undefined
  try {
    return getAddress(`0x${data.slice(98, 138)}`)
  }
  catch {
    return undefined
  }
}

export const decodeFirstUint256 = (data: string): bigint | undefined => {
  if (data.length < 74) return undefined
  try {
    return BigInt(`0x${data.slice(10, 74)}`)
  }
  catch {
    return undefined
  }
}

export const getVaultAssetInfo = (
  data: string,
  targetContract: string,
  getVault: VaultLookup,
): StepAssetInfo | undefined => {
  const vaultAddress = decodeVaultAddressFromData(data)
  const vault = vaultAddress ? getVault(vaultAddress) : undefined
  if (vault?.asset) return { symbol: vault.asset.symbol, address: vault.asset.address }

  try {
    const targetVault = getVault(getAddress(targetContract))
    if (targetVault?.asset) return { symbol: targetVault.asset.symbol, address: targetVault.asset.address }
  }
  catch { /* ignore */ }

  return undefined
}

export const resolveAmountFromCalldata = (
  data: string,
  targetContract: string,
  getVault: VaultLookup,
): { decoded: boolean, amount?: string, isMax?: boolean } => {
  const raw = decodeFirstUint256(data)
  if (raw === undefined) return { decoded: false }
  if (raw === MAX_UINT256) return { decoded: true, isMax: true }
  if (raw === 0n) return { decoded: true }
  try {
    const vault = getVault(getAddress(targetContract))
    if (vault?.asset?.decimals) {
      return { decoded: true, amount: formatUnits(raw, Number(vault.asset.decimals)) }
    }
  }
  catch { /* ignore */ }
  return { decoded: false }
}

// ---------------------------------------------------------------------------
// Internal: per-step asset resolution (uses mutable cursor state)
// ---------------------------------------------------------------------------

const getAssetInfoForStep = (
  label: string,
  data: string,
  targetContract: string,
  ctx: StepDecodingContext,
  getVault: VaultLookup,
  usedSupply: { value: boolean },
  usedBorrow: { value: boolean },
  usedSwapTo: { value: boolean },
  lastWithdrawAmount: { value: string | undefined },
): StepAssetInfo | undefined => {
  if (label === 'Enable collateral' || label === 'Enable controller' || label === 'Disable collateral' || label === 'Disable controller') {
    return getVaultAssetInfo(data, targetContract, getVault)
  }

  if (label === 'Supply' || label === 'Withdraw') {
    if (ctx.type === 'borrow' && !usedSupply.value && label === 'Supply' && ctx.supplyingAssetForBorrow && ctx.supplyingAmount) {
      usedSupply.value = true
      return { symbol: ctx.supplyingAssetForBorrow.symbol, address: ctx.supplyingAssetForBorrow.address, amount: ctx.supplyingAmount }
    }
    const resolved = resolveAmountFromCalldata(data, targetContract, getVault)
    const displayAmount = resolved.isMax ? 'remaining' : (resolved.decoded ? resolved.amount : ctx.amount)
    if (label === 'Withdraw' && resolved.decoded && resolved.amount) {
      lastWithdrawAmount.value = resolved.amount
    }
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: displayAmount }
  }

  if (label === 'Deposit') {
    if (ctx.swapToAsset && ctx.swapToAmount) {
      return { symbol: ctx.swapToAsset.symbol, address: ctx.swapToAsset.address, amount: ctx.swapToAmount }
    }
    try {
      const targetVault = getVault(getAddress(targetContract))
      if (targetVault?.asset) {
        const resolved = resolveAmountFromCalldata(data, targetContract, getVault)
        const displayAmount = resolved.decoded && !resolved.isMax && resolved.amount
          ? resolved.amount
          : 'remaining'
        return { symbol: targetVault.asset.symbol, address: targetVault.asset.address, amount: displayAmount }
      }
    }
    catch { /* ignore */ }
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: 'remaining' }
  }

  if (label === 'Transfer' || label === 'Transfer to account') {
    const knownAmount = label === 'Transfer to account' && ctx.transferAmounts
      ? ctx.transferAmounts[targetContract.toLowerCase()]
      : undefined
    const transferAmount = knownAmount || (label === 'Transfer to account' ? 'remaining' : undefined)
    try {
      const targetVault = getVault(getAddress(targetContract))
      if (targetVault?.asset) return { symbol: targetVault.asset.symbol, address: targetVault.asset.address, amount: transferAmount }
    }
    catch { /* ignore */ }
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: transferAmount }
  }

  if (label === 'Borrow' || label === 'Repay') {
    const vaultAsset = getVaultAssetInfo(data, targetContract, getVault)
    const borrowAsset = vaultAsset || { symbol: ctx.asset.symbol, address: ctx.asset.address }
    const resolved = resolveAmountFromCalldata(data, targetContract, getVault)
    if (resolved.decoded) {
      const displayAmount = resolved.isMax ? 'max' : resolved.amount
      return { ...borrowAsset, amount: displayAmount }
    }
    if (!usedBorrow.value) {
      usedBorrow.value = true
      return { ...borrowAsset, amount: ctx.amount }
    }
  }

  if (label === 'Swap') {
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: lastWithdrawAmount.value || ctx.amount }
  }

  if (label === 'Verify min received') {
    if (ctx.swapToAsset && data.length >= 202) {
      try {
        const amountMinRaw = BigInt(`0x${data.slice(138, 202)}`)
        const decoded = formatUnits(amountMinRaw, Number(ctx.swapToAsset.decimals))
        usedSwapTo.value = true
        return { symbol: ctx.swapToAsset.symbol, address: ctx.swapToAsset.address, amount: decoded }
      }
      catch { /* fall through */ }
    }
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: ctx.amount }
  }

  if (label === 'Verify max debt') {
    if (data.length >= 202) {
      try {
        const debtVaultAddr = getAddress(`0x${data.slice(34, 74)}`)
        const debtVault = getVault(debtVaultAddr)
        if (debtVault?.asset) {
          const maxDebt = BigInt(`0x${data.slice(138, 202)}`)
          const debtAmount = maxDebt === MAX_UINT256
            ? 'max'
            : formatUnits(maxDebt, Number(debtVault.asset.decimals))
          return { symbol: debtVault.asset.symbol, address: debtVault.asset.address, amount: debtAmount }
        }
      }
      catch { /* fall through */ }
    }
    if (ctx.swapToAsset && ctx.swapToAmount) {
      return { symbol: ctx.swapToAsset.symbol, address: ctx.swapToAsset.address, amount: ctx.swapToAmount }
    }
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: ctx.amount }
  }

  if (label === 'Transfer from wallet') {
    return { symbol: ctx.asset.symbol, address: ctx.asset.address, amount: ctx.amount }
  }

  if (label === 'Update price feeds') {
    return { symbol: ctx.asset.symbol, address: ctx.asset.address }
  }

  return undefined
}

// ---------------------------------------------------------------------------
// Main orchestrator
// ---------------------------------------------------------------------------

export function buildDisplaySteps(
  plan: TxPlan,
  ctx: StepDecodingContext,
  getVault: VaultLookup,
  getLogoUrl: (address: string, symbol: string) => string,
  hasPermit2Approval: boolean,
): DisplayStep[] {
  if (!plan.steps) return []

  const steps: DisplayStep[] = []
  let index = 0
  const usedSupply = { value: false }
  const usedBorrow = { value: false }
  const usedSwapTo = { value: false }
  const lastWithdrawAmount: { value: string | undefined } = { value: undefined }

  for (const step of plan.steps) {
    if (step.type === 'evc-batch') {
      const batchItems = step.args?.[0] as EVCCall[] | undefined
      if (batchItems?.length) {
        const shouldInjectPermit2 = step.label?.includes('Permit2') && !hasPermit2Approval
        const hasTermsOfUse = shouldInjectPermit2
          && batchItems.some(item => decodeBatchItemLabel(item.data) === 'Sign terms of use')

        if (shouldInjectPermit2 && !hasTermsOfUse) {
          index++
          const permitAsset = ctx.type === 'borrow' && ctx.supplyingAssetForBorrow
            ? ctx.supplyingAssetForBorrow
            : ctx.asset
          steps.push({
            index,
            label: 'Sign permit2 message',
            isSeparateTx: false,
            assetInfo: { symbol: permitAsset.symbol, address: permitAsset.address },
          })
        }

        for (const item of batchItems) {
          index++
          const label = decodeBatchItemLabel(item.data)
          const stepAssetInfo = getAssetInfoForStep(label, item.data, item.targetContract, ctx, getVault, usedSupply, usedBorrow, usedSwapTo, lastWithdrawAmount)
          const secondAsset = ctx.supplyingAssetForBorrow || ctx.swapToAsset
          let toAssetInfo: StepAssetInfo | undefined
          if (label === 'Swap' && ctx.swapToAsset && ctx.swapToAmount) {
            toAssetInfo = { symbol: ctx.swapToAsset.symbol, address: ctx.swapToAsset.address, amount: ctx.swapToAmount }
          }
          else if (label === 'Update price feeds' && stepAssetInfo && secondAsset && secondAsset.symbol !== ctx.asset.symbol) {
            toAssetInfo = { symbol: secondAsset.symbol, address: secondAsset.address }
          }
          const displayLabel = label === 'Transfer to account' ? 'Transfer' : label
          const batchLabelSuffix = label === 'Transfer to account' ? 'to savings' : undefined
          steps.push({
            index,
            label: displayLabel,
            labelSuffix: batchLabelSuffix,
            isSeparateTx: false,
            assetInfo: stepAssetInfo,
            toAssetInfo,
            iconOnly: label === 'Update price feeds',
          })

          if (hasTermsOfUse && label === 'Sign terms of use') {
            index++
            const permitAsset = ctx.type === 'borrow' && ctx.supplyingAssetForBorrow
              ? ctx.supplyingAssetForBorrow
              : ctx.asset
            steps.push({
              index,
              label: 'Sign permit2 message',
              isSeparateTx: false,
              assetInfo: { symbol: permitAsset.symbol, address: permitAsset.address },
            })
          }
        }
      }
      else {
        index++
        steps.push({
          index,
          label: cleanStepLabel(step.label || step.functionName),
          isSeparateTx: false,
        })
      }
    }
    else {
      index++
      const isApproval = step.type === 'approve' || step.type === 'permit2-approve'
      const approvalAsset = isApproval
        ? (ctx.type === 'borrow' && ctx.supplyingAssetForBorrow ? ctx.supplyingAssetForBorrow : ctx.asset)
        : undefined

      const labelSuffix = step.type === 'approve'
        ? 'for vault'
        : step.type === 'permit2-approve'
          ? 'for permit2'
          : undefined

      const isRewardOrUnlock = !isApproval && (ctx.type === 'reward' || ctx.type === 'brevis-reward' || ctx.type === 'reul-unlock')
      const rewardIconUrl = ['EUL', 'rEUL'].includes(ctx.asset.symbol)
        ? getLogoUrl(ctx.asset.address, 'EUL')
        : ctx.assetIconUrl
      const stepAsset: StepAssetInfo | undefined = isApproval
        ? (approvalAsset ? { symbol: approvalAsset.symbol, address: approvalAsset.address } : undefined)
        : isRewardOrUnlock
          ? {
              symbol: ctx.asset.symbol,
              address: ctx.asset.address,
              amount: ctx.amount,
              iconUrl: rewardIconUrl,
            }
          : undefined

      steps.push({
        index,
        label: isApproval ? 'Approve' : cleanStepLabel(step.label || step.functionName),
        labelSuffix,
        isSeparateTx: isApproval,
        assetInfo: stepAsset,
      })
    }
  }

  return steps
}
