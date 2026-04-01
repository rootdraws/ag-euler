import { useAccount, useSwitchChain, useWriteContract } from '@wagmi/vue'
import type { Address } from 'viem'
import axios from 'axios'

import { merklDistributorABI } from '~/abis/merkl'
import type { Opportunity, Reward, RewardsResponseItem, RewardToken } from '~/entities/merkl'
import type { RewardCampaign } from '~/entities/reward-campaign'
import { mapMerklSubType } from '~/entities/reward-campaign'
import type { TxPlan } from '~/entities/txPlan'
import { CACHE_TTL_1MIN_MS, POLL_INTERVAL_10S_MS } from '~/entities/tuning-constants'
import { logWarn } from '~/utils/errorHandling'

const {
  MERKL_API_BASE_URL,
} = useEulerConfig()

const endpoints = {
  tokens: `${MERKL_API_BASE_URL}/tokens/reward`,
  opportunities: `${MERKL_API_BASE_URL}/opportunities/campaigns`,
  rewards: (addr: string) => `${MERKL_API_BASE_URL}/users/${addr}/rewards`,
  campaignById: (id: string) => `${MERKL_API_BASE_URL}/campaigns/${id}`,
}

const address = ref('')

const isLoaded = ref(false)
const merklCampaigns: Ref<Map<string, RewardCampaign[]>> = shallowRef(new Map())
const rewards: Ref<Reward[]> = ref([])
const rewardTokens: Ref<RewardToken[]> = ref([])
const isTokensLoading = ref(true)
const isOpportunitiesLoading = ref(true)
const isRewardsLoading = ref(true)

let interval: NodeJS.Timeout | null = null

// Cache state for Merkl data
const cacheState = {
  tokens: { chainId: 0, timestamp: 0 },
  opportunities: { chainId: 0, timestamp: 0 },
  rewards: { chainId: 0, address: '', timestamp: 0 },
}

const loadTokens = async (chainId: number, isInitialLoading = true, forceRefresh = false) => {
  const now = Date.now()
  // Skip if cached and not expired
  if (!forceRefresh
    && cacheState.tokens.chainId === chainId
    && rewardTokens.value.length > 0
    && (now - cacheState.tokens.timestamp) < CACHE_TTL_1MIN_MS) {
    return
  }

  try {
    if (isInitialLoading) {
      isTokensLoading.value = true
    }
    const res = await axios.get(endpoints.tokens)
    const data: RewardToken[] = res.data[chainId]
    rewardTokens.value = data || []
    cacheState.tokens = { chainId, timestamp: Date.now() }
  }
  catch (e) {
    logWarn('merkl/loadTokens', e)
  }
  finally {
    isTokensLoading.value = false
  }
}

const processOpportunitiesToCampaigns = (
  opportunities: Opportunity[],
  opType: 'EULER' | 'ERC20LOGPROCESSOR',
): Map<string, RewardCampaign[]> => {
  const campaignMap = new Map<string, RewardCampaign[]>()
  const now = Math.floor(Date.now() / 1000)

  for (const opportunity of opportunities) {
    if (opportunity.status !== 'LIVE') continue
    if (!opportunity.campaigns?.length) continue
    if (!opportunity.aprRecord?.breakdowns) continue

    // Build APR map from aprRecord breakdowns (keyed by campaign ID)
    // This is the actual computed APR, not the stale campaign.apr field
    const aprs = new Map<string, number>()
    for (const breakdown of opportunity.aprRecord.breakdowns) {
      aprs.set(breakdown.identifier, breakdown.value)
    }

    for (const campaign of opportunity.campaigns) {
      if (campaign.subType === null || campaign.subType === undefined) continue

      const campaignType = mapMerklSubType(campaign.subType)
      if (!campaignType) continue

      if (!campaign.rewardToken || !campaign.params?.targetToken) continue

      const apr = aprs.get(campaign.campaignId) || 0

      // Skip active campaigns with no APR
      if (campaign.endTimestamp > now && !apr) continue

      const vaultAddress = opType === 'ERC20LOGPROCESSOR'
        ? (campaign.params.targetToken).toLowerCase()
        : (campaign.params.evkAddress || campaign.params.targetToken).toLowerCase()

      const collateral = campaignType === 'euler_borrow_collateral'
        ? campaign.params.collateralAddress?.toLowerCase()
        : undefined

      const rewardCampaign: RewardCampaign = {
        vault: vaultAddress,
        collateral,
        type: campaignType,
        apr,
        provider: 'merkl',
        endTimestamp: campaign.endTimestamp,
        rewardToken: { symbol: campaign.rewardToken.symbol, icon: campaign.rewardToken.icon },
      }

      const existing = campaignMap.get(vaultAddress)
      if (existing) existing.push(rewardCampaign)
      else campaignMap.set(vaultAddress, [rewardCampaign])
    }
  }

  return campaignMap
}

