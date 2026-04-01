<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { getAddress, type Address } from 'viem'
import { zeroAddress } from 'viem'
import { FixedPoint } from '~/utils/fixed-point'
import { POLL_INTERVAL_5S_MS } from '~/entities/tuning-constants'
import { useEulerProductOfVault } from '~/composables/useEulerLabels'
import type { Vault, VaultAsset } from '~/entities/vault'
import { fetchBackendPrice } from '~/services/pricing/backendClient'
import type { SwapApiQuote } from '~/entities/swap'
import { SwapperMode } from '~/entities/swap'
import { formatNumber, formatSmartAmount, formatHealthScore } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import { useCollateralForm } from '~/composables/position/useCollateralForm'

const { isConnected, address } = useAccount()
const { fetchSingleBalance } = useWallets()
const { buildSupplyPlan, buildSwapAndSupplyPlan } = useEulerOperations()

// Supply-specific state
const balance = ref(0n)
const selectedAsset = ref<VaultAsset | undefined>()
const selectedAssetBalance = ref(0n)
const swapAssetUsdPrice = ref<number | undefined>()

const needsSwap = computed(() => {
  if (!selectedAsset.value || !form.asset.value) return false
  try {
    return getAddress(selectedAsset.value.address) !== getAddress(form.asset.value.address)
  }
  catch {
    return false
  }
})

const activeBalance = computed(() => needsSwap.value ? selectedAssetBalance.value : balance.value)
const _activeAsset = computed(() => needsSwap.value ? selectedAsset.value : form.asset.value)

const form = useCollateralForm({
  mode: 'supply',
  needsSwap,
  effectiveBalance: activeBalance,

  computePriceFixed: pos =>
    FixedPoint.fromValue(pos.price || 0n, 18),

  computeLiquidationPrice: (pos) => {
    if (nanoToValue(pos.health || 0n, 18) < 0.1) return Infinity
    return nanoToValue(pos.price || 0n, 18) / nanoToValue(pos.health || 1n, 18)
  },

  validateEstimate: ({ amountFixed, needsSwap: isSwap }) => {
    if (!isSwap && balanceFixed.value.lt(amountFixed)) {
      throw new Error('Not enough balance')
    }
    if (isSwap && selectedAssetBalance.value < valueToNano(form.amount.value, selectedAsset.value?.decimals)) {
      throw new Error('Not enough balance')
    }
  },

  buildDirectPlan: async ({ vaultAddress, assetAddress, amountNano, subAccount, includePermit2Call }) =>
    buildSupplyPlan(vaultAddress, assetAddress, amountNano, subAccount, { includePermit2Call }),

  buildSwapPlan: async (quote: SwapApiQuote, { includePermit2Call }) => {
    if (!selectedAsset.value || !form.collateralVault.value) {
      throw new Error('No selected asset or vault')
    }
    return buildSwapAndSupplyPlan({
      inputTokenAddress: selectedAsset.value.address as Address,
      inputAmount: valueToNano(form.amount.value || '0', selectedAsset.value.decimals),
      quote,
      includePermit2Call,
    })
  },

  requestSwapQuoteParams: ({ userAddr, subAccountAddr, amountNano: _amountNano, slippage }) => {
    if (!selectedAsset.value || !form.asset.value || !form.collateralVault.value) return null
    return {
      tokenIn: selectedAsset.value.address as Address,
      tokenOut: form.asset.value.address as Address,
      accountIn: zeroAddress as Address,
      accountOut: subAccountAddr,
      amount: valueToNano(form.amount.value || '0', selectedAsset.value.decimals),
      vaultIn: zeroAddress as Address,
      receiver: form.collateralVault.value.address as Address,
      unusedInputReceiver: userAddr,
      slippage,
      swapperMode: SwapperMode.EXACT_IN,
      isRepay: false,
      targetDebt: 0n,
      currentDebt: 0n,
    }
  },

  getSwapOutputAsset: () => form.asset.value,

  reviewLabel: 'Review Supply',
  reviewType: 'supply',
  swapReviewType: 'swap-supply',
  getReviewAsset: isSwap => isSwap && selectedAsset.value ? selectedAsset.value : form.asset.value,
  getSwapToAsset: () => form.asset.value,

  onAfterLoad: () => updateBalance(),
})

