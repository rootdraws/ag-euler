<script setup lang="ts">
import type { MarketGroup } from '~/entities/lend-discovery'
import { nanoToValue } from '~/utils/crypto-utils'
import { getMaxMultiplier, getMaxRoe } from '~/utils/leverage'
import {
  findVault,
  formatMetricValue,
  getCellBgColor,
  isLiquidationLTVRamping,
  getCurrentLiquidationLTV,
  getVaultUtilization,
  type CollateralMatrixData,
  type MatrixCell,
  type DotMetric,
  type EnhancedCellApys,
} from '~/utils/discoveryCalculations'

const props = defineProps<{
  market: MarketGroup
  matrix: CollateralMatrixData
  dotMetric: DotMetric
  selectedCell: { collateralAddr: string, liabilityAddr: string } | null
  selectedHeader: { address: string, axis: 'row' | 'column' } | null
}>()

defineEmits<{
  selectCell: [collateralAddr: string, liabilityAddr: string]
  selectHeader: [address: string, axis: 'row' | 'column']
}>()

const { withIntrinsicSupplyApy, withIntrinsicBorrowApy } = useIntrinsicApy()
const { getBorrowRewardApy, getSupplyRewardApy, hasSupplyRewards, hasBorrowRewards } = useRewardsApy()

const hoveredCell = ref<{
  collateralAddr: string
  liabilityAddr: string
} | null>(null)

const computeEnhancedApys = (cell: MatrixCell, collateralAddr: string, liabilityAddr: string): EnhancedCellApys => {
  const collateral = findVault(props.market, collateralAddr)
  const liability = findVault(props.market, liabilityAddr)

  let supplyApy = 0
  let supplyRewards = 0
  if (collateral) {
    const base = nanoToValue(collateral.interestRateInfo.supplyAPY, 25)
    supplyApy = withIntrinsicSupplyApy(base, collateral.asset.address)
    supplyRewards = getSupplyRewardApy(collateral.address)
  }

  let borrowApy = 0
  let utilization = 0
  let borrowRewards = 0
  if (liability) {
    const base = nanoToValue(liability.interestRateInfo.borrowAPY, 25)
    borrowApy = withIntrinsicBorrowApy(base, liability.asset.address)
    borrowRewards = getBorrowRewardApy(liability.address, collateral?.address)
    utilization = getVaultUtilization(liability)
  }

  const supplyFinal = supplyApy + supplyRewards
  const borrowFinal = borrowApy - borrowRewards
  const netApy = supplyFinal - borrowFinal
  const multiplier = getMaxMultiplier(cell.ltv.borrowLTV)
  const roe = getMaxRoe(multiplier, supplyFinal, borrowFinal)

  return { supplyApy: supplyFinal, borrowApy: borrowFinal, netApy, roe, utilization }
}

const getCellMetricValue = (cell: MatrixCell, collateralAddr: string, liabilityAddr: string): number => {
  switch (props.dotMetric) {
    case 'bltv':
      return Number(nanoToValue(cell.ltv.borrowLTV, 2))
    case 'lltv':
      return Number(nanoToValue(getCurrentLiquidationLTV(cell.ltv), 2))
    case 'multiplier':
      return getMaxMultiplier(cell.ltv.borrowLTV)
    case 'net-apy':
      return computeEnhancedApys(cell, collateralAddr, liabilityAddr).netApy
    case 'roe':
      return computeEnhancedApys(cell, collateralAddr, liabilityAddr).roe
    default:
      return 0
  }
}

const shouldShowSparkles = (collateralAddr: string, liabilityAddr: string): boolean => {
  if (props.dotMetric !== 'net-apy' && props.dotMetric !== 'roe') return false
  const collateral = findVault(props.market, collateralAddr)
  const liability = findVault(props.market, liabilityAddr)
  const hasSupplyRewardsForCell = collateral ? hasSupplyRewards(collateral.address) : false
  const hasBorrowRewardsForCell = liability ? hasBorrowRewards(liability.address, collateral?.address) : false
  return hasSupplyRewardsForCell || hasBorrowRewardsForCell
}

const metricRange = computed((): { min: number, max: number } => {
  let min = Infinity
  let max = -Infinity
  for (const [rowAddr, cols] of props.matrix.cells) {
    for (const [colAddr, cell] of cols) {
      const v = getCellMetricValue(cell, rowAddr, colAddr)
      if (Number.isFinite(v)) {
        if (v < min) min = v
        if (v > max) max = v
      }
    }
  }
  return Number.isFinite(min) ? { min, max } : { min: 0, max: 0 }
})
</script>

