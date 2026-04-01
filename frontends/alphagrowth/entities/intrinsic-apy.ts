export interface IntrinsicApyInfo {
  readonly apy: number
  readonly provider: string
  readonly source?: string
}

export const EMPTY_INTRINSIC_APY: IntrinsicApyInfo = { apy: 0, provider: '' }

export interface IntrinsicApyProvider {
  readonly name: string
  fetch(chainId: number): Promise<IntrinsicApyResult[]>
}

export interface IntrinsicApyResult {
  /** Lowercase token address */
  readonly address: string
  readonly info: IntrinsicApyInfo
}
