<script setup lang="ts">
import { encodeFunctionData } from 'viem'
import type { Address, Hex } from 'viem'
import type { Campaign } from '~/entities/brevis'
import type { VaultAsset } from '~/entities/vault'
import type { TxPlan } from '~/entities/txPlan'
import type { EVCCall } from '~/utils/evc-converter'
import { buildDisplaySteps, type DisplayStep, type StepDecodingContext } from '~/utils/stepDecoding'
import { useVaultRegistry } from '~/composables/useVaultRegistry'
import { logWarn } from '~/utils/errorHandling'
import { formatNumber } from '~/utils/string-utils'
import { getAssetLogoUrl } from '~/composables/useTokens'

const emits = defineEmits(['close', 'confirm'])

interface REULUnlockInfo {
  unlockableAmount: number
  amountToBeBurned: number
  maturityDate: string
  daysUntilMaturity: number
}

const { type, asset, assetIconUrl, campaignInfo: _campaignInfo, reulUnlockInfo, amount, onConfirm, fee, plan, swapToAsset, swapToAmount, supplyingAssetForBorrow, supplyingAmount, transferAmounts } = defineProps<{
  type?: 'supply' | 'withdraw' | 'borrow' | 'repay' | 'swap' | 'transfer' | 'reward' | 'brevis-reward' | 'reul-unlock' | 'disableCollateral' | 'swap-supply' | 'swap-withdraw' | 'swap-borrow'
  asset: VaultAsset
  assetIconUrl?: string
  amount: number | string
  fee?: number | string
  plan?: TxPlan
  supplyingAssetForBorrow?: VaultAsset
  supplyingAmount?: number | string
  swapToAsset?: VaultAsset
  swapToAmount?: number | string
  campaignInfo?: Campaign
  reulUnlockInfo?: REULUnlockInfo
  onConfirm: () => void
  subAccount?: string
  hasBorrows?: boolean
  /** Known amounts for transferFromMax steps, keyed by vault address (lowercase) */
  transferAmounts?: Record<string, string>
}>()

const { chain, address: walletAddress, chainId: currentChainId } = useWagmi()
const { estimatePlanFees } = useEstimatePlanFees()
const { getVault } = useVaultRegistry()
const { buildSimulationStateOverride } = useEulerOperations()
const { eulerCoreAddresses } = useEulerAddresses()
const { isSimulating: isTenderlySimulating, simulationError: tenderlyError, simulate: tenderlySimulate, clearSimulation: clearTenderly, fetchEnabled: fetchTenderlyEnabled } = useTenderlySimulation()

const isEstimatingFee = ref(false)
const feeEstimate = ref<string | null>(null)
const copied = ref(false)
const tenderlyEnabled = ref(false)

fetchTenderlyEnabled().then((enabled) => {
  tenderlyEnabled.value = enabled
})

const handleTenderlySimulate = async () => {
  if (!plan?.steps || !walletAddress.value || !currentChainId.value) return
  clearTenderly()

  try {
    const owner = walletAddress.value as Address
    const stateOverrides = await buildSimulationStateOverride(plan, owner)

    const mainStep = plan.steps.find(s => s.type === 'evc-batch')
    if (!mainStep) return

    const batchItems = mainStep.args?.[0] as EVCCall[] | undefined
    if (!batchItems?.length) return

    const permit2Address = eulerCoreAddresses.value?.permit2 as string | undefined

    const filteredItems = permit2Address
      ? batchItems.filter(
          call => call.targetContract.toLowerCase() !== permit2Address.toLowerCase(),
        )
      : batchItems

    const data = encodeFunctionData({
      abi: mainStep.abi,
      functionName: mainStep.functionName,
      args: [filteredItems],
    })

    const url = await tenderlySimulate({
      chainId: currentChainId.value,
      from: owner,
      to: mainStep.to,
      data: data as Hex,
      value: mainStep.value?.toString() || '0',
      stateOverrides,
    })

    if (url) {
      window.open(url, '_blank', 'noopener,noreferrer')
    }
  }
  catch {
    // Error is captured in tenderlyError ref by the composable
  }
}

