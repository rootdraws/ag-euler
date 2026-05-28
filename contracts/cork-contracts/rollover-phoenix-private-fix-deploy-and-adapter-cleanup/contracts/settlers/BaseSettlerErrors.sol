// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Sentinel reverted by every PR 2 stub external. Replaced by real implementations in
///         PR 3 (ERC6909Premium), PR 4b (BaseSettler), PR 4c (ExactFillSettler), and PR 4d
///         (PartialFillSettler).
error NotImplemented();

error InvalidDestination();
error UnauthorizedDebitFrom();
error WrongOriginSettler();
error WrongOriginChain();
error OpenDeadlinePassed();
error CellarNotBound();
error DisproportionateOutput();

/// @notice `PartialFillSettler.finaliseAsSettled` was invoked with an empty `fillers[]` array.
///         Rejecting the call closes a griefing path (Pashov A1): a zero-length call used to
///         succeed as a no-op but advanced no state, meaning any caller could spam the function
///         on an opened order. Now every finalise batch must name at least one filler.
error InvalidFillers();

/// @notice Cellar returned `actualRolled == 0` from `executeIntentHooks` — slot-squat
///         defense-in-depth. Shared across Partial and Exact settlers (Pashov A6). Same selector
///         as the legacy `IPartialFillSettler.ZeroRollover` declaration — off-chain consumers
///         can match either.
error ZeroRollover();

/// @notice `fill` was invoked by a caller other than `OrderData.exclusiveFiller` on an order
///         that restricts filling to a single address (AS-21 ingress gate, RFC 003 §6.2). The
///         gate is skipped when `exclusiveFiller == address(0)`.
error NotExclusiveFiller();

/// @notice A leg's `output.amount` is below `OrderData.minFillSize` (AS-19 ingress gate,
///         RFC 003 §6.2). Blocks dust fragmentation across both legs and both settler variants.
///         The gate is skipped when `minFillSize == 0`.
error BelowMinFillSize();

/// @notice A rollover-leg `fillAmount` fails the per-fill decimal-precision check
///         `fillAmount % (10 ** decimalOffset) != 0`, where
///         `decimalOffset = 18 - IERC20(od.srcCstToken).decimals()` (AS-20 decimal-truncation
///         gate, RFC 003 §6.2). Guards against silent-dust truncation inside the source pool.
///         The gate is a no-op when `decimalOffset == 0`. Applies to the rollover leg only.
error DecimalTruncates();

/// @notice A partial-path rollover fill would leave residual capacity `0 < r < minFillSize`,
///         so any follow-up fill against the order would itself be dust (AS-22 residual-
///         truncation gate). AS-22 is a plan extension — NOT part of RFC §6.2 — that solves a
///         distinct failure mode (unfillable residual) from RFC's AS-20 decimal check. Applies
///         only to the partial settler's rollover leg; the exact settler bypasses it because
///         it permits exactly one fill per order. The gate is skipped when `minFillSize == 0`.
error ResidualTruncates();

/// @notice `rescueSettled` was invoked for a `(orderKey, filler)` pair whose `_rescueable`
///         credit is zero. Either the payout never reverted or a prior `rescueSettled` call has
///         already consumed the slot — the CEI zeroing on the withdrawal path makes
///         sig-replay a no-op revert rather than a silent double-spend (PR 6 / closes #44).
error NothingToRescue();

/// @notice `rescueSettled` received a signature that did not recover to the `filler` argument
///         under the settler's EIP-712 domain over `(orderDigest, orderId, fallbackDestination)`.
///         The function is permissionless — authorisation is the filler's own typed-data
///         signature, so a bad or foreign signature must revert (PR 6 / closes #44).
error InvalidRescueSignature();

/// @notice Settler-cellar state parity check failed on the premium leg (#61 / I4). After a
///         successful `executeIntentHooks(phase=1)` forward, the cellar MUST have latched
///         `premiumFiredFor[orderDigest][targetFiller] = true`. If the view returns `false`,
///         settler and cellar state have diverged — either the hook body bypassed the latch via
///         a masquerading cellar or the forward silently no-opped. Reverting here stops the
///         settler from committing its own premium-settled latch on top of a cellar that never
///         latched, preserving the phase-1 invariant used by off-chain consumers.
error StateDivergence();

/// @notice The settler's dstCST balance dropped below the per-order escrow floor after the
///         `finaliseAsSettled` payout loop (#46 / M2). The check is
///         `balanceOf(settler) >= totalDstCstEscrowed` (the residual escrow for other fillers'
///         unfinalised slots on Partial; zero on Exact). Catches silent-siphon refactors where a
///         future change lets dstCST leak out of the settler before the remaining escrow is
///         honoured. Attacker-influenceable inputs in the payout path (blacklist tokens, ERC-20
///         hooks) cannot cross this floor because the catch branch routes to `_rescueable`
///         instead of transferring.
/// @param observed Settler's live `dstCST.balanceOf` after the payout loop.
/// @param floor Required minimum — the order's remaining `totalDstCstEscrowed` post-batch.
error BalanceFloorViolated(uint256 observed, uint256 floor);
