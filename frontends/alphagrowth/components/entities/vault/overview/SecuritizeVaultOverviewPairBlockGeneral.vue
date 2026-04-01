<script setup lang="ts">
import { formatNumber, formatSignificant } from '~/utils/string-utils'
import { nanoToValue } from '~/utils/crypto-utils'
import { type SecuritizeBorrowVaultPair, getCurrentLiquidationLTV, isLiquidationLTVRamping, getRampTimeRemaining } from '~/entities/vault'
import { getAssetOraclePrice } from '~/services/pricing/priceProvider'
import { getMaxMultiplier, getMaxRoe } from '~/utils/leverage'
import { useModal } from '~/components/ui/composables/useModal'
import { VaultBorrowApyModal, VaultSupplyApyModal } from '#components'

const { pair } = defineProps<{ pair: SecuritizeBorrowVaultPair }>()

const currentLiquidationLTV = computed(() => getCurrentLiquidationLTV(pair))
const isRamping = computed(() => isLiquidationLTVRamping(pair))

const formatTimeRemaining = (seconds: bigint): string => {
  const days = Number(seconds) / 86400
  if (days >= 1) return `${Math.ceil(days)} day${Math.ceil(days) > 1 ? 's' : ''}`
  const hours = Number(seconds) / 3600
  if (hours >= 1) return `${Math.ceil(hours)} hour${Math.ceil(hours) > 1 ? 's' : ''}`
  const minutes = Number(seconds) / 60
  return `${Math.ceil(minutes)} minute${Math.ceil(minutes) > 1 ? 's' : ''}`
}

const modal = useModal()
const { withIntrinsicBorrowApy, getIntrinsicApy, getIntrinsicApyInfo } = useIntrinsicApy()
const { getSupplyRewardApy, getBorrowRewardApy, getSupplyRewardCampaigns, getBorrowRewardCampaigns, hasSupplyRewards, hasBorrowRewards } = useRewardsApy()

// Borrow APY (from EVK borrow vault)
const totalBorrowRewardsAPY = computed(() => getBorrowRewardApy(pair.borrow.address, pair.collateral.address))

const borrowApyWithRewards = computed(() => withIntrinsicBorrowApy(
  nanoToValue(pair.borrow.interestRateInfo.borrowAPY, 25),
  pair.borrow.asset.address,
) - totalBorrowRewardsAPY.value)

const baseBorrowApy = computed(() => nanoToValue(pair.borrow.interestRateInfo.borrowAPY, 25))
const intrinsicBorrowApy = computed(() => getIntrinsicApy(pair.borrow.asset.address))
const borrowRewardInfo = computed(() => getBorrowRewardCampaigns(pair.borrow.address, pair.collateral.address))

// Supply APY (for securitize collateral - intrinsic + rewards only, no interest rate)
const collateralRewardAPY = computed(() => getSupplyRewardApy(pair.collateral.address))
const intrinsicSupplyApy = computed(() => getIntrinsicApy(pair.collateral.asset.address))
const supplyApyWithRewards = computed(() => intrinsicSupplyApy.value + collateralRewardAPY.value)
const supplyRewardInfo = computed(() => getSupplyRewardCampaigns(pair.collateral.address))

const maxMultiplier = computed(() => getMaxMultiplier(pair.borrowLTV))
const maxRoe = computed(() =>
  getMaxRoe(maxMultiplier.value, supplyApyWithRewards.value, borrowApyWithRewards.value),
)

const priceInvert = usePriceInvert(
  () => pair.collateral.asset.symbol,
  () => pair.borrow.asset.symbol,
)

// Calculate price using collateral prices from borrow vault
const price = computed(() => {
  const collateralPrice = pair.borrow.collateralPrices.find(
    p => p.asset === pair.collateral.address,
  )
  const borrowPrice = getAssetOraclePrice(pair.borrow)

  const bid = collateralPrice?.amountOutBid || collateralPrice?.amountOutMid || 0n
  const ask = borrowPrice?.amountOutAsk || borrowPrice?.amountOutMid || 0n

  if (!bid || !ask || ask === 0n) return null
  return Number(bid) / Number(ask)
})

const onSupplyInfoIconClick = () => {
  modal.open(VaultSupplyApyModal, {
    props: {
      lendingAPY: 0, // Securitize vaults don't have interest rates
      intrinsicAPY: intrinsicSupplyApy.value,
      intrinsicApyInfo: getIntrinsicApyInfo(pair.collateral.asset.address),
      campaigns: supplyRewardInfo.value,
    },
  })
}

