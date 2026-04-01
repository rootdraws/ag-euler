import { useAccount, useConfig } from '@wagmi/vue'
import { formatUnits, parseUnits, type Address, erc20Abi } from 'viem'
import { sendTransaction, waitForTransactionReceipt, writeContract, readContract } from '@wagmi/vue/actions'
import { useToast } from '~/components/ui/composables/useToast'
import {
  useEnsoRoute,
  previewAdapterZapIn,
  zapInFunctionAbi,
  type BptAdapterConfigEntry,
} from '~/composables/useEnsoRoute'
import { logWarn } from '~/utils/errorHandling'

export interface ZapPool {
  id: string
  name: string
  collateralVault: string
  borrowAsset: string
  borrowAssetSymbol: string
  borrowAssetDecimals: number
  inputTokens: { address: string, symbol: string, decimals: number }[]
  routeType: 'adapter' | 'enso'
  bptAddress: string
}

const POOLS: ZapPool[] = [
  {
    id: 'pool1',
    name: 'Stableswap (USDT0/AUSD/USDC)',
    collateralVault: '0x5795130BFb9232C7500C6E57A96Fdd18bFA60436',
    borrowAsset: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
    borrowAssetSymbol: 'AUSD',
    borrowAssetDecimals: 6,
    inputTokens: [
      { address: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a', symbol: 'AUSD', decimals: 6 },
    ],
    routeType: 'enso',
    bptAddress: '0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b',
  },
  {
    id: 'pool2',
    name: 'sMON/WMON (Kintsu)',
    collateralVault: '0x578c60e6Df60336bE41b316FDE74Aa3E2a4E0Ea5',
    borrowAsset: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A',
    borrowAssetSymbol: 'WMON',
    borrowAssetDecimals: 18,
    inputTokens: [
      { address: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A', symbol: 'WMON', decimals: 18 },
    ],
    routeType: 'enso',
    bptAddress: '0x3475Ea1c3451a9a10Aeb51bd8836312175B88BAc',
  },
  {
    id: 'pool3',
    name: 'shMON/WMON (Fastlane)',
    collateralVault: '0x6660195421557BC6803e875466F99A764ae49Ed7',
    borrowAsset: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A',
    borrowAssetSymbol: 'WMON',
    borrowAssetDecimals: 18,
    inputTokens: [
      { address: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A', symbol: 'WMON', decimals: 18 },
    ],
    routeType: 'enso',
    bptAddress: '0x150360c0eFd098A6426060Ee0Cc4a0444c4b4b68',
  },
  {
    id: 'pool4',
    name: 'AZND/AUSD/LOAZND',
    collateralVault: '0x175831aF06c30F2EA5EA1e3F5EBA207735Eb9F92',
    borrowAsset: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
    borrowAssetSymbol: 'AUSD',
    borrowAssetDecimals: 6,
    inputTokens: [
      { address: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a', symbol: 'AUSD', decimals: 6 },
    ],
    routeType: 'adapter',
    bptAddress: '0xD328E74AdD15Ac98275737a7C1C884ddc951f4D3',
  },
]

export const useZapBpt = () => {
  const wagmiConfig = useConfig()
  const { address, isConnected } = useAccount()
  const { chainId: currentChainId } = useEulerAddresses()
  const { fetchSingleBalance } = useWallets()
  const { slippage } = useSlippage()
  const { bptAdapterConfig } = useDeployConfig()
  const { getEnsoRoute } = useEnsoRoute()
  const { error: showError, success: showSuccess } = useToast()

  const selectedPoolId = ref<string>(POOLS[0].id)
  const inputAmount = ref<string>('')
  const inputTokenAddress = ref<string>('')

  const isQuoting = ref(false)
  const isZapping = ref(false)
  const quoteError = ref<string | null>(null)

  const walletBalance = ref<bigint>(0n)
  const expectedBptFromZap = ref<bigint>(0n)
  const bptReceivedFromZap = ref<bigint>(0n)

  const phase = ref<'input' | 'done'>('input')

  const selectedPool = computed(() => POOLS.find(p => p.id === selectedPoolId.value)!)

  const selectedInputToken = computed(() => {
    const pool = selectedPool.value
    if (!pool) return null
    const token = pool.inputTokens.find(t => t.address === inputTokenAddress.value)
    return token || pool.inputTokens[0]
  })

  watch(selectedPoolId, () => {
    const pool = POOLS.find(p => p.id === selectedPoolId.value)
    if (pool) {
      inputTokenAddress.value = pool.inputTokens[0].address
      inputAmount.value = ''
      resetState()
    }
  }, { immediate: true })

  const inputAmountNano = computed(() => {
    const token = selectedInputToken.value
    if (!token || !inputAmount.value) return 0n
    try {
      return parseUnits(inputAmount.value, token.decimals)
    }
    catch {
      return 0n
    }
  })

  const isInsufficient = computed(() => {
    return inputAmountNano.value > 0n && inputAmountNano.value > walletBalance.value
  })

  const isZapReady = computed(() => {
    return isConnected.value
      && inputAmountNano.value > 0n
      && !isInsufficient.value
      && expectedBptFromZap.value > 0n
      && !quoteError.value
      && phase.value === 'input'
  })

  function resetState() {
    phase.value = 'input'
    expectedBptFromZap.value = 0n
    bptReceivedFromZap.value = 0n
    quoteError.value = null
  }

  async function updateBalance() {
    const token = selectedInputToken.value
    if (!token || !isConnected.value) {
      walletBalance.value = 0n
      return
    }
    walletBalance.value = await fetchSingleBalance(token.address)
  }

  watch([selectedInputToken, isConnected], () => updateBalance(), { immediate: true })

  const fetchZapPreview = useDebounceFn(async () => {
    expectedBptFromZap.value = 0n
    quoteError.value = null

    const pool = selectedPool.value
    const input = inputAmountNano.value
    if (!pool || input <= 0n) return
    if (!currentChainId.value) return

    isQuoting.value = true

    try {
      if (pool.routeType === 'adapter') {
        const adapterEntry = bptAdapterConfig[pool.collateralVault.toLowerCase()]
          || bptAdapterConfig[pool.collateralVault]
        if (!adapterEntry?.pool || !adapterEntry?.wrapper || !adapterEntry?.numTokens) {
          throw new Error('Adapter config missing for this pool')
        }
        const { expectedBptOut } = await previewAdapterZapIn(
          wagmiConfig,
          adapterEntry as BptAdapterConfigEntry,
          input,
          slippage.value,
        )
        expectedBptFromZap.value = expectedBptOut
      }
      else {
        const ensoRoute = await getEnsoRoute({
          chainId: currentChainId.value,
          fromAddress: address.value! as Address,
          tokenIn: pool.borrowAsset as Address,
          tokenOut: pool.bptAddress as Address,
          amountIn: input,
          receiver: address.value! as Address,
          slippage: slippage.value,
        })
        expectedBptFromZap.value = BigInt(ensoRoute.amountOut)
      }
    }
    catch (e: any) {
      quoteError.value = e?.message || 'Failed to get zap preview'
      logWarn('zap-bpt/preview', e)
    }
    finally {
      isQuoting.value = false
    }
  }, 600)

  watch([inputAmountNano, selectedPoolId, slippage], () => {
    if (phase.value !== 'input') return
    if (inputAmountNano.value > 0n) {
      fetchZapPreview()
    }
    else {
      expectedBptFromZap.value = 0n
      quoteError.value = null
    }
  })

  async function executeZapIn() {
    const pool = selectedPool.value
    if (!pool || !address.value) return

    isZapping.value = true

    try {
      const input = inputAmountNano.value
      const userAddr = address.value as Address

      const bptBalanceBefore = await readContract(wagmiConfig, {
        address: pool.bptAddress as Address,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [userAddr],
      })

      if (pool.routeType === 'adapter') {
        const adapterEntry = bptAdapterConfig[pool.collateralVault.toLowerCase()]
          || bptAdapterConfig[pool.collateralVault]
        const fullEntry = adapterEntry as BptAdapterConfigEntry
        const { minBptOut } = await previewAdapterZapIn(wagmiConfig, fullEntry, input, slippage.value)
        const adapterAddr = fullEntry.adapter as Address
        const inputAddr = pool.borrowAsset as Address

        const currentAllowance = await readContract(wagmiConfig, {
          address: inputAddr,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [userAddr, adapterAddr],
        })
        if (currentAllowance < input) {
          const approveHash = await writeContract(wagmiConfig, {
            address: inputAddr,
            abi: erc20Abi,
            functionName: 'approve',
            args: [adapterAddr, input],
          })
          await waitForTransactionReceipt(wagmiConfig, { hash: approveHash })
        }

        const zapHash = await writeContract(wagmiConfig, {
          address: adapterAddr,
          abi: zapInFunctionAbi,
          functionName: 'zapIn',
          args: [BigInt(fullEntry.tokenIndex), input, minBptOut],
        })
        await waitForTransactionReceipt(wagmiConfig, { hash: zapHash })
      }
      else {
        const ensoRoute = await getEnsoRoute({
          chainId: currentChainId.value,
          fromAddress: userAddr,
          tokenIn: pool.borrowAsset as Address,
          tokenOut: pool.bptAddress as Address,
          amountIn: input,
          receiver: userAddr,
          slippage: slippage.value,
        })

        const ensoRouter = ensoRoute.tx.to as Address
        const inputAddr = pool.borrowAsset as Address

        const currentAllowance = await readContract(wagmiConfig, {
          address: inputAddr,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [userAddr, ensoRouter],
        })
        if (currentAllowance < input) {
          const approveHash = await writeContract(wagmiConfig, {
            address: inputAddr,
            abi: erc20Abi,
            functionName: 'approve',
            args: [ensoRouter, input],
          })
          await waitForTransactionReceipt(wagmiConfig, { hash: approveHash })
        }

        const hash = await sendTransaction(wagmiConfig, {
          to: ensoRoute.tx.to,
          data: ensoRoute.tx.data,
          value: BigInt(ensoRoute.tx.value),
        })
        await waitForTransactionReceipt(wagmiConfig, { hash })
      }

      const bptBalanceAfter = await readContract(wagmiConfig, {
        address: pool.bptAddress as Address,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [userAddr],
      })

      bptReceivedFromZap.value = bptBalanceAfter - bptBalanceBefore
      phase.value = 'done'
      showSuccess(`Zap complete — ${formatUnits(bptReceivedFromZap.value, 18)} BPT received`)

      await updateBalance()
    }
    catch (e: any) {
      logWarn('zap-bpt/zap-in', e)
      showError(e?.shortMessage || e?.message || 'Zap failed')
    }
    finally {
      isZapping.value = false
    }
  }

  return {
    pools: POOLS,

    selectedPoolId,
    selectedPool,
    inputAmount,
    inputTokenAddress,
    selectedInputToken,

    inputAmountNano,
    walletBalance,
    expectedBptFromZap,
    bptReceivedFromZap,
    isInsufficient,

    phase,
    isQuoting,
    isZapping,
    quoteError,
    isZapReady,

    executeZapIn,
    updateBalance,
    resetState,
  }
}
