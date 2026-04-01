import { encodeFunctionData, encodeAbiParameters, type Address, type Hex } from 'viem'
import { readContract } from '@wagmi/vue/actions'
import { type SwapApiQuote, type SwapApiVerify, SwapVerificationType } from '~/entities/swap'
import { swapVerifierAbi } from '~/entities/euler/abis'
import { INTEREST_ADJUSTMENT_BPS, BPS_BASE } from '~/entities/tuning-constants'
import { vaultPreviewDepositAbi } from '~/abis/vault'

const erc20DecimalsAbi = [{
  type: 'function' as const,
  name: 'decimals',
  inputs: [],
  outputs: [{ type: 'uint8' }],
  stateMutability: 'view' as const,
}]

const HANDLER_GENERIC: Hex = '0x47656e6572696300000000000000000000000000000000000000000000000000'

const swapFunctionAbi = [{
  type: 'function' as const,
  name: 'swap',
  inputs: [{
    name: 'params',
    type: 'tuple',
    components: [
      { name: 'handler', type: 'bytes32' },
      { name: 'mode', type: 'uint256' },
      { name: 'account', type: 'address' },
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'vaultIn', type: 'address' },
      { name: 'accountIn', type: 'address' },
      { name: 'receiver', type: 'address' },
      { name: 'amountOut', type: 'uint256' },
      { name: 'data', type: 'bytes' },
    ],
  }],
  outputs: [],
  stateMutability: 'nonpayable' as const,
}]

const sweepFunctionAbi = [{
  type: 'function' as const,
  name: 'sweep',
  inputs: [
    { name: 'token', type: 'address' },
    { name: 'amountMin', type: 'uint256' },
    { name: 'to', type: 'address' },
  ],
  outputs: [],
  stateMutability: 'nonpayable' as const,
}]

const repayFunctionAbi = [{
  type: 'function' as const,
  name: 'repay',
  inputs: [
    { name: 'token', type: 'address' },
    { name: 'vault', type: 'address' },
    { name: 'repayAmount', type: 'uint256' },
    { name: 'account', type: 'address' },
  ],
  outputs: [],
  stateMutability: 'nonpayable' as const,
}]

export interface EnsoRouteResponse {
  tx: { to: Address; from: Address; data: Hex; value: string }
  amountOut: string
  minAmountOut: string
  route: Array<{ action: string; protocol: string }>
  gas?: string
}

export interface EnsoSwapQuoteContext {
  swapperAddress: Address
  swapVerifierAddress: Address
  collateralVault: Address
  borrowVault: Address
  subAccount: Address
  tokenIn: Address
  tokenOut: Address
  borrowAmount: bigint
  deadline: number
}

export interface EnsoRepayQuoteContext {
  swapperAddress: Address
  swapVerifierAddress: Address
  collateralVault: Address
  borrowVault: Address
  subAccount: Address
  owner: Address
  tokenIn: Address
  tokenOut: Address
  withdrawAmount: bigint
  currentDebt: bigint
  deadline: number
}

export interface AdapterSwapQuoteContext extends EnsoSwapQuoteContext {
  adapterAddress: Address
  adapterCalldata: Hex
  minAmountOut: bigint
}

export interface BptAdapterConfigEntry {
  adapter: string
  tokenIndex: number
  pool: string
  wrapper: string
  numTokens: number
}

