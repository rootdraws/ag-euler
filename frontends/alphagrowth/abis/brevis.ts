export const brevisClaimABI = [
  {
    type: 'function',
    name: 'claim',
    inputs: [
      {
        name: 'earner',
        type: 'address',
        internalType: 'address',
      },
      {
        name: 'cumulativeAmounts',
        type: 'uint256[]',
        internalType: 'uint256[]',
      },
      {
        name: 'epoch',
        type: 'uint64',
        internalType: 'uint64',
      },
      {
        name: 'proof',
        type: 'bytes32[]',
        internalType: 'bytes32[]',
      },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const
