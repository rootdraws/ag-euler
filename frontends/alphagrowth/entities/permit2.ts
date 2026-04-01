import type { Address } from 'viem'
import { MAX_UINT160, MAX_UINT48, PERMIT2_TYPES } from '~/entities/constants'

export const permit2Abi = [
  {
    type: 'function',
    name: 'allowance',
    inputs: [
      { name: 'owner', type: 'address', internalType: 'address' },
      { name: 'token', type: 'address', internalType: 'address' },
      { name: 'spender', type: 'address', internalType: 'address' },
    ],
    outputs: [
      { name: 'amount', type: 'uint160', internalType: 'uint160' },
      { name: 'expiration', type: 'uint48', internalType: 'uint48' },
      { name: 'nonce', type: 'uint48', internalType: 'uint48' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'permit',
    inputs: [
      { name: 'owner', type: 'address', internalType: 'address' },
      {
        name: 'permitSingle',
        type: 'tuple',
        internalType: 'struct IAllowanceTransfer.PermitSingle',
        components: [
          {
            name: 'details',
            type: 'tuple',
            internalType: 'struct IAllowanceTransfer.PermitDetails',
            components: [
              { name: 'token', type: 'address', internalType: 'address' },
              { name: 'amount', type: 'uint160', internalType: 'uint160' },
              { name: 'expiration', type: 'uint48', internalType: 'uint48' },
              { name: 'nonce', type: 'uint48', internalType: 'uint48' },
            ],
          },
          { name: 'spender', type: 'address', internalType: 'address' },
          { name: 'sigDeadline', type: 'uint256', internalType: 'uint256' },
        ],
      },
      { name: 'signature', type: 'bytes', internalType: 'bytes' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const

export { PERMIT2_TYPES, MAX_UINT48, MAX_UINT160 }

export type Permit2Details = {
  token: Address
  amount: bigint
  expiration: bigint
  nonce: bigint
}

export type Permit2Permit = {
  details: Permit2Details
  spender: Address
  sigDeadline: bigint
}