const balanceFixed = computed(() => FixedPoint.fromValue(balance.value, form.collateralVault.value?.decimals || 18))
const assets = computed(() => [form.asset.value].filter((v): v is VaultAsset => !!v))
const { name } = useEulerProductOfVault(computed(() => form.collateralVault.value?.address || ''))

// Supply-specific: balance management
const updateBalance = async () => {
  if (!isConnected.value || !form.collateralVault.value?.asset.address) {
    balance.value = 0n
    return
  }
  balance.value = await fetchSingleBalance(form.collateralVault.value.asset.address)
}

const fetchSelectedAssetBalance = async () => {
  if (!selectedAsset.value?.address) {
    selectedAssetBalance.value = 0n
    return
  }
  selectedAssetBalance.value = await fetchSingleBalance(selectedAsset.value.address)
}

const onSelectSwapAsset = (newAsset: VaultAsset) => {
  selectedAsset.value = newAsset
  form.amount.value = ''
  form.clearSimulationError()
  form.resetSwapQuoteState()
}

const openSwapTokenSelector = () => {
  form.openSwapTokenSelector(
    selectedAsset.value?.address || form.asset.value?.address,
    onSelectSwapAsset,
  )
}

// Supply-specific watchers
watch(isConnected, () => {
  updateBalance()
})

watch(address, () => {
  updateBalance()
  fetchSelectedAssetBalance()
})

watch(selectedAsset, async () => {
  fetchSelectedAssetBalance()
  if (needsSwap.value && form.amount.value) {
    form.resetSwapQuoteState()
    form.requestSwapQuote()
  }
  if (selectedAsset.value?.address && needsSwap.value) {
    const priceData = await fetchBackendPrice(selectedAsset.value.address as Address)
    swapAssetUsdPrice.value = priceData?.price
  }
  else {
    swapAssetUsdPrice.value = undefined
  }
})

// Balance polling
const interval = setInterval(() => {
  updateBalance()
}, POLL_INTERVAL_5S_MS)

onUnmounted(() => {
  clearInterval(interval)
})
</script>

