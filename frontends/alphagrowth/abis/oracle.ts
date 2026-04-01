export const priceOracleAbi = [
  {
    type: 'function',
    name: 'getQuote',
    inputs: [
      { name: 'inAmount', type: 'uint256' },
      { name: 'base', type: 'address' },
      { name: 'quote', type: 'address' },
    ],
    outputs: [{ name: 'outAmount', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const
