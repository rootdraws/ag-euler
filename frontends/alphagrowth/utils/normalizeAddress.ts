import { getAddress, type Address } from 'viem'

export const normalizeAddress = (address: string): Address => {
  try {
    return getAddress(address)
  }
  catch {
    return address.toLowerCase() as Address
  }
}