const nativeSymbol = computed(() => chain.value?.nativeCurrency?.symbol || 'ETH')

const loadFeeEstimate = async () => {
  if (!plan) {
    feeEstimate.value = null
    return
  }

  try {
    isEstimatingFee.value = true
    const res = await estimatePlanFees(plan)
    feeEstimate.value = res.totalNative
  }
  catch (err) {
    logWarn('OperationReviewModal/feeEstimate', err)
    feeEstimate.value = null
  }
  finally {
    isEstimatingFee.value = false
  }
}

watch(() => plan, () => {
  loadFeeEstimate()
}, { immediate: true })

const handleConfirm = () => {
  emits('close')
  onConfirm()
}

const displaySteps = computed((): DisplayStep[] => {
  if (!plan?.steps) return []

  const ctx: StepDecodingContext = {
    type, asset, assetIconUrl, amount,
    supplyingAssetForBorrow, supplyingAmount,
    swapToAsset, swapToAmount, transferAmounts,
  }

  return buildDisplaySteps(plan, ctx, getVault, getAssetLogoUrl, hasPermit2Approval.value)
})

const copyCalldata = () => {
  if (!plan?.steps) return

  try {
    const calldataEntries = plan.steps.map(step => ({
      to: step.to,
      data: encodeFunctionData({
        abi: step.abi,
        functionName: step.functionName,
        args: step.args,
      }),
      value: step.value?.toString() || '0',
    }))

    navigator.clipboard.writeText(JSON.stringify(calldataEntries, null, 2))
    copied.value = true
    setTimeout(() => {
      copied.value = false
    }, 2000)
  }
  catch (err) {
    logWarn('OperationReviewModal/calldataCopy', err)
  }
}

const btnLabel = computed(() => {
  switch (type) {
    case 'supply':
    case 'swap-supply':
      return 'Supply'
    case 'withdraw':
    case 'swap-withdraw':
      return 'Withdraw'
    case 'borrow':
    case 'swap-borrow':
      return 'Borrow'
    case 'repay':
      return 'Repay'
    case 'swap':
      return 'Swap'
    case 'transfer':
      return 'Transfer'
    case 'reul-unlock':
      return 'Unlock'
    case 'reward':
    case 'brevis-reward':
      return 'Claim'
    case 'disableCollateral':
      return 'Disable collateral'
    default:
      return 'Submit'
  }
})
const reulUnlockDisclaimerText = computed(() => {
  if (type !== 'reul-unlock' || !reulUnlockInfo) return

  return `This action will unlock ${formatNumber(reulUnlockInfo.unlockableAmount, 6)} EUL, and ${formatNumber(reulUnlockInfo.amountToBeBurned, 6)} EUL will be permanently burned. To fully redeem your EUL rewards, you must wait for the 6-month vesting period to complete (${reulUnlockInfo.daysUntilMaturity} days remaining, maturity date: ${reulUnlockInfo.maturityDate}).`
})
const disclaimerText = computed(() => {
  if (type !== 'reward') return
  const displayAmount = Number(amount) < 0.01 ? '< 0.01' : formatNumber(amount)
  return `You're claiming all ${displayAmount} ${asset.symbol} on Merkl. Part of this amount could have been earned outside of Euler.`
})

const hasPermit2Approval = computed(() => {
  return plan?.steps?.some(step => step.type === 'permit2-approve') ?? false
})

const usesPermit2 = computed(() => {
  return plan?.steps?.some(step => step.label?.includes('Permit2')) ?? false
})