export async function previewAdapterZapIn(
  config: Parameters<typeof readContract>[0],
  entry: BptAdapterConfigEntry,
  inputAmount: bigint,
  slippagePercent: number,
): Promise<{ expectedBptOut: bigint, minBptOut: bigint }> {
  const wrappedAmount = await readContract(config, {
    address: entry.wrapper as Address,
    abi: vaultPreviewDepositAbi,
    functionName: 'previewDeposit',
    args: [inputAmount],
  })

  const wrapperDecimals = await readContract(config, {
    address: entry.wrapper as Address,
    abi: erc20DecimalsAbi,
    functionName: 'decimals',
  }) as number

  // BPT is always 18 decimals. Scale wrappedAmount from wrapper decimals
  // to BPT decimals. This approximates 1 wrapped token ≈ 1 BPT for
  // single-sided deposits. On-chain slippage via minBptOut guards execution.
  const BPT_DECIMALS = 18
  let expectedBptOut: bigint
  if (wrapperDecimals < BPT_DECIMALS) {
    expectedBptOut = wrappedAmount * (10n ** BigInt(BPT_DECIMALS - wrapperDecimals))
  }
  else if (wrapperDecimals > BPT_DECIMALS) {
    expectedBptOut = wrappedAmount / (10n ** BigInt(wrapperDecimals - BPT_DECIMALS))
  }
  else {
    expectedBptOut = wrappedAmount
  }

  const slippageBps = Math.round(slippagePercent * 100)
  const minBptOut = expectedBptOut * BigInt(10000 - slippageBps) / 10000n

  return { expectedBptOut, minBptOut }
}

export const zapInFunctionAbi = [{
  type: 'function' as const,
  name: 'zapIn',
  inputs: [
    { name: 'tokenIndex', type: 'uint256' },
    { name: 'amount', type: 'uint256' },
    { name: 'minBptOut', type: 'uint256' },
  ],
  outputs: [{ name: 'bptOut', type: 'uint256' }],
  stateMutability: 'nonpayable' as const,
}]

export function encodeAdapterZapIn(tokenIndex: number, amount: bigint, minBptOut: bigint): Hex {
  return encodeFunctionData({
    abi: zapInFunctionAbi,
    functionName: 'zapIn',
    args: [BigInt(tokenIndex), amount, minBptOut],
  })
}

