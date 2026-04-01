export const reulWithdrawABI = [
  {
    type: 'function',
    name: 'withdrawToByLockTimestamp',
    inputs: [
      {
        name: 'account',
        type: 'address',
        internalType: 'address',
      },
      {
        name: 'lockTimestamp',
        type: 'uint256',
        internalType: 'uint256',
      },
      {
        name: 'allowRemainderLoss',
        type: 'bool',
        internalType: 'bool',
      },
    ],
    outputs: [
      {
        name: 'success',
        type: 'bool',
        internalType: 'bool',
      },
    ],
    stateMutability: 'nonpayable',
  },
] as const

export const reulLockAbi = [
  {
    type: 'function',
    name: 'getLockedAmounts',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [
      { name: 'timestamps', type: 'uint256[]' },
      { name: 'amounts', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getWithdrawAmountsByLockTimestamp',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'lockTimestamp', type: 'uint256' },
    ],
    outputs: [
      { name: 'unlockableAmount', type: 'uint256' },
      { name: 'amountToBeBurned', type: 'uint256' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'withdrawToByLockTimestamp',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'lockTimestamp', type: 'uint256' },
      { name: 'allowRemainderLoss', type: 'bool' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const
