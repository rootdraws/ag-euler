export const PYTH_ABI = [
  {
    type: 'function',
    name: 'getUpdateFee',
    inputs: [{ name: 'updateData', type: 'bytes[]' }],
    outputs: [{ name: 'feeAmount', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'updatePriceFeeds',
    inputs: [{ name: 'updateData', type: 'bytes[]' }],
    outputs: [],
    stateMutability: 'payable',
  },
] as const
