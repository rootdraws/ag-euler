export const vaultBorrowAbi = [
  {
    type: 'function',
    name: 'borrow',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultRepayAbi = [
  {
    type: 'function',
    name: 'repay',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultDepositAbi = [
  {
    type: 'function',
    name: 'deposit',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultWithdrawAbi = [
  {
    type: 'function',
    name: 'withdraw',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultRedeemAbi = [
  {
    type: 'function',
    name: 'redeem',
    inputs: [
      { name: 'shares', type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultPreviewWithdrawAbi = [
  {
    type: 'function',
    name: 'previewWithdraw',
    inputs: [{ name: 'assets', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const vaultConvertToAssetsAbi = [
  {
    type: 'function',
    name: 'convertToAssets',
    inputs: [{ name: 'shares', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const vaultConvertToSharesAbi = [
  {
    type: 'function',
    name: 'convertToShares',
    inputs: [{ name: 'assets', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const vaultMaxWithdrawAbi = [
  {
    type: 'function',
    name: 'maxWithdraw',
    inputs: [{ name: 'owner', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const vaultSkimAbi = [
  {
    type: 'function',
    name: 'skim',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultRepayWithSharesAbi = [
  {
    type: 'function',
    name: 'repayWithShares',
    inputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [
      { name: 'shares', type: 'uint256' },
      { name: 'debt', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
] as const

export const vaultPreviewDepositAbi = [
  {
    type: 'function',
    name: 'previewDeposit',
    inputs: [{ name: 'assets', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const

export const vaultTransferFromMaxAbi = [
  {
    type: 'function',
    name: 'transferFromMax',
    inputs: [
      { name: 'from', type: 'address' },
      { name: 'to', type: 'address' },
    ],
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
] as const