const permit2DisclaimerText = 'You are granting the permit2 contract unlimited access to your tokens. This is a safe, one-time setup — permit2 (by Uniswap) is a widely trusted and audited contract that replaces repeated approval transactions with gasless signatures. Each future transaction still requires your explicit signature, limited in both amount and duration.'

const feeDisplay = computed(() => {
  if (isEstimatingFee.value) {
    return '...'
  }

  const value = feeEstimate.value ?? fee
  if (value === undefined || value === null || value === '') {
    return '-'
  }

  return `${formatNumber(value, 8, 0)} ${nativeSymbol.value}`
})
</script>

<template>
  <BaseModalWrapper
    title="Transaction review"
    @close="$emit('close')"
  >
    <div class="flex flex-col gap-24">
      <!-- Transaction Steps -->
      <div
        v-if="displaySteps.length"
        class="flex flex-col gap-8"
      >
        <p class="text-p3 text-euler-dark-900">
          Transaction steps
        </p>
        <div class="bg-euler-dark-600 rounded-12 p-12 flex flex-col gap-8">
          <OperationStepsList :steps="displaySteps" />
        </div>
      </div>

      <!-- Fee -->
      <div class="flex-wrap gap-8 bg-euler-dark-600 p-16 rounded-12 flex justify-between">
        <div class="flex gap-8 items-center">
          <UiIcon
            name="gas"
            class="!w-20 !h-20"
          />
          Transaction fee
        </div>
        <div class="flex gap-8 items-center">
          <span class="text-p2">&asymp; {{ feeDisplay }}</span>
        </div>
      </div>

      <!-- Copy calldata & Tenderly simulate -->
      <div
        v-if="plan?.steps?.length"
        class="flex items-center justify-center gap-16"
      >
        <button
          type="button"
          class="flex items-center gap-6 text-p3 text-euler-dark-900 hover:text-euler-dark-1000 transition-colors"
          @click="copyCalldata"
        >
          <SvgIcon
            name="copy"
            class="!w-16 !h-16"
          />
          {{ copied ? 'Copied!' : 'Copy calldata' }}
        </button>
        <button
          v-if="tenderlyEnabled"
          type="button"
          class="flex items-center gap-6 text-p3 text-euler-dark-900 hover:text-euler-dark-1000 transition-colors"
          :disabled="isTenderlySimulating"
          @click="handleTenderlySimulate"
        >
          <SvgIcon
            :name="isTenderlySimulating ? 'loading' : 'arrow-top-right'"
            class="!w-16 !h-16"
            :class="{ 'animate-spin': isTenderlySimulating }"
          />
          Simulate on Tenderly
        </button>
      </div>
      <p
        v-if="usesPermit2"
        class="text-p4 text-euler-dark-900 text-center"
      >
        Copied calldata does not contain the permit() call. It is only known after the permit2 message is signed.
      </p>

      <!-- Tenderly error -->
      <UiToast
        v-if="tenderlyError"
        title="Simulation failed"
        variant="warning"
        :description="tenderlyError"
        size="compact"
      />

      <!-- Disclaimers -->
      <UiToast
        v-if="type === 'reward'"
        title="Disclaimer"
        variant="warning"
        :description="disclaimerText"
        size="compact"
      />
      <UiToast
        v-if="type === 'reul-unlock'"
        title="Important"
        variant="warning"
        :description="reulUnlockDisclaimerText"
        size="compact"
      />
      <UiToast
        v-if="type === 'disableCollateral'"
        title="Disclaimer"
        variant="warning"
        description="Disabling collateral will move this deposit to savings"
        size="compact"
      />
      <UiToast
        v-if="hasPermit2Approval"
        title="Infinite approval"
        variant="info"
        :description="permit2DisclaimerText"
        size="compact"
      />

      <!-- Confirm button -->
      <UiButton
        variant="primary"
        size="xlarge"
        rounded
        @click="handleConfirm"
      >
        {{ btnLabel }}
      </UiButton>
    </div>
  </BaseModalWrapper>
</template>