<template>
  <VaultForm
    title="Supply"
    :loading="form.isLoading.value"
    @submit.prevent="form.submit"
  >
    <div v-if="!isConnected">
      Connect your wallet to see your positions
    </div>

    <template v-else-if="form.collateralVault.value">
      <VaultLabelsAndAssets
        :vault="form.collateralVault.value"
        :assets="assets"
        size="large"
      />

      <div class="grid gap-16 laptop:grid-cols-[minmax(0,1fr)_360px] laptop:items-start">
        <div class="flex flex-col gap-16 w-full">
          <AssetInput
            v-if="form.asset.value"
            v-model="form.amount.value"
            label="Deposit amount"
            :desc="name"
            :asset="needsSwap && selectedAsset ? selectedAsset : form.asset.value"
            :vault="needsSwap ? undefined : (form.collateralVault.value as Vault)"
            :price-override="needsSwap ? swapAssetUsdPrice : undefined"
            :balance="activeBalance"
            maxable
          />

          <!-- Pay with token selector -->
          <div
            v-if="form.enableSwapDeposit"
            class="flex items-center gap-8"
          >
            <span class="text-p3 text-content-tertiary">Pay with</span>
            <button
              type="button"
              class="flex items-center gap-6 bg-euler-dark-500 text-p3 font-semibold px-12 h-36 rounded-[40px] whitespace-nowrap"
              @click="openSwapTokenSelector"
            >
              <AssetAvatar
                :asset="{ address: selectedAsset?.address || form.asset.value?.address || '', symbol: selectedAsset?.symbol || form.asset.value?.symbol || '' }"
                size="20"
              />
              {{ selectedAsset?.symbol || form.asset.value?.symbol }}
              <SvgIcon
                class="text-euler-dark-800 !w-16 !h-16"
                name="arrow-down"
              />
            </button>
          </div>

          <!-- Swap info block -->
          <template v-if="needsSwap && form.asset.value">
            <SwapRouteSelector
              :items="form.swapRouteItems.value"
              :selected-provider="form.swapSelectedProvider.value"
              :status-label="form.swapQuotesStatusLabel.value"
              :is-loading="form.isSwapQuoteLoading.value"
              empty-message="Enter amount to fetch quotes"
              @select="form.selectSwapQuote"
              @refresh="form.onRefreshSwapQuotes"
            />

            <VaultFormInfoBlock
              v-if="form.swapEstimatedOutput.value"
              :loading="form.isSwapQuoteLoading.value"
            >
              <SummaryRow
                label="Estimated deposit"
                align-top
              >
                <p class="text-p2">
                  ~{{ formatSmartAmount(form.swapEstimatedOutput.value) }} {{ form.asset.value.symbol }}
                </p>
              </SummaryRow>
              <SummaryRow label="Slippage tolerance">
                <button
                  type="button"
                  class="flex items-center gap-6 text-p2"
                  @click="form.openSlippageSettings"
                >
                  <span>{{ formatNumber(form.swapSlippage.value, 2, 0) }}%</span>
                  <SvgIcon
                    name="edit"
                    class="!w-16 !h-16 text-accent-600"
                  />
                </button>
              </SummaryRow>
            </VaultFormInfoBlock>

            <UiToast
              v-if="form.swapQuoteError.value"
              title="Swap quote"
              variant="warning"
              :description="form.swapQuoteError.value"
              size="compact"
            />
          </template>

          <UiToast
            v-if="form.isGeoBlocked.value"
            title="Region restricted"
            description="This operation is not available in your region. You can still repay existing debt."
            variant="warning"
            size="compact"
          />
          <UiToast
            v-if="!form.isGeoBlocked.value && form.isSwapRestricted.value"
            title="Swap restricted"
            description="Swapping into this vault is not available in your region. You can deposit the vault's underlying asset directly."
            variant="warning"
            size="compact"
          />
          <UiToast
            v-show="form.estimatesError.value"
            title="Error"
            variant="error"
            :description="form.estimatesError.value"
            size="compact"
          />
          <UiToast
            v-if="form.simulationError.value"
            title="Error"
            variant="error"
            :description="form.simulationError.value"
            size="compact"
          />
        </div>

        <VaultFormInfoBlock
          v-if="form.position.value"
          :loading="form.isEstimatesLoading.value"
          variant="card"
          class="w-full laptop:max-w-[360px]"
        >
          <SummaryRow label="Net APY">
            <SummaryValue
              :before="formatNumber(form.netAPY.value)"
              :after="formatNumber(form.estimateNetAPY.value)"
              suffix="%"
            />
          </SummaryRow>
          <SummaryRow label="Oracle price">
            <SummaryPriceValue
              :value="!form.priceFixed.value.isZero() ? formatSmartAmount(form.priceInvert.invertValue(form.priceFixed.value.toUnsafeFloat())) : undefined"
              :symbol="form.priceInvert.displaySymbol"
              invertible
              @invert="form.priceInvert.toggle"
            />
          </SummaryRow>
          <SummaryRow label="Liquidation price">
            <SummaryPriceValue
              :value="form.liquidationPrice.value != null && form.liquidationPrice.value !== Infinity ? formatSmartAmount(form.priceInvert.invertValue(form.liquidationPrice.value)!) : undefined"
              :symbol="form.priceInvert.displaySymbol"
              invertible
              @invert="form.priceInvert.toggle"
            />
          </SummaryRow>
          <SummaryRow label="LTV">
            <SummaryValue
              :before="formatNumber(nanoToValue(form.position.value.userLTV, 18))"
              :after="formatNumber(nanoToValue(form.estimateUserLTV.value, 18))"
              suffix="%"
            />
          </SummaryRow>
          <SummaryRow label="Health score">
            <SummaryValue
              :before="formatHealthScore(nanoToValue(form.position.value.health, 18))"
              :after="formatHealthScore(nanoToValue(form.estimateHealth.value, 18))"
            />
          </SummaryRow>
        </VaultFormInfoBlock>

        <div class="flex flex-col gap-8 laptop:col-start-1 laptop:row-start-2">
          <VaultFormInfoButton
            :disabled="form.isLoading.value || form.isSubmitting.value"
            :vault="form.collateralVault.value"
          />
          <VaultFormSubmit
            :disabled="form.submitDisabled.value"
            :loading="form.isSubmitting.value || form.isPreparing.value"
          >
            {{ form.submitLabel.value }}
          </VaultFormSubmit>
        </div>
      </div>
    </template>
  </VaultForm>
</template>
