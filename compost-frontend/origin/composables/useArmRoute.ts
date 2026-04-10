import { encodeFunctionData, encodeAbiParameters, type Address, type Hex } from 'viem'
import { readContract } from '@wagmi/vue/actions'
import { type SwapApiQuote, type SwapApiVerify, SwapVerificationType } from '~/entities/swap'
import { swapVerifierAbi } from '~/entities/euler/abis'
import { armPreviewDepositAbi, armDepositAbi } from '~/abis/arm'

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

export interface ArmSwapQuoteContext {
  swapperAddress: Address
  swapVerifierAddress: Address
  collateralVault: Address
  borrowVault: Address
  subAccount: Address
  tokenIn: Address
  tokenOut: Address
  borrowAmount: bigint
  deadline: number
  armAddress: Address
  minAmountOut: bigint
}

/**
 * Preview an ARM deposit on-chain. Both WETH and ARM-WETH-stETH are 18 decimals,
 * so no decimal scaling is needed (unlike Balancer BPT).
 */
export async function previewArmDeposit(
  config: Parameters<typeof readContract>[0],
  armAddress: Address,
  wethAmount: bigint,
  slippagePercent: number,
): Promise<{ expectedArmOut: bigint, minArmOut: bigint }> {
  const expectedArmOut = await readContract(config, {
    address: armAddress,
    abi: armPreviewDepositAbi,
    functionName: 'previewDeposit',
    args: [wethAmount],
  }) as bigint

  const slippageBps = Math.round(slippagePercent * 100)
  const minArmOut = expectedArmOut * BigInt(10000 - slippageBps) / 10000n

  return { expectedArmOut, minArmOut }
}

export const useArmRoute = () => {
  /**
   * Build a SwapApiQuote that routes WETH -> ARM-WETH-stETH via the Swapper's
   * GenericHandler calling ARM.deposit(wethAmount) directly.
   *
   * GenericHandler flow:
   *   1. Decodes data as (address target, bytes payload)
   *   2. Approves tokenIn (WETH) to target (ARM contract) via setMaxAllowance
   *   3. Calls target.call(payload) -> ARM.deposit(wethAmount)
   *   4. ARM mints shares to msg.sender (the Swapper)
   *   5. sweep() transfers ARM tokens from Swapper to collateral vault
   *   6. verifyAmountMinAndSkim checks balance and skims into vault accounting
   */
  const buildArmSwapQuote = (ctx: ArmSwapQuoteContext): SwapApiQuote => {
    const armDepositCalldata = encodeFunctionData({
      abi: armDepositAbi,
      functionName: 'deposit',
      args: [ctx.borrowAmount],
    })

    const genericHandlerData = encodeAbiParameters(
      [{ type: 'address' }, { type: 'bytes' }],
      [ctx.armAddress, armDepositCalldata],
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
      route: [{ providerName: 'arm-deposit' }],
    }
  }

  return { buildArmSwapQuote }
}
