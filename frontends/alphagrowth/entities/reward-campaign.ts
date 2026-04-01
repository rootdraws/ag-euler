export type RewardCampaignType = 'euler_lend' | 'euler_borrow' | 'euler_borrow_collateral'

export interface RewardCampaign {
  vault: string
  collateral?: string
  type: RewardCampaignType
  apr: number
  provider: 'merkl' | 'brevis'
  endTimestamp: number
  rewardToken?: {
    symbol: string
    icon: string
  }
}

// Merkl subType is a positional index: 0 = euler_lend, 1 = euler_borrow, 2 = euler_borrow_collateral
const EULER_SUBTYPES: RewardCampaignType[] = ['euler_lend', 'euler_borrow', 'euler_borrow_collateral']

export const mapMerklSubType = (subType: number): RewardCampaignType | null =>
  EULER_SUBTYPES[subType] ?? null