export const useEnsoRoute = () => {
  const getEnsoRoute = async (params: {
    chainId: number
    fromAddress: Address
    tokenIn: Address
    tokenOut: Address
    amountIn: bigint
    receiver: Address
    slippage: number
  }): Promise<EnsoRouteResponse> => {
    const query = new URLSearchParams({
      chainId: String(params.chainId),
      fromAddress: params.fromAddress,
      tokenIn: params.tokenIn,
      tokenOut: params.tokenOut,
      amountIn: params.amountIn.toString(),
      receiver: params.receiver,
      slippage: String(Math.round(params.slippage * 100)),
      routingStrategy: 'router',
    })

    const response = await $fetch<string>(`/api/enso/route?${query.toString()}`, {
      method: 'GET',
      responseType: 'text',
    })

    const data = JSON.parse(response)
    if (!data.tx) {
      throw new Error(data.message || 'Enso route failed')
    }
    return data as EnsoRouteResponse
  }

  const buildEnsoSwapQuote = (
    ensoRoute: EnsoRouteResponse,
    ctx: EnsoSwapQuoteContext,
  ): SwapApiQuote => {
    const genericHandlerData = encodeAbiParameters(
      [{ type: 'address' }, { type: 'bytes' }],
      [ensoRoute.tx.to, ensoRoute.tx.data],
    )

    const swapCalldata = encodeFunctionData({
      abi: swapFunctionAbi,
      functionName: 'swap',
      args: [{
        handler: HANDLER_GENERIC,
        mode: 0n, // EXACT_IN
        account: ctx.subAccount,
        tokenIn: ctx.tokenIn,
        tokenOut: ctx.tokenOut,
        vaultIn: ctx.borrowVault,
        accountIn: ctx.subAccount,
        receiver: ctx.swapperAddress,
        amountOut: 0n,
        data: genericHandlerData,
      }],
    })

    const sweepCalldata = encodeFunctionData({
      abi: sweepFunctionAbi,
      functionName: 'sweep',
      args: [ctx.tokenOut, 0n, ctx.collateralVault],
    })

    const minAmountOut = BigInt(ensoRoute.minAmountOut)
    const deadline = ctx.deadline

    const verifierData = encodeFunctionData({
      abi: swapVerifierAbi,
      functionName: 'verifyAmountMinAndSkim',
      args: [ctx.collateralVault, ctx.subAccount, minAmountOut, BigInt(deadline)],
    })

    const verify: SwapApiVerify = {
      verifierAddress: ctx.swapVerifierAddress,
      verifierData,
      type: SwapVerificationType.SkimMin,
      vault: ctx.collateralVault,
      account: ctx.subAccount,
      amount: minAmountOut.toString(),
      deadline,
    }

    const emptyToken = {
      chainId: 0,
      decimals: 18,
      logoURI: '',
      name: '',
      symbol: '',
    }

    return {
      amountIn: ctx.borrowAmount.toString(),
      amountInMax: ctx.borrowAmount.toString(),
      amountOut: ensoRoute.amountOut,
      amountOutMin: ensoRoute.minAmountOut,
      accountIn: ctx.subAccount,
      accountOut: ctx.subAccount,
      vaultIn: ctx.borrowVault,
      receiver: ctx.collateralVault,
      tokenIn: { ...emptyToken, address: ctx.tokenIn },
      tokenOut: { ...emptyToken, address: ctx.tokenOut },
      slippage: 300,
      swap: {
        swapperAddress: ctx.swapperAddress,
        swapperData: '0x' as Hex,
        multicallItems: [
          { functionName: 'swap', args: [], data: swapCalldata },
          { functionName: 'sweep', args: [], data: sweepCalldata },
        ],
      },
      verify,
      route: [{ providerName: 'enso' }],
    }
  }

  const buildEnsoRepaySwapQuote = (
    ensoRoute: EnsoRouteResponse,
    ctx: EnsoRepayQuoteContext,
  ): SwapApiQuote => {
    const genericHandlerData = encodeAbiParameters(
      [{ type: 'address' }, { type: 'bytes' }],
      [ensoRoute.tx.to, ensoRoute.tx.data],
    )

    const swapCalldata = encodeFunctionData({
      abi: swapFunctionAbi,
      functionName: 'swap',
      args: [{
        handler: HANDLER_GENERIC,
        mode: 0n, // EXACT_IN
        account: ctx.subAccount,
        tokenIn: ctx.tokenIn,
        tokenOut: ctx.tokenOut,
        vaultIn: ctx.collateralVault,
        accountIn: ctx.subAccount,
        receiver: ctx.swapperAddress,
        amountOut: 0n,
        data: genericHandlerData,
      }],
    })

    const repayCalldata = encodeFunctionData({
      abi: repayFunctionAbi,
      functionName: 'repay',
      args: [
        ctx.tokenOut,
        ctx.borrowVault,
        BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'), // type(uint256).max
        ctx.subAccount,
      ],
    })

    const sweepCalldata = encodeFunctionData({
      abi: sweepFunctionAbi,
      functionName: 'sweep',
      args: [ctx.tokenOut, 0n, ctx.owner],
    })

    const minAmountOut = BigInt(ensoRoute.minAmountOut)
    let maxDebtAfter = ctx.currentDebt - minAmountOut
    if (maxDebtAfter < 0n) maxDebtAfter = 0n
    const adjustedMaxDebt = (maxDebtAfter * INTEREST_ADJUSTMENT_BPS) / BPS_BASE

    const verifierData = encodeFunctionData({
      abi: swapVerifierAbi,
      functionName: 'verifyDebtMax',
      args: [ctx.borrowVault, ctx.subAccount, adjustedMaxDebt, BigInt(ctx.deadline)],
    })

    const verify: SwapApiVerify = {
      verifierAddress: ctx.swapVerifierAddress,
      verifierData,
      type: SwapVerificationType.DebtMax,
      vault: ctx.borrowVault,
      account: ctx.subAccount,
      amount: adjustedMaxDebt.toString(),
      deadline: ctx.deadline,
    }

    const emptyToken = {
      chainId: 0,
      decimals: 18,
      logoURI: '',
      name: '',
      symbol: '',
    }

    return {
      amountIn: ctx.withdrawAmount.toString(),
      amountInMax: ctx.withdrawAmount.toString(),
      amountOut: ensoRoute.amountOut,
      amountOutMin: ensoRoute.minAmountOut,
      accountIn: ctx.subAccount,
      accountOut: ctx.subAccount,
      vaultIn: ctx.collateralVault,
      receiver: ctx.borrowVault,
      tokenIn: { ...emptyToken, address: ctx.tokenIn },
      tokenOut: { ...emptyToken, address: ctx.tokenOut },
      slippage: 300,
      swap: {
        swapperAddress: ctx.swapperAddress,
        swapperData: '0x' as Hex,
        multicallItems: [
          { functionName: 'swap', args: [], data: swapCalldata },
          { functionName: 'repay', args: [], data: repayCalldata },
          { functionName: 'sweep', args: [], data: sweepCalldata },
        ],
      },
      verify,
      route: [{ providerName: 'enso' }],
    }
  }

  const buildAdapterSwapQuote = (ctx: AdapterSwapQuoteContext): SwapApiQuote => {
    const genericHandlerData = encodeAbiParameters(
      [{ type: 'address' }, { type: 'bytes' }],
      [ctx.adapterAddress, ctx.adapterCalldata],
    )

    const swapCalldata = encodeFunctionData({
      abi: swapFunctionAbi,
      functionName: 'swap',
      args: [{
        handler: HANDLER_GENERIC,
        mode: 0n,
        account: ctx.subAccount,
        tokenIn: ctx.tokenIn,
        tokenOut: ctx.tokenOut,
        vaultIn: ctx.borrowVault,
        accountIn: ctx.subAccount,
        receiver: ctx.swapperAddress,
        amountOut: 0n,
        data: genericHandlerData,
      }],
    })

    const sweepCalldata = encodeFunctionData({
      abi: sweepFunctionAbi,
      functionName: 'sweep',
      args: [ctx.tokenOut, 0n, ctx.collateralVault],
    })

    const verifierData = encodeFunctionData({
      abi: swapVerifierAbi,
      functionName: 'verifyAmountMinAndSkim',
      args: [ctx.collateralVault, ctx.subAccount, ctx.minAmountOut, BigInt(ctx.deadline)],
    })

    const verify: SwapApiVerify = {
      verifierAddress: ctx.swapVerifierAddress,
      verifierData,
      type: SwapVerificationType.SkimMin,
      vault: ctx.collateralVault,
      account: ctx.subAccount,
      amount: ctx.minAmountOut.toString(),
      deadline: ctx.deadline,
    }

    const emptyToken = {
      chainId: 0,
      decimals: 18,
      logoURI: '',
      name: '',
      symbol: '',
    }

    return {
      amountIn: ctx.borrowAmount.toString(),
      amountInMax: ctx.borrowAmount.toString(),
      amountOut: '0',
      amountOutMin: ctx.minAmountOut.toString(),
      accountIn: ctx.subAccount,
      accountOut: ctx.subAccount,
      vaultIn: ctx.borrowVault,
      receiver: ctx.collateralVault,
      tokenIn: { ...emptyToken, address: ctx.tokenIn },
      tokenOut: { ...emptyToken, address: ctx.tokenOut },
      slippage: 300,
      swap: {
        swapperAddress: ctx.swapperAddress,
        swapperData: '0x' as Hex,
        multicallItems: [
          { functionName: 'swap', args: [], data: swapCalldata },
          { functionName: 'sweep', args: [], data: sweepCalldata },
        ],
      },
      verify,
      route: [{ providerName: 'balancer-adapter' }],
    }
  }

  return {
    getEnsoRoute,
    buildEnsoSwapQuote,
    buildEnsoRepaySwapQuote,
    buildAdapterSwapQuote,
  }
}
