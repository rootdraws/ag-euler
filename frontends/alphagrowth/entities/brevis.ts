export enum CampaignStatus {
  DEPLOYING = 0,
  CREATING_FAILED = 1,
  INACTIVE = 2,
  ACTIVE = 3,
  ENDED = 4,
  DEACTIVATED = 5,
}

export enum CampaignAction {
  BORROW = 2001,
  LEND = 2002,
}

export interface RewardInfo {
  submission_chain_id: number
  submission_contract: string
  claim_chain_id: number
  claim_contract: string
  token_address: string
  token_symbol: string
  reward_amt: string
  reward_usd_price: string
  reward_per_hour: string
  apr: number
  tvl: number
}

export interface Campaign {
  chain_id: number
  vault_address: string
  action: CampaignAction
  campaign_id: string
  campaign_name: string
  start_time: number
  end_time: number
  reward_info: RewardInfo
  last_reward_attestation_time: number
  status: CampaignStatus
}

export interface CampaignsRequest {
  chain_id?: number[]
  vault_address?: string[]
  action?: CampaignAction[]
  campaign_id?: string[]
  status?: CampaignStatus[]
  user_address?: string[]
}

export interface CampaignsResponse {
  err?: {
    code: number
    msg: string
  }
  campaigns: Campaign[]
}

export interface MerkleProofRequest {
  user_addr: string
  types?: number[]
  chain_id?: number[]
  status?: number[]
  campaign_id?: string[]
}

export interface SingleCampaignMerkle {
  campaignId: string
  epoch: string
  claimChainId: string
  claimContractAddr: string
  cumulativeRewards: string[]
  merkleProof: string[]
  claimableRewards: string
}

export interface MerkleProofResponse {
  err?: {
    code: string
    msg: string
  }
  rewardsBatch: SingleCampaignMerkle[]
}