const loadOpportunities = async (chainId: number, isInitialLoading = true, forceRefresh = false) => {
  const now = Date.now()
  // Skip if cached and not expired
  if (!forceRefresh
    && cacheState.opportunities.chainId === chainId
    && merklCampaigns.value.size > 0
    && (now - cacheState.opportunities.timestamp) < CACHE_TTL_1MIN_MS) {
    return
  }

  try {
    if (isInitialLoading) {
      isOpportunitiesLoading.value = true
    }

    // Fetch from both endpoints: EULER type for standard vaults and ERC20LOGPROCESSOR for Earn vaults
    const urls = [
      { url: `${MERKL_API_BASE_URL}/opportunities/?chainId=${chainId}&type=EULER&campaigns=true`, type: 'EULER' as const },
      { url: `${MERKL_API_BASE_URL}/opportunities/?chainId=${chainId}&mainProtocolId=euler&campaigns=true&type=ERC20LOGPROCESSOR`, type: 'ERC20LOGPROCESSOR' as const },
    ]

    const results = await Promise.all(
      urls.map(async ({ url, type }) => {
        try {
          const res = await axios.get(url)
          const data: Opportunity[] = Array.isArray(res.data) ? res.data : []
          return { data, type }
        }
        catch (error) {
          logWarn('merkl/fetchOpportunity', error)
          return { data: [] as Opportunity[], type }
        }
      }),
    )

    const merged = new Map<string, RewardCampaign[]>()

    for (const { data, type } of results) {
      const partial = processOpportunitiesToCampaigns(data, type)
      for (const [vault, campaigns] of partial) {
        const existing = merged.get(vault)
        if (existing) existing.push(...campaigns)
        else merged.set(vault, [...campaigns])
      }
    }

    merklCampaigns.value = merged
    cacheState.opportunities = { chainId, timestamp: Date.now() }
  }
  catch (e) {
    logWarn('merkl/loadOpportunities', e)
  }
  finally {
    isOpportunitiesLoading.value = false
  }
}

const loadRewards = async (chainId: number, isInitialLoading = true, forceRefresh = false) => {
  if (!address.value) {
    rewards.value = []
    return
  }

  const now = Date.now()
  // Skip if cached and not expired (check address too since rewards are per-user)
  if (!forceRefresh
    && cacheState.rewards.chainId === chainId
    && cacheState.rewards.address === address.value
    && (now - cacheState.rewards.timestamp) < CACHE_TTL_1MIN_MS) {
    return
  }

  try {
    if (isInitialLoading) {
      isRewardsLoading.value = true
    }
    const res = await axios.get(endpoints.rewards(address.value), {
      params: {
        chainId,
      },
    })

    const data = res.data

    const rewardsList: Reward[] = data
      .reduce((prev: Reward[], curr: RewardsResponseItem) => {
        return [...prev, ...curr.rewards]
      }, [] as Reward[])

    rewards.value = rewardsList.filter(reward => reward.claimed !== reward.amount)
    cacheState.rewards = { chainId, address: address.value, timestamp: Date.now() }
  }
  catch (e) {
    logWarn('merkl/loadRewards', e)
  }
  finally {
    isRewardsLoading.value = false
  }
}

const getMerklCampaignsForVault = (vaultAddress: string): RewardCampaign[] => {
  return merklCampaigns.value.get(vaultAddress.toLowerCase()) || []
}

export const useMerkl = () => {
  const { isConnected, address: wagmiAddress, chain: wagmiChain } = useAccount()
  const { switchChain } = useSwitchChain()
  const { MERKL_ADDRESS } = useEulerConfig()
  const { writeContractAsync } = useWriteContract()
  const { chainId } = useEulerAddresses()

  const ensureWalletOnCurrentChain = async () => {
    const targetChainId = chainId.value
    if (!targetChainId) {
      return
    }

    const walletChainId = wagmiChain.value?.id
    if (walletChainId === targetChainId) {
      return
    }

    await switchChain({ chainId: targetChainId })
  }

  const claimReward = async (reward: Reward) => {
    if (!wagmiAddress.value) {
      throw new Error('Wallet not connected')
    }

    await ensureWalletOnCurrentChain()

    const hash = await writeContractAsync({
      address: MERKL_ADDRESS as Address,
      abi: merklDistributorABI,
      functionName: 'claim',
      args: [
        [wagmiAddress.value],
        [reward.token.address as Address],
        [BigInt(reward.amount)],
        [reward.proofs as Address[]],
      ],
    })

    return hash
  }

  const buildClaimRewardPlan = async (reward: Reward): Promise<TxPlan> => {
    if (!wagmiAddress.value) {
      throw new Error('Wallet not connected')
    }

    return {
      kind: 'reward',
      steps: [
        {
          type: 'other',
          label: 'Claim reward',
          to: MERKL_ADDRESS as Address,
          abi: merklDistributorABI,
          functionName: 'claim',
          args: [
            [wagmiAddress.value],
            [reward.token.address as Address],
            [BigInt(reward.amount)],
            [reward.proofs as Address[]],
          ],
          value: 0n,
        },
      ],
    }
  }

  watch(wagmiAddress, (val) => {
    if (val) {
      address.value = val
    }
    else {
      address.value = ''
    }
  }, { immediate: true })

  watch([isConnected, chainId], (val, oldVal) => {
    if (oldVal[1] && val[1] !== oldVal[1]) {
      isLoaded.value = false
    }

    if (!isLoaded.value) {
      loadOpportunities(chainId.value)
      loadTokens(chainId.value)
      loadRewards(chainId.value)
      isLoaded.value = true
    }

    if (!interval) {
      interval = setInterval(() => {
        loadRewards(chainId.value, false)
        loadOpportunities(chainId.value, false)
        loadTokens(chainId.value, false)
      }, POLL_INTERVAL_10S_MS)
    }
    else {
      if (interval) {
        clearInterval(interval)
        interval = null
      }
    }
  }, { immediate: true })

  onUnmounted(() => {
    if (interval) {
      clearInterval(interval)
      interval = null
    }
  })

  return {
    merklCampaigns,
    rewards,
    rewardTokens,
    isTokensLoading,
    isOpportunitiesLoading,
    isRewardsLoading,
    claimReward,
    buildClaimRewardPlan,
    loadOpportunities,
    loadTokens,
    loadRewards,
    getMerklCampaignsForVault,
  }
}
