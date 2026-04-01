import type { OperationsContext, OperationHelpers } from '../types'
import { createSameAssetSwapBuilders } from './same-asset'
import { createCrossAssetSwapBuilders } from './cross-asset'
import { createSupplyBorrowSwapBuilders } from './supply-borrow'

export const createSwapBuilders = (ctx: OperationsContext, helpers: OperationHelpers) => ({
  ...createSameAssetSwapBuilders(ctx, helpers),
  ...createCrossAssetSwapBuilders(ctx, helpers),
  ...createSupplyBorrowSwapBuilders(ctx, helpers),
})
