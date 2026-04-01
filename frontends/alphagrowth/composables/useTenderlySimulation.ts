import type { Address, Hex } from 'viem'

interface TenderlySimulateParams {
  chainId: number
  from: Address
  to: Address
  data: Hex
  value: string
  stateOverrides: { address: Address, stateDiff?: { slot: Hex, value: Hex }[] }[]
}

interface TenderlySimulateResponse {
  url: string
}

export const useTenderlySimulation = () => {
  const isSimulating = ref(false)
  const simulationError = ref('')
  const simulationUrl = ref('')

  const clearSimulation = () => {
    simulationError.value = ''
    simulationUrl.value = ''
  }

  const simulate = async (params: TenderlySimulateParams): Promise<string | null> => {
    clearSimulation()
    isSimulating.value = true

    try {
      const response = await $fetch<TenderlySimulateResponse>('/api/tenderly/simulate', {
        method: 'POST',
        body: params,
      })

      simulationUrl.value = response.url
      return response.url
    }
    catch (error: unknown) {
      simulationError.value = error instanceof Error
        ? error.message
        : 'Tenderly simulation failed'
      return null
    }
    finally {
      isSimulating.value = false
    }
  }

  const fetchEnabled = async (): Promise<boolean> => {
    try {
      const { enabled } = await $fetch<{ enabled: boolean }>('/api/tenderly/status')
      return enabled
    }
    catch {
      return false
    }
  }

  return {
    isSimulating,
    simulationError,
    simulationUrl,
    simulate,
    clearSimulation,
    fetchEnabled,
  }
}
