<script setup lang="ts">
import { formatUnits } from 'viem'
import { useZapBpt } from '~/composables/useLoopZap'

defineOptions({ name: 'ZapBptPage' })

const {
  pools,
  selectedPoolId,
  selectedPool,
  inputAmount,
  selectedInputToken,
  inputAmountNano,
  walletBalance,
  expectedBptFromZap,
  bptReceivedFromZap,
  isInsufficient,
  phase,
  isQuoting,
  isZapping,
  quoteError,
  isZapReady,
  executeZapIn,
  resetState,
} = useZapBpt()

const { isConnected } = useWagmi()

function trimDecimals(raw: string, maxDecimals: number): string {
  const [int, frac] = raw.split('.')
  if (!frac) return int
  const trimmed = frac.slice(0, maxDecimals).replace(/0+$/, '')
  return trimmed ? `${int}.${trimmed}` : int
}

const walletBalanceFormatted = computed(() => {
  const token = selectedInputToken.value
  if (!token || walletBalance.value <= 0n) return '0'
  return trimDecimals(formatUnits(walletBalance.value, token.decimals), 6)
})

const expectedBptFormatted = computed(() => {
  if (expectedBptFromZap.value <= 0n) return '0'
  return trimDecimals(formatUnits(expectedBptFromZap.value, 18), 6)
})

const bptReceivedFormatted = computed(() => {
  if (bptReceivedFromZap.value <= 0n) return '0'
  return trimDecimals(formatUnits(bptReceivedFromZap.value, 18), 6)
})

const setMax = () => {
  const token = selectedInputToken.value
  if (!token || walletBalance.value <= 0n) return
  inputAmount.value = formatUnits(walletBalance.value, token.decimals)
}

const zapButtonLabel = computed(() => {
  if (!isConnected.value) return 'Connect Wallet'
  if (isInsufficient.value) return 'Insufficient Balance'
  if (isQuoting.value) return 'Getting Quote...'
  if (isZapping.value) return 'Zapping...'
  if (quoteError.value) return 'Quote Error'
  if (!inputAmountNano.value || inputAmountNano.value <= 0n) return 'Enter Amount'
  return `Zap ${selectedInputToken.value?.symbol} → BPT`
})

const isZapButtonDisabled = computed(() => {
  if (!isConnected.value) return false
  return !isZapReady.value || isZapping.value || isQuoting.value
})

const handleZap = () => {
  if (!isConnected.value) {
    const { open } = useAppKit()
    open()
    return
  }
  executeZapIn()
}
</script>

