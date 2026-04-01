<script setup lang="ts">
import { useAccount } from '@wagmi/vue'
import { formatNumber, formatCompactUsdValue } from '~/utils/string-utils'
import { POLL_INTERVAL_10S_MS } from '~/entities/tuning-constants'

defineOptions({
  name: 'PortfolioPage',
})

const route = useRoute()
const router = useRouter()
const {
  borrowPositions,
  depositPositions,
  totalSuppliedValueInfo,
  totalBorrowedValueInfo,
  portfolioRoe,
  portfolioNetApy,
  isPositionsLoaded,
  isShowAllPositions,
  refreshAllPositions,
} = useEulerAccount()
const { rewards } = useMerkl()
const { locks } = useREULLocks()
const { isConnected, address } = useAccount()
const { isLoaded: isBalancesLoaded, updateBalances } = useWallets()
const { eulerLensAddresses } = useEulerAddresses()

const interval: Ref<NodeJS.Timeout | null> = ref(null)

const tabsModel = ref(route.name as string)

const tabs = computed(() => [
  {
    label: 'Positions',
    value: 'portfolio',
    badge: borrowPositions.value.length || null,
  },
  {
    label: 'Savings',
    value: 'portfolio-saving',
    badge: depositPositions.value.length || null,
  },
  {
    label: 'Rewards',
    value: 'portfolio-rewards',
    badge: rewards.value.length + locks.value.length || null,
  },
])

const checkTab = () => {
  if (route.name !== tabsModel.value) {
    router.replace({ name: tabsModel.value })
  }
}

const updatePositions = async () => {
  await refreshAllPositions(eulerLensAddresses.value, address.value as string)
}

watch(tabsModel, checkTab, { immediate: true })
onActivated(async () => {
  checkTab()
  await updateBalances()
  updatePositions()
  interval.value = setInterval(updatePositions, POLL_INTERVAL_10S_MS)
})
onDeactivated(() => {
  if (interval.value) {
    clearInterval(interval.value)
    interval.value = null
  }
})
</script>

<template>
  <section class="flex flex-col gap-16 min-h-[calc(100dvh-178px)] mobile:-mx-16">
    <div class="flex items-center justify-between px-16">
      <h2 class="text-h2 text-content-primary">
        Your Portfolio
      </h2>
      <div class="flex items-center gap-8">
        <span class="text-h6 text-content-secondary">Show all</span>
        <UiFootnote
          title="Show all"
          text="When enabled, shows positions and deposits in the hidden (unknown) vaults."
          tooltip-placement="top-end"
        />
        <UiSwitch
          v-model="isShowAllPositions"
        />
      </div>
    </div>

    <div class="flex flex-col gap-16 p-16 rounded-12 mx-16 border border-line-default bg-card shadow-card">
      <div class="flex justify-between items-center">
        <div class="flex items-center gap-4 text-p2 text-content-secondary">
          Portfolio Net APY
          <UiFootnote
            title="Portfolio Net APY"
            text="Net annual percentage yield across all borrow positions. Calculated as total net yield (supply income minus borrow costs) divided by total supplied value."
            tooltip-placement="bottom-start"
            class="[--ui-footnote-icon-color:var(--c-content-tertiary)]"
          />
        </div>
        <BaseLoadableContent :loading="isConnected && (!isPositionsLoaded || !isBalancesLoaded)">
          <div
            class="text-h5"
            :class="[portfolioNetApy >= 0 ? 'text-accent-600' : 'text-error-500']"
          >
            {{ Number.isFinite(portfolioNetApy) ? `${formatNumber(portfolioNetApy)}%` : '-' }}
          </div>
        </BaseLoadableContent>
      </div>
      <div class="flex justify-between items-center">
        <div class="flex items-center gap-4 text-p2 text-content-secondary">
          Portfolio ROE
          <UiFootnote
            title="Portfolio ROE"
            text="Return on equity across all borrow positions. Calculated as total net yield divided by total equity (supplied value minus borrowed value)."
            tooltip-placement="bottom-start"
            class="[--ui-footnote-icon-color:var(--c-content-tertiary)]"
          />
        </div>
        <BaseLoadableContent :loading="isConnected && (!isPositionsLoaded || !isBalancesLoaded)">
          <div
            class="text-h5"
            :class="[portfolioRoe >= 0 ? 'text-accent-600' : 'text-error-500']"
          >
            {{ Number.isFinite(portfolioRoe) ? `${formatNumber(portfolioRoe)}%` : '-' }}
          </div>
        </BaseLoadableContent>
      </div>
      <div class="flex justify-between items-center">
        <div class="text-p2 text-content-secondary">
          Net asset value
        </div>
        <BaseLoadableContent :loading="isConnected && (!isPositionsLoaded || !isBalancesLoaded)">
          <div class="flex items-center gap-4 text-h5 text-content-primary">
            {{ (() => {
              const netValue = totalSuppliedValueInfo.total - totalBorrowedValueInfo.total
              const hasMissing = totalSuppliedValueInfo.hasMissingPrices || totalBorrowedValueInfo.hasMissingPrices
              if (netValue === 0 && hasMissing) return '—'
              return formatCompactUsdValue(netValue)
            })() }}
            <UiFootnote
              v-if="(totalSuppliedValueInfo.hasMissingPrices || totalBorrowedValueInfo.hasMissingPrices) && (totalSuppliedValueInfo.total - totalBorrowedValueInfo.total) !== 0"
              title="Incomplete pricing"
              text="Some assets in your portfolio don't have price data available. The displayed value may be higher than shown."
              tooltip-placement="top-end"
            />
          </div>
        </BaseLoadableContent>
      </div>
      <div class="flex justify-between items-center">
        <div class="text-p2 text-content-secondary">
          Total supplied value
        </div>
        <BaseLoadableContent :loading="isConnected && (!isPositionsLoaded || !isBalancesLoaded)">
          <div class="flex items-center gap-4 text-h5 text-content-primary">
            {{ (() => {
              const { total, hasMissingPrices } = totalSuppliedValueInfo
              if (total === 0 && hasMissingPrices) return '—'
              return formatCompactUsdValue(total)
            })() }}
            <UiFootnote
              v-if="totalSuppliedValueInfo.hasMissingPrices && totalSuppliedValueInfo.total !== 0"
              title="Incomplete pricing"
              text="Some supplied assets don't have price data available. The displayed value may be higher than shown."
              tooltip-placement="top-end"
            />
          </div>
        </BaseLoadableContent>
      </div>
      <div class="flex justify-between items-center">
        <div class="text-p2 text-content-secondary">
          Total borrowed value
        </div>
        <BaseLoadableContent :loading="isConnected && (!isPositionsLoaded || !isBalancesLoaded)">
          <div class="flex items-center gap-4 text-h5 text-content-primary">
            {{ (() => {
              const { total, hasMissingPrices } = totalBorrowedValueInfo
              if (total === 0 && hasMissingPrices) return '—'
              return formatCompactUsdValue(total)
            })() }}
            <UiFootnote
              v-if="totalBorrowedValueInfo.hasMissingPrices && totalBorrowedValueInfo.total !== 0"
              title="Incomplete pricing"
              text="Some borrowed assets don't have price data available. The displayed value may be higher than shown."
              tooltip-placement="top-end"
            />
          </div>
        </BaseLoadableContent>
      </div>
    </div>

    <UiTabs
      v-model="tabsModel"
      rounded
      :list="tabs"
    />

    <NuxtPage />
  </section>
</template>
