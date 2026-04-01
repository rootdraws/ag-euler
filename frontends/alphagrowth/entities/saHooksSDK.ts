import { encodeFunctionData, encodeAbiParameters, zeroAddress, type Abi } from 'viem'

export interface PreHook {
  isFromSAPerspective: boolean
  contractAddress: string
  value: bigint
  data: string
}

export interface PostHook {
  isFromSAPerspective: boolean
  contractAddress: string
  value: bigint
  data: string
}

export interface MainCallHook {
  isFromSAPerspective: boolean
  contractAddress: string
  value: bigint
  data: string
}

export interface NFTBridgeHook {
  tokenAddress: string
  tokenId: bigint
  amount: bigint
}

export interface TokenBridgeHook {
  tokenAddress: string
}

export interface SaHooks {
  preHooks: PreHook[]
  postHooks: PostHook[]
  mainCallHook: MainCallHook
}

const hookTupleType = {
  type: 'tuple',
  components: [
    { name: 'isFromSAPerspective', type: 'bool' },
    { name: 'contractAddress', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'data', type: 'bytes' },
  ],
} as const

const saHooksAbiParameters = [
  {
    type: 'tuple',
    components: [
      { name: 'preHooks', type: 'tuple[]', components: hookTupleType.components },
      { name: 'postHooks', type: 'tuple[]', components: hookTupleType.components },
      { name: 'mainCallHook', type: 'tuple', components: hookTupleType.components },
    ],
  },
] as const

export class SaHooksBuilder {
  private hooks: SaHooks
  private contractAbis: { [address: string]: Abi }

  constructor() {
    this.hooks = {
      preHooks: [],
      postHooks: [],
      mainCallHook: {
        isFromSAPerspective: false,
        contractAddress: zeroAddress,
        value: 0n,
        data: '0x',
      },
    }
    this.contractAbis = {}
  }

  public addContractInterface(address: string, abi: Abi | readonly unknown[]): SaHooksBuilder {
    this.contractAbis[address] = abi as Abi
    return this
  }

  private encodeFunctionCall(
    address: string,
    functionName: string,
    params: unknown[],
  ): string {
    if (!this.contractAbis[address]) {
      throw new Error(`No interface found for contract at ${address}`)
    }
    return encodeFunctionData({
      abi: this.contractAbis[address],
      functionName,
      args: params,
    })
  }

  // Pre-hooks methods
  private addPreHook(hook: PreHook): SaHooksBuilder {
    this.hooks.preHooks.push(hook)
    return this
  }

  private addPreHookFromSA(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.addPreHook({
      isFromSAPerspective: true,
      contractAddress,
      value,
      data,
    })
  }

  private addPreHookFromSelf(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.addPreHook({
      isFromSAPerspective: false,
      contractAddress,
      value,
      data,
    })
  }

  addPreHookCallFromSA(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.addPreHookFromSA(contractAddress, value, data)
  }

  addPreHookCallFromSelf(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.addPreHookFromSelf(contractAddress, value, data)
  }

  // Post-hooks methods
  private addPostHook(hook: PostHook): SaHooksBuilder {
    this.hooks.postHooks.push(hook)
    return this
  }

  private addPostHookFromSA(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.addPostHook({
      isFromSAPerspective: true,
      contractAddress,
      value,
      data,
    })
  }

  private addPostHookFromSelf(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.addPostHook({
      isFromSAPerspective: false,
      contractAddress,
      value,
      data,
    })
  }

  addPostHookCallFromSA(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.addPostHookFromSA(contractAddress, value, data)
  }

  addPostHookCallFromSelf(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.addPostHookFromSelf(contractAddress, value, data)
  }

  getDataForCall(contractAddress: string, functionName: string, params: unknown[]): string {
    return this.encodeFunctionCall(contractAddress, functionName, params)
  }

  // Main call hook methods
  private setMainCallHook(hook: MainCallHook): SaHooksBuilder {
    this.hooks.mainCallHook = hook
    return this
  }

  private setMainCallHookFromSA(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.setMainCallHook({
      isFromSAPerspective: true,
      contractAddress,
      value,
      data,
    })
  }

  private setMainCallHookFromSelf(contractAddress: string, value: bigint, data: string): SaHooksBuilder {
    return this.setMainCallHook({
      isFromSAPerspective: false,
      contractAddress,
      value,
      data,
    })
  }

  setMainCallHookCallFromSA(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.setMainCallHookFromSA(contractAddress, value, data)
  }

  setMainCallHookCallFromSelf(
    contractAddress: string,
    functionName: string,
    params: unknown[],
    value: bigint = 0n,
  ): SaHooksBuilder {
    const data = this.encodeFunctionCall(contractAddress, functionName, params)
    return this.setMainCallHookFromSelf(contractAddress, value, data)
  }

  // Helper methods for common operations
  addApprovePreHook(tokenAddress: string, spenderAddress: string, amount: bigint): SaHooksBuilder {
    return this.addPreHookCallFromSA(
      tokenAddress,
      'approve',
      [spenderAddress, amount],
    )
  }

  addTransferPreHook(tokenAddress: string, toAddress: string, amount: bigint): SaHooksBuilder {
    return this.addPreHookCallFromSA(
      tokenAddress,
      'transfer',
      [toAddress, amount],
    )
  }

  addApprovePostHook(tokenAddress: string, spenderAddress: string, amount: bigint): SaHooksBuilder {
    return this.addPostHookCallFromSelf(
      tokenAddress,
      'approve',
      [spenderAddress, amount],
    )
  }

  addTransferPostHook(tokenAddress: string, toAddress: string, amount: bigint): SaHooksBuilder {
    return this.addPostHookCallFromSelf(
      tokenAddress,
      'transfer',
      [toAddress, amount],
    )
  }

  // Build and encode methods
  build(): SaHooks {
    return this.hooks
  }

  encode(): string {
    return encodeAbiParameters(
      saHooksAbiParameters,
      [this.hooks as any],
    )
  }

  tupleString(): string {
    return 'tuple('
      + 'tuple(bool isFromSAPerspective, address contractAddress, uint256 value, bytes data)[] preHooks,'
      + 'tuple(bool isFromSAPerspective, address contractAddress, uint256 value, bytes data)[] postHooks,'
      + 'tuple(bool isFromSAPerspective, address contractAddress, uint256 value, bytes data) mainCallHook'
      + ')'
  }

  bridgeString(): string {
    return 'tuple(address[])'
  }
}
