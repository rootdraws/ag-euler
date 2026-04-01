export const merklDistributorABI = [
  {
    type: 'function',
    name: 'claim',
    inputs: [
      {
        name: 'users',
        type: 'address[]',
        internalType: 'address[]',
      },
      {
        name: 'tokens',
        type: 'address[]',
        internalType: 'address[]',
      },
      {
        name: 'amounts',
        type: 'uint256[]',
        internalType: 'uint256[]',
      },
      {
        name: 'proofs',
        type: 'bytes32[][]',
        internalType: 'bytes32[][]',
      },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const
