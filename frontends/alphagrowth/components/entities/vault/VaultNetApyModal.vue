<script setup lang="ts">
import { DateTime } from 'luxon'
import { formatNumber } from '~/utils/string-utils'
import type { RewardCampaign } from '~/entities/reward-campaign'

const emits = defineEmits(['close'])
const {
  supplyUSD,
  borrowUSD,
  baseSupplyAPY,
  baseBorrowAPY,
  intrinsicSupplyAPY,
  intrinsicBorrowAPY,
  supplyRewardAPY,
  borrowRewardAPY,
  netAPY,
  supplyCampaigns,
  borrowCampaigns,
} = defineProps<{
  supplyUSD: number
  borrowUSD: number
  baseSupplyAPY: number
  baseBorrowAPY: number
  intrinsicSupplyAPY?: number
  intrinsicBorrowAPY?: number
  supplyRewardAPY?: number | null
  borrowRewardAPY?: number | null
  netAPY: number
  supplyCampaigns?: RewardCampaign[]
  borrowCampaigns?: RewardCampaign[]
}>()

const intrinsicApyValue = computed(() => {
  if (supplyUSD === 0) return 0
  const supplyIntrinsic = intrinsicSupplyAPY ?? 0
  const borrowIntrinsic = intrinsicBorrowAPY ?? 0
  const weightedBorrowIntrinsic = (borrowUSD * borrowIntrinsic) / supplyUSD
  return supplyIntrinsic + weightedBorrowIntrinsic
})
const hasIntrinsicApy = computed(() => intrinsicApyValue.value !== 0)

const lendingBorrowingAPY = computed(() => {
  if (supplyUSD === 0) return 0
  const sum = (supplyUSD * baseSupplyAPY) - (borrowUSD * baseBorrowAPY)
  return sum / supplyUSD
})

const rewardsTotalAPY = computed(() => {
  const supplyReward = supplyRewardAPY || 0
  const borrowReward = borrowRewardAPY || 0
  if (supplyUSD === 0) return null
  const weightedRewards = (supplyUSD * supplyReward) + (borrowUSD * borrowReward)
  const totalRewards = weightedRewards / supplyUSD
  return totalRewards > 0 ? totalRewards : null
})

const hasRewards = computed(() => rewardsTotalAPY.value !== null && rewardsTotalAPY.value > 0)

const rewardsInfo = computed(() => {
  const rewards: Array<{
    id: string
    apr: number
    endDate: DateTime
    rewardToken: { symbol: string, icon?: string }
    source: string
    side: string
  }> = []
  const now = Math.floor(Date.now() / 1000)

  if (supplyCampaigns) {
    for (const c of supplyCampaigns) {
      if (c.endTimestamp <= now) continue
      rewards.push({
        id: `supply-${c.vault}-${c.provider}-${c.endTimestamp}`,
        apr: c.apr,
        endDate: DateTime.fromSeconds(c.endTimestamp),
        rewardToken: c.rewardToken || { symbol: 'Unknown', icon: '' },
        source: c.provider,
        side: 'supply',
      })
    }
  }

  if (borrowCampaigns) {
    for (const c of borrowCampaigns) {
      if (c.endTimestamp <= now) continue
      rewards.push({
        id: `borrow-${c.vault}-${c.provider}-${c.type}-${c.collateral || ''}-${c.endTimestamp}`,
        apr: c.apr,
        endDate: DateTime.fromSeconds(c.endTimestamp),
        rewardToken: c.rewardToken || { symbol: 'Unknown', icon: '' },
        source: c.provider,
        side: 'borrow',
      })
    }
  }

  return rewards.sort((a, b) => a.rewardToken.symbol.localeCompare(b.rewardToken.symbol))
})

const handleClose = () => {
  emits('close')
}
</script>

<template>
  <BaseModalWrapper
    title="Combined APY"
    @close="handleClose"
  >
    <div class="mb-24">
      <div class="flex justify-between items-center mb-16">
        <div>
          <p class="mb-4">
            Lending & borrowing APY
          </p>
          <p class="text-euler-dark-900">
            Yield from lending & borrowing on Euler
          </p>
        </div>
        <div class="text-h5">
          {{ formatNumber(lendingBorrowingAPY) }}%
        </div>
      </div>
      <div
        v-if="hasIntrinsicApy"
        class="flex justify-between items-center mb-16"
      >
        <div>
          <p class="mb-4">
            Intrinsic APY
          </p>
          <p class="text-euler-dark-900">
            Yield intrinsic to the supplied asset, such as staking yield or external rewards, might be compounded with lending yield.
          </p>
        </div>
        <div class="flex flex-shrink-0 text-h5">
          - {{ formatNumber(intrinsicApyValue) }}%
        </div>
      </div>
      <div
        v-if="hasRewards"
        class="flex justify-between items-center mb-16"
      >
        <div>
          <p class="mb-4 flex gap-4">
            <SvgIcon
              class="!w-20 !h-20 text-aquamarine-700"
              name="sparks"
            />
            <span>Rewards APY</span>
          </p>
          <p class="text-euler-dark-900">
            Yield from token rewards
          </p>
        </div>
        <div class="flex flex-shrink-0 text-h5">
          + {{ formatNumber(rewardsTotalAPY ?? 0) }}%
        </div>
      </div>
      <div
        v-for="reward in rewardsInfo"
        :key="reward.id"
        class="flex justify-between items-center mb-16"
      >
        <div class="flex">
          <img
            v-if="reward.rewardToken.icon"
            class="w-20 h-20 rounded-full"
            :src="reward.rewardToken.icon"
            alt="Reward token logo"
          >
          <p class="ml-12">
            {{ reward.rewardToken.symbol === 'WTAC' ? 'TAC' : reward.rewardToken.symbol }}
          </p>
          <p class="ml-4 text-euler-dark-900">
            ({{ reward.source === 'brevis' ? 'Brevis, ' : '' }}ends {{ reward.endDate.toFormat('MMMM dd, yyyy') }})
          </p>
        </div>
        <div class="text-p2">
          {{ formatNumber(reward.apr) }}%
        </div>
      </div>
    </div>
    <div class="bg-euler-dark-600 rounded-12 p-16 flex justify-between items-center">
      <p>Net APY</p>
      <p class="text-h4">
        = {{ formatNumber(netAPY) }}%
      </p>
    </div>
  </BaseModalWrapper>
</template>
