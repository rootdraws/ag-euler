export const tosSignerReadAbi = [
  {
    type: 'function',
    name: 'lastTermsOfUseSignatureTimestamp',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'termsOfUseHash', type: 'bytes32' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const tosSignerWriteAbi = [
  {
    type: 'function',
    name: 'signTermsOfUse',
    inputs: [
      { name: 'message', type: 'string' },
      { name: 'messageHash', type: 'bytes32' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const