<template>
  <section class="flex flex-col min-h-[calc(100dvh-178px)]">
    <BasePageHeader
      title="Zap BPT"
      description="Convert AUSD or WMON into Balancer Pool Tokens"
      class="mb-24"
      arrow-right
    />

    <div class="max-w-[520px] w-full mx-auto flex flex-col gap-16">
      <!-- Pool Selector -->
      <div class="bg-surface-secondary rounded-xl p-24 shadow-card">
        <h3 class="text-body-sm font-medium text-content-tertiary mb-12">
          Select Pool
        </h3>
        <div class="grid grid-cols-2 gap-8">
          <button
            v-for="pool in pools"
            :key="pool.id"
            class="rounded-12 p-12 text-left transition-all border text-body-sm"
            :class="selectedPoolId === pool.id
              ? 'bg-accent-400/20 border-accent-400 text-accent-400'
              : 'bg-surface border-line-default text-content-secondary hover:border-line-emphasis'"
            @click="selectedPoolId = pool.id"
          >
            <div class="font-medium truncate">
              {{ pool.name }}
            </div>
            <div class="text-body-xs mt-4 opacity-70">
              {{ pool.borrowAssetSymbol }}
            </div>
          </button>
        </div>
      </div>

      <!-- Amount Input -->
      <div class="bg-surface-secondary rounded-xl p-24 shadow-card">
        <div class="flex justify-between items-center mb-8">
          <h3 class="text-body-sm font-medium text-content-tertiary">
            Amount
          </h3>
          <button
            v-if="walletBalance > 0n"
            class="text-body-xs text-accent-400 hover:text-accent-300 transition-colors"
            @click="setMax"
          >
            Balance: {{ walletBalanceFormatted }} {{ selectedInputToken?.symbol }}
          </button>
        </div>

        <div class="flex items-center gap-8 bg-surface rounded-12 border border-line-default p-12 focus-within:border-accent-400 transition-colors">
          <input
            v-model="inputAmount"
            type="text"
            inputmode="decimal"
            placeholder="0.0"
            class="flex-1 bg-transparent text-content-primary text-h3 outline-none placeholder:text-content-quaternary"
          >
          <div class="px-12 py-6 bg-euler-dark-600 rounded-8 text-body-sm font-medium text-content-secondary shrink-0">
            {{ selectedInputToken?.symbol || '—' }}
          </div>
        </div>

        <div
          v-if="isInsufficient"
          class="mt-8 text-body-xs text-red-400"
        >
          Insufficient balance
        </div>
      </div>

      <!-- Summary -->
      <div
        v-if="inputAmountNano > 0n"
        class="bg-surface-secondary rounded-xl p-24 shadow-card"
      >
        <h3 class="text-body-sm font-medium text-content-tertiary mb-12">
          Summary
        </h3>
        <div class="flex flex-col gap-10">
          <div class="flex justify-between text-body-sm">
            <span class="text-content-tertiary">You Send</span>
            <span class="text-content-primary font-medium">{{ inputAmount }} {{ selectedInputToken?.symbol }}</span>
          </div>
          <div
            v-if="expectedBptFromZap > 0n"
            class="flex justify-between text-body-sm"
          >
            <span class="text-content-tertiary">You Receive (est.)</span>
            <span class="text-content-primary font-medium">~{{ expectedBptFormatted }} BPT</span>
          </div>
          <div class="flex justify-between text-body-sm">
            <span class="text-content-tertiary">Pool</span>
            <span class="text-content-primary font-medium">{{ selectedPool.name }}</span>
          </div>
        </div>

        <div
          v-if="quoteError"
          class="mt-12 p-10 rounded-8 bg-red-500/10 text-red-400 text-body-xs"
        >
          {{ quoteError }}
        </div>

        <div
          v-if="isQuoting"
          class="mt-12 flex items-center gap-8 text-body-xs text-content-tertiary"
        >
          <UiLoader class="!w-14 !h-14" />
          Fetching quote...
        </div>
      </div>

      <!-- Zap Button -->
      <button
        v-if="phase === 'input'"
        class="w-full py-16 rounded-12 text-body-md font-semibold transition-all"
        :class="isZapButtonDisabled
          ? 'bg-euler-dark-600 text-content-quaternary cursor-not-allowed'
          : 'bg-accent-400 ui-button--primary hover:bg-accent-300 shadow-lg hover:shadow-xl'"
        :disabled="isZapButtonDisabled"
        @click="handleZap"
      >
        <span
          v-if="isZapping"
          class="flex items-center justify-center gap-8"
        >
          <UiLoader class="!w-16 !h-16" />
          Zapping...
        </span>
        <span v-else>{{ zapButtonLabel }}</span>
      </button>

      <!-- Success State -->
      <template v-if="phase === 'done'">
        <div class="bg-surface-secondary rounded-xl p-24 shadow-card">
          <div class="flex items-center gap-8 mb-16">
            <div class="w-32 h-32 rounded-full bg-green-400/20 flex items-center justify-center text-green-400 text-body-sm font-bold">
              ✓
            </div>
            <div>
              <div class="text-body-sm font-medium text-content-primary">
                Zap Complete
              </div>
              <div class="text-body-xs text-content-tertiary">
                {{ bptReceivedFormatted }} BPT received in your wallet
              </div>
            </div>
          </div>
        </div>

        <button
          class="w-full py-16 rounded-12 text-body-md font-semibold transition-all bg-accent-400 text-euler-dark-900 hover:bg-accent-300 shadow-lg hover:shadow-xl"
          @click="resetState"
        >
          Zap Again
        </button>
      </template>
    </div>
  </section>
</template>
