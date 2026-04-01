import type { RewardCampaign } from '~/entities/reward-campaign'

export const useRewardsApy = () => {
  const { settings } = useUserSettings()
  const { merklCampaigns, getMerklCampaignsForVault } = useMerkl()
  const { brevisCampaigns, getBrevisCampaignsForVault } = useBrevis()

  const isEnabled = computed(() => settings.value.enableRewardsApy)

  // Reactive version counter — bumps when any underlying data or settings change.
  // Consumers should read `version.value` in the sync phase of watchEffect(async)
  // to ensure they re-run when reward data updates.
  const _versionCounter = ref(0)
  watch(
    [isEnabled, merklCampaigns, brevisCampaigns],
    () => { _versionCounter.value++ },
  )
  const version = computed(() => _versionCounter.value)

  const getCampaignsForVault = (vaultAddress: string): RewardCampaign[] => {
    if (!isEnabled.value) return []
    return [
      ...getMerklCampaignsForVault(vaultAddress),
      ...getBrevisCampaignsForVault(vaultAddress),
    ]
  }

  const getSupplyRewardApy = (vaultAddress: string): number => {
    if (!isEnabled.value) return 0
    const campaigns = getCampaignsForVault(vaultAddress)
    return campaigns
      .filter(c => c.type === 'euler_lend')
      .reduce((sum, c) => sum + c.apr, 0)
  }

  const getBorrowRewardApy = (borrowVaultAddress: string, collateralAddress?: string): number => {
    if (!isEnabled.value) return 0
    const campaigns = getCampaignsForVault(borrowVaultAddress)

    let total = 0
    for (const c of campaigns) {
      if (c.type === 'euler_borrow') {
        total += c.apr
      }
      else if (
        c.type === 'euler_borrow_collateral'
        && collateralAddress
        && c.collateral === collateralAddress.toLowerCase()
      ) {
        total += c.apr
      }
    }
    return total
  }

  const hasSupplyRewards = (vaultAddress: string): boolean => {
    return getSupplyRewardApy(vaultAddress) > 0
  }

  const hasBorrowRewards = (borrowVaultAddress: string, collateralAddress?: string): boolean => {
    return getBorrowRewardApy(borrowVaultAddress, collateralAddress) > 0
  }

  const getSupplyRewardCampaigns = (vaultAddress: string): RewardCampaign[] => {
    if (!isEnabled.value) return []
    return getCampaignsForVault(vaultAddress).filter(c => c.type === 'euler_lend')
  }

  const getBorrowRewardCampaigns = (borrowVaultAddress: string, collateralAddress?: string): RewardCampaign[] => {
    if (!isEnabled.value) return []
    return getCampaignsForVault(borrowVaultAddress).filter((c) => {
      if (c.type === 'euler_borrow') return true
      if (
        c.type === 'euler_borrow_collateral'
        && collateralAddress
        && c.collateral === collateralAddress.toLowerCase()
      ) return true
      return false
    })
  }

  return {
    isEnabled,
    version,
    getSupplyRewardApy,
    getBorrowRewardApy,
    hasSupplyRewards,
    hasBorrowRewards,
    getSupplyRewardCampaigns,
    getBorrowRewardCampaigns,
  }
}
