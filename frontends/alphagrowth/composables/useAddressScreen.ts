import { useDisconnect } from '@wagmi/vue'
import { useModal } from '~/components/ui/composables/useModal'
import { BlockedAddressModal } from '#components'
import { detectVpn, resetVpnCache } from '~/services/vpn'
import { resetCountryCache } from '~/services/country'
import { screenAddress } from '~/services/trm'
import { getDefaultPageRoute } from '~/entities/menu'

// Track last screened address to avoid duplicate API calls
let lastScreenedAddress: string | null = null

export const useAddressScreen = () => {
  const modal = useModal()
  const { disconnect } = useDisconnect()
  const router = useRouter()

  const { enableEarnPage, enableLendPage, enableExplorePage } = useDeployConfig()
  const defaultPageRoute = getDefaultPageRoute(enableEarnPage, enableLendPage, enableExplorePage)
  const blockedAddress = ref<string | null>(null)
  const isScreening = ref(false)

  const showBlockedModal = (address: string) => {
    blockedAddress.value = address
    modal.open(BlockedAddressModal, {
      props: {
        address,
        onClose: () => {
          modal.close()
          blockedAddress.value = null
          router.push({ name: defaultPageRoute })
        },
      },
    })
  }

  const screenConnectedAddress = async (address: string): Promise<boolean> => {
    if (!address) {
      return false
    }

    if (lastScreenedAddress === address.toLowerCase()) {
      return false
    }

    isScreening.value = true
    try {
      const vpnIsUsed = await detectVpn()
      const isRestricted = await screenAddress(address, vpnIsUsed)

      lastScreenedAddress = address.toLowerCase()

      if (isRestricted) {
        await disconnect()
        showBlockedModal(address)
        return true
      }
      return false
    }
    finally {
      isScreening.value = false
    }
  }

  const resetScreeningCache = () => {
    lastScreenedAddress = null
    resetVpnCache()
    resetCountryCache()
  }

  return {
    isScreening,
    blockedAddress,
    screenConnectedAddress,
    resetScreeningCache,
  }
}