const onBorrowInfoIconClick = () => {
  modal.open(VaultBorrowApyModal, {
    props: {
      borrowingAPY: baseBorrowApy.value,
      intrinsicAPY: intrinsicBorrowApy.value,
      intrinsicApyInfo: getIntrinsicApyInfo(pair.borrow.asset.address),
      campaigns: borrowRewardInfo.value,
    },
  })
}
</script>

<template>
  <div class="bg-euler-dark-300 rounded-16 flex flex-col gap-24 p-24">
    <p class="text-h3 text-white">
      Overview
    </p>
    <div class="flex flex-col items-start gap-24">
      <VaultOverviewLabelValue
        label="Price"
      >
        <template v-if="price !== null">
          {{ formatSignificant(priceInvert.invertValue(price), 4) }}
          <span class="text-euler-dark-900">{{ priceInvert.displaySymbol }}</span>
          <button
            type="button"
            class="ml-4 text-euler-dark-900 hover:text-white transition-colors inline-flex"
            @click.stop="priceInvert.toggle"
          >
            <SvgIcon
              name="swap-horizontal"
              class="!w-12 !h-12"
            />
          </button>
        </template>
        <template v-else>
          <span class="text-euler-dark-900">-</span>
        </template>
      </VaultOverviewLabelValue>
      <VaultOverviewLabelValue>
        <template #label>
          <span class="flex items-center gap-4">
            Supply APY
            <SvgIcon
              class="!w-20 !h-20 text-content-muted cursor-pointer hover:text-content-secondary"
              name="info-circle"
              @click="onSupplyInfoIconClick"
            />
          </span>
        </template>
        <span class="flex items-center gap-4">
          <SvgIcon
            v-if="hasSupplyRewards(pair.collateral.address)"
            class="!w-20 !h-20 text-accent-500 cursor-pointer"
            name="sparks"
            @click="onSupplyInfoIconClick"
          />
          {{ formatNumber(supplyApyWithRewards) }}%
        </span>
      </VaultOverviewLabelValue>
      <VaultOverviewLabelValue>
        <template #label>
          <span class="flex items-center gap-4">
            Borrow APY
            <SvgIcon
              class="!w-20 !h-20 text-content-muted cursor-pointer hover:text-content-secondary"
              name="info-circle"
              @click="onBorrowInfoIconClick"
            />
          </span>
        </template>
        <span class="flex items-center gap-4">
          <SvgIcon
            v-if="hasBorrowRewards(pair.borrow.address, pair.collateral.address)"
            class="!w-20 !h-20 text-accent-500 cursor-pointer"
            name="sparks"
            @click="onBorrowInfoIconClick"
          />
          {{ formatNumber(borrowApyWithRewards) }}%
        </span>
      </VaultOverviewLabelValue>
      <VaultOverviewLabelValue
        label="Max ROE"
        :value="`${formatNumber(maxRoe, 2, 2)}%`"
      />
      <VaultOverviewLabelValue
        label="Max multiplier"
        :value="`${formatNumber(maxMultiplier, 2, 2)}x`"
      />
      <VaultOverviewLabelValue
        label="Max LTV"
        :value="`${formatNumber(nanoToValue(pair.borrowLTV, 2), 2)}%`"
      />
      <VaultOverviewLabelValue
        label="Liquidation LTV"
      >
        <div class="flex items-center gap-4">
          <SvgIcon
            v-if="isRamping"
            name="arrow-top-right"
            class="!w-14 !h-14 text-warning-500 shrink-0 rotate-180"
            title="Liquidation LTV ramping down"
          />
          <span>{{ `${formatNumber(nanoToValue(currentLiquidationLTV, 2), 2)}%` }}</span>
          <span
            v-if="isRamping"
            @click.stop.prevent
          >
            <UiFootnote
              title="LTV Ramping"
              :text="`The Liquidation LTV for this pair is being reduced. Target: ${formatNumber(nanoToValue(pair.liquidationLTV, 2), 2)}%. Time remaining: ${formatTimeRemaining(getRampTimeRemaining(pair))}.`"
              class="[--ui-footnote-icon-color:var(--c-content-tertiary)]"
            />
          </span>
        </div>
      </VaultOverviewLabelValue>
    </div>
  </div>
</template>
