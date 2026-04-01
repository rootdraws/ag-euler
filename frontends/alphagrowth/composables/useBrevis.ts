import { useAccount, useSwitchChain, useWriteContract } from '@wagmi/vue'
import type { Address } from 'viem'
import axios from 'axios'

import { brevisClaimABI } from '~/abis/brevis'
import type { Campaign, CampaignsRequest, MerkleProofRequest, RewardInfo } from '~/entities/brevis'
import type { RewardCampaign } from '~/entities/reward-campaign'
import type { TxPlan } from '~/entities/txPlan'
import { CampaignAction } from '~/entities/brevis'
import { CACHE_TTL_1MIN_MS, POLL_INTERVAL_10S_MS } from '~/entities/tuning-constants'
import { logWarn } from '~/utils/errorHandling'

const ACTION_MAP: Record<string, CampaignAction> = {
  EULER_BORROW: CampaignAction.BORROW,
  EULER_LEND: CampaignAction.LEND,
}

// Brevis API may return camelCase or snake_case — normalize to snake_case
const normalizeRewardInfo = (raw: Record<string, unknown>): RewardInfo => ({
  submission_chain_id: (raw.submission_chain_id ?? raw.submissionChainId ?? 0) as number,
  submission_contract: (raw.submission_contract ?? raw.submissionContract ?? '') as string,
  claim_chain_id: (raw.claim_chain_id ?? raw.claimChainId ?? 0) as number,
  claim_contract: (raw.claim_contract ?? raw.claimContract ?? '') as string,
  token_address: (raw.token_address ?? raw.tokenAddress ?? '') as string,
  token_symbol: (raw.token_symbol ?? raw.tokenSymbol ?? '') as string,
  reward_amt: (raw.reward_amt ?? raw.rewardAmt ?? '0') as string,
  reward_usd_price: (raw.reward_usd_price ?? raw.rewardUsdPrice ?? '0') as string,
  reward_per_hour: (raw.reward_per_hour ?? raw.rewardPerHour ?? '0') as string,
  apr: (raw.apr ?? 0) as number,
  tvl: (raw.tvl ?? 0) as number,
})

const normalizeCampaign = (raw: Record<string, unknown>): Campaign => {
  const rawAction = raw.action
  const action = typeof rawAction === 'number'
    ? rawAction as CampaignAction
    : ACTION_MAP[rawAction as string] ?? CampaignAction.LEND

  const rawReward = (raw.reward_info ?? raw.rewardInfo ?? {}) as Record<string, unknown>

  return {
    chain_id: (raw.chain_id ?? raw.chainId ?? 0) as number,
    vault_address: (raw.vault_address ?? raw.vaultAddress ?? '') as string,
    action,
    campaign_id: (raw.campaign_id ?? raw.campaignId ?? '') as string,
    campaign_name: (raw.campaign_name ?? raw.campaignName ?? '') as string,
    start_time: (raw.start_time ?? raw.startTime ?? 0) as number,
    end_time: (raw.end_time ?? raw.endTime ?? 0) as number,
    reward_info: normalizeRewardInfo(rawReward),
    last_reward_attestation_time: (raw.last_reward_attestation_time ?? raw.lastRewardAttestationTime ?? 0) as number,
    status: (raw.status ?? 0) as number,
  }
}

const address = ref('')

const isLoaded = ref(false)
const brevisCampaigns: Ref<Map<string, RewardCampaign[]>> = shallowRef(new Map())
const userRewards: Ref<Campaign[]> = ref([])
const isCampaignsLoading = ref(true)
const isRewardsLoading = ref(true)

let interval: NodeJS.Timeout | null = null

const cacheState = {
  campaigns: { timestamp: 0 },
  rewards: { timestamp: 0, address: '' },
}

const getBrevisCampaignsForVault = (vaultAddress: string): RewardCampaign[] => {
  return brevisCampaigns.value.get(vaultAddress.toLowerCase()) || []
}