<template>
  <div class="px-16 pb-12 flex items-center justify-center">
    <div class="relative max-h-[50vh] overflow-auto rounded-8 border border-line-subtle p-12">
      <table class="border-collapse">
        <thead class="sticky top-0 z-20 bg-surface">
          <tr>
            <th class="text-left text-p5 text-content-muted font-normal py-6 pr-10 pl-6 sticky left-0 bg-surface z-30 border-b border-r border-white/[0.04]">
              <div class="flex flex-col leading-tight">
                <span>Liability &#8594;</span>
                <span>Collateral &#8595;</span>
              </div>
            </th>
            <th
              v-for="col in matrix.columns"
              :key="col.address"
              class="text-center text-p4 font-medium py-6 px-8 whitespace-nowrap border-b border-r border-white/[0.04] cursor-pointer transition-colors"
              :class="selectedHeader?.address === col.address && selectedHeader?.axis === 'column'
                ? 'text-accent-500 !bg-accent-500/10'
                : 'text-content-primary hover:bg-white/[0.04]'"
              @click.stop="$emit('selectHeader', col.address, 'column')"
            >
              <div class="flex flex-col items-center gap-2">
                <AssetAvatar
                  :asset="{ address: col.assetAddress, symbol: col.symbol }"
                  size="16"
                />
                {{ col.symbol }}
              </div>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="row in matrix.rows"
            :key="row.address"
          >
            <td
              class="text-p4 py-6 pr-10 pl-6 whitespace-nowrap sticky left-0 z-10 bg-surface border-b border-r border-white/[0.04] cursor-pointer transition-colors"
              :class="selectedHeader?.address === row.address && selectedHeader?.axis === 'row'
                ? 'text-accent-500 !bg-accent-500/10'
                : row.category === 'external' ? 'text-content-tertiary hover:bg-white/[0.04]' : 'text-content-primary hover:bg-white/[0.04]'"
              @click.stop="$emit('selectHeader', row.address, 'row')"
            >
              <div class="flex items-center gap-4">
                <AssetAvatar
                  class="shrink-0"
                  :asset="{ address: row.assetAddress, symbol: row.symbol }"
                  size="16"
                />
                {{ row.symbol }}
              </div>
            </td>
            <td
              v-for="col in matrix.columns"
              :key="col.address"
              class="text-center py-6 px-8 min-w-[56px] transition-colors border-b border-r border-white/[0.04]"
              :class="[
                selectedCell?.collateralAddr === row.address && selectedCell?.liabilityAddr === col.address
                  ? '!bg-accent-500/20'
                  : row.address === col.address
                    ? 'bg-white/[0.03]'
                    : '',
                matrix.cells.get(row.address)?.get(col.address) ? 'cursor-pointer hover:bg-white/[0.06]' : '',
              ]"
              :style="(() => {
                const cell = matrix.cells.get(row.address)?.get(col.address)
                if (!cell) return undefined
                if (selectedCell?.collateralAddr === row.address && selectedCell?.liabilityAddr === col.address) return undefined
                if (row.address === col.address) return undefined
                const val = getCellMetricValue(cell, row.address, col.address)
                return { backgroundColor: getCellBgColor(val, dotMetric, metricRange.min, metricRange.max) }
              })()"
              @mouseenter="matrix.cells.get(row.address)?.get(col.address) && (hoveredCell = { collateralAddr: row.address, liabilityAddr: col.address })"
              @mouseleave="hoveredCell = null"
              @click.stop="matrix.cells.get(row.address)?.get(col.address) && $emit('selectCell', row.address, col.address)"
            >
              <template v-if="matrix.cells.get(row.address)?.get(col.address)">
                <div class="inline-flex items-center justify-center gap-2">
                  <SvgIcon
                    v-if="dotMetric === 'lltv' && isLiquidationLTVRamping(matrix.cells.get(row.address)!.get(col.address)!.ltv)"
                    name="arrow-top-right"
                    class="!w-10 !h-10 text-warning-500 shrink-0 rotate-180"
                    title="Liquidation LTV ramping down"
                  />
                  <SvgIcon
                    v-if="shouldShowSparkles(row.address, col.address)"
                    name="sparks"
                    class="!w-10 !h-10 text-accent-500 shrink-0"
                  />
                  <span
                    class="text-p5 whitespace-nowrap transition-all"
                    :class="[
                      selectedCell?.collateralAddr === row.address && selectedCell?.liabilityAddr === col.address
                        ? 'text-accent-500 font-semibold'
                        : hoveredCell?.collateralAddr === row.address && hoveredCell?.liabilityAddr === col.address
                          ? 'text-content-primary font-medium'
                          : 'text-content-secondary',
                    ]"
                  >
                    {{ formatMetricValue(getCellMetricValue(matrix.cells.get(row.address)!.get(col.address)!, row.address, col.address), dotMetric) }}
                  </span>
                </div>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <p class="text-p4 text-content-muted text-center leading-relaxed px-16 pb-12">
    Tap a cell, row, or column header to see lending/borrowing options below.
  </p>
</template>