export const useBrevis = () => {
  const { isConnected, address: wagmiAddress, chain: wagmiChain } = useAccount()
  const { switchChain } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const { BREVIS_API_URL, BREVIS_MERKLE_PROOF_URL } = useEulerConfig()
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

  const loadCampaigns = async (isInitialLoading = true, forceRefresh = false) => {
    try {
      const now = Date.now()
      if (!forceRefresh
        && brevisCampaigns.value.size > 0
        && (now - cacheState.campaigns.timestamp) < CACHE_TTL_1MIN_MS) {
        return
      }

      if (isInitialLoading) {
        isCampaignsLoading.value = true
      }

      const request: CampaignsRequest = {
        chain_id: [1],
        action: [CampaignAction.LEND, CampaignAction.BORROW],
        status: [3],
      }

      const res = await axios.post(BREVIS_API_URL, request)

      if (res.data.err) {
        logWarn('brevis/campaigns', res.data.err)
        return
      }

      const campaigns: Campaign[] = (res.data.campaigns || []).map(normalizeCampaign)
      const campaignMap = new Map<string, RewardCampaign[]>()

      for (const campaign of campaigns) {
        const vaultKey = campaign.vault_address.toLowerCase()
        const rewardCampaign: RewardCampaign = {
          vault: vaultKey,
          // TODO: Add 'euler_borrow_collateral' support if Brevis adds collateral-specific campaigns
          type: campaign.action === CampaignAction.LEND ? 'euler_lend' : 'euler_borrow',
          apr: campaign.reward_info.apr * 100,
          provider: 'brevis',
          endTimestamp: campaign.end_time,
          rewardToken: {
            symbol: campaign.reward_info.token_symbol,
            icon: '',
          },
        }

        const existing = campaignMap.get(vaultKey)
        if (existing) existing.push(rewardCampaign)
        else campaignMap.set(vaultKey, [rewardCampaign])
      }

      brevisCampaigns.value = campaignMap
      cacheState.campaigns.timestamp = Date.now()
    }
    catch (e) {
      logWarn('brevis/campaigns', e)
    }
    finally {
      isCampaignsLoading.value = false
    }
  }

  const loadRewards = async (isInitialLoading = true, forceRefresh = false) => {
    try {
      if (!address.value) {
        userRewards.value = []
        return
      }

      const now = Date.now()
      if (!forceRefresh
        && cacheState.rewards.address === address.value
        && userRewards.value.length > 0
        && (now - cacheState.rewards.timestamp) < CACHE_TTL_1MIN_MS) {
        return
      }

      if (isInitialLoading) {
        isRewardsLoading.value = true
      }

      const request: CampaignsRequest = {
        chain_id: [1],
        user_address: [address.value],
        status: [3, 4],
      }

      const res = await axios.post(BREVIS_API_URL, request)

      if (res.data.err) {
        logWarn('brevis/rewards', res.data.err)
        return
      }

      userRewards.value = (res.data.campaigns || []).map(normalizeCampaign)
      cacheState.rewards.timestamp = Date.now()
      cacheState.rewards.address = address.value
    }
    catch (e) {
      logWarn('brevis/allocations', e)
    }
    finally {
      isRewardsLoading.value = false
    }
  }

  const claimReward = async (campaign: Campaign) => {
    if (!wagmiAddress.value) {
      throw new Error('Wallet not connected')
    }

    await ensureWalletOnCurrentChain()

    const request: MerkleProofRequest = {
      user_addr: wagmiAddress.value,
      campaign_id: [campaign.campaign_id],
      chain_id: [campaign.chain_id],
    }

    const res = await axios.post(BREVIS_MERKLE_PROOF_URL, request)

    if (res.data.err) {
      throw new Error(res.data.err.msg || 'Failed to fetch merkle proof')
    }

    const rewardsBatch = res.data.rewardsBatch
    if (!rewardsBatch || rewardsBatch.length === 0) {
      throw new Error('No claimable rewards found')
    }

    const merkleData = rewardsBatch[0]

    const hash = await writeContractAsync({
      address: merkleData.claimContractAddr as Address,
      abi: brevisClaimABI,
      functionName: 'claim',
      args: [
        wagmiAddress.value,
        merkleData.cumulativeRewards.map((r: string) => BigInt(r)),
        BigInt(merkleData.epoch),
        merkleData.merkleProof as Address[],
      ],
    })

    return hash
  }

  const buildClaimRewardPlan = async (campaign: Campaign): Promise<TxPlan> => {
    if (!wagmiAddress.value) {
      throw new Error('Wallet not connected')
    }

    const request: MerkleProofRequest = {
      user_addr: wagmiAddress.value,
      campaign_id: [campaign.campaign_id],
      chain_id: [campaign.chain_id],
    }

    const res = await axios.post(BREVIS_MERKLE_PROOF_URL, request)

    if (res.data.err) {
      throw new Error(res.data.err.msg || 'Failed to fetch merkle proof')
    }

    const rewardsBatch = res.data.rewardsBatch
    if (!rewardsBatch || rewardsBatch.length === 0) {
      throw new Error('No claimable rewards found')
    }

    const merkleData = rewardsBatch[0]

    return {
      kind: 'brevis-reward',
      steps: [
        {
          type: 'other',
          label: 'Claim reward',
          to: merkleData.claimContractAddr as Address,
          abi: brevisClaimABI,
          functionName: 'claim',
          args: [
            wagmiAddress.value,
            merkleData.cumulativeRewards.map((r: string) => BigInt(r)),
            BigInt(merkleData.epoch),
            merkleData.merkleProof as Address[],
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

  watch(isConnected, (connected) => {
    if (connected) {
      if (!isLoaded.value) {
        loadCampaigns()
        loadRewards()
        isLoaded.value = true
      }

      if (!interval) {
        interval = setInterval(() => {
          loadRewards(false)
          loadCampaigns(false)
        }, POLL_INTERVAL_10S_MS)
      }
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
    brevisCampaigns,
    userRewards,
    isCampaignsLoading,
    isRewardsLoading,
    loadCampaigns,
    loadRewards,
    claimReward,
    buildClaimRewardPlan,
    getBrevisCampaignsForVault,
  }
}
