<script setup lang="ts">
import { formatSmartAmount } from '~/utils/string-utils'
import { useCorkBorrowForm } from '~/composables/borrow/useCorkBorrowForm'

defineOptions({ name: 'CorkBorrowPage' })

const {
  vbUsdcAmount,
  borrowAmount,
  cstAmountDisplay,
  friendlyVbUsdcBalance,
  friendlyCstBalance,
  hasInsufficientCst,
  errorText,
  canSubmit,
  isSubmitting,
  isPreparing,
  onMaxVbUsdc,
  prepare,
} = useCorkBorrowForm()

const onVbUsdcInput = (e: Event) => {
  const value = (e.target as HTMLInputElement).value.replace(',', '.')
  if (isNaN(Number(value)) && Boolean(value)) {
    (e.target as HTMLInputElement).value = vbUsdcAmount.value
    return
  }
  vbUsdcAmount.value = value
}

const onBorrowInput = (e: Event) => {
  const value = (e.target as HTMLInputElement).value.replace(',', '.')
  if (isNaN(Number(value)) && Boolean(value)) {
    (e.target as HTMLInputElement).value = borrowAmount.value
    return
  }
  borrowAmount.value = value
}
</script>

<template>
  <div class="max-w-[520px] mx-auto px-16 pt-24 pb-48">
    <form
      class="flex flex-col gap-16"
      @submit.prevent
    >
      <h1 class="text-p1">
        Cork Protected Borrow
      </h1>
      <p class="text-p3 text-euler-dark-800">
        Deposit vbUSDC + cST as dual collateral to borrow sUSDe. cST is automatically matched 1:1 with vbUSDC.
      </p>

      <!-- vbUSDC collateral input -->
      <div class="flex flex-col gap-12 p-16 rounded-16 border bg-[var(--ui-form-field-background)] border-[var(--ui-form-field-border-color)] shadow-[var(--ui-form-field-shadow)]">
        <div class="flex justify-between text-euler-dark-800">
          <p>Supply vbUSDC</p>
        </div>
        <div class="flex items-center gap-12">
          <input
            :value="vbUsdcAmount"
            class="text-h1 text-euler-dark-1000 w-full h-40 outline-none bg-transparent placeholder:text-euler-dark-800"
            type="text"
            placeholder="0.00"
            maxlength="24"
            autocomplete="off"
            inputmode="decimal"
            @input="onVbUsdcInput"
          >
          <div class="bg-euler-dark-500 text-p3 font-semibold gap-8 flex items-center justify-center px-12 h-36 rounded-[40px] whitespace-nowrap">
            vbUSDC
          </div>
        </div>
        <div class="flex justify-between">
          <p class="text-euler-dark-800">
            {{ formatSmartAmount(friendlyVbUsdcBalance) }} vbUSDC
          </p>
          <span
            class="text-aquamarine-700 font-semibold px-4 cursor-pointer select-none text-[12px] leading-[16px]"
            @click="onMaxVbUsdc"
          >Max</span>
        </div>
      </div>

      <!-- cST paired display (read-only) -->
      <div class="flex flex-col gap-12 p-16 rounded-16 border bg-[var(--ui-form-field-background)] border-[var(--ui-form-field-border-color)] shadow-[var(--ui-form-field-shadow)] opacity-75">
        <div class="flex justify-between text-euler-dark-800">
          <p>Paired cST (auto-matched)</p>
        </div>
        <div class="flex items-center gap-12">
          <input
            :value="cstAmountDisplay || '0.00'"
            class="text-h1 text-euler-dark-1000 w-full h-40 outline-none bg-transparent placeholder:text-euler-dark-800 cursor-not-allowed"
            type="text"
            disabled
          >
          <div class="bg-euler-dark-500 text-p3 font-semibold gap-8 flex items-center justify-center px-12 h-36 rounded-[40px] whitespace-nowrap">
            cST
          </div>
        </div>
        <div class="flex justify-between">
          <p class="text-euler-dark-800">
            {{ formatSmartAmount(friendlyCstBalance) }} cST
          </p>
          <span
            v-if="hasInsufficientCst"
            class="text-red-400 font-medium text-[12px]"
          >Insufficient cST</span>
        </div>
      </div>

      <!-- Separator -->
      <div class="flex items-center gap-12">
        <div class="flex-1 h-px bg-euler-dark-600" />
        <SvgIcon
          name="arrow-down"
          class="!w-20 !h-20 text-euler-dark-800"
        />
        <div class="flex-1 h-px bg-euler-dark-600" />
      </div>

      <!-- Borrow sUSDe input -->
      <div class="flex flex-col gap-12 p-16 rounded-16 border bg-[var(--ui-form-field-background)] border-[var(--ui-form-field-border-color)] shadow-[var(--ui-form-field-shadow)]">
        <div class="flex justify-between text-euler-dark-800">
          <p>Borrow sUSDe</p>
        </div>
        <div class="flex items-center gap-12">
          <input
            :value="borrowAmount"
            class="text-h1 text-euler-dark-1000 w-full h-40 outline-none bg-transparent placeholder:text-euler-dark-800"
            type="text"
            placeholder="0.00"
            maxlength="24"
            autocomplete="off"
            inputmode="decimal"
            @input="onBorrowInput"
          >
          <div class="bg-euler-dark-500 text-p3 font-semibold gap-8 flex items-center justify-center px-12 h-36 rounded-[40px] whitespace-nowrap">
            sUSDe
          </div>
        </div>
      </div>

      <!-- Info block -->
      <div class="p-16 rounded-16 bg-surface-secondary shadow-card flex flex-col gap-16">
        <div class="flex justify-between">
          <span class="text-euler-dark-800">Collateral</span>
          <span class="text-p2">{{ vbUsdcAmount || '0' }} vbUSDC + {{ cstAmountDisplay || '0' }} cST</span>
        </div>
        <div class="flex justify-between">
          <span class="text-euler-dark-800">Borrow</span>
          <span class="text-p2">{{ borrowAmount || '0' }} sUSDe</span>
        </div>
        <div class="flex justify-between">
          <span class="text-euler-dark-800">Dual-collateral ratio</span>
          <span class="text-p2">1:1 (vbUSDC : cST)</span>
        </div>
      </div>

      <!-- Error text -->
      <p
        v-if="errorText"
        class="text-red-400 text-p3 text-center"
      >
        {{ errorText }}
      </p>

      <!-- Submit -->
      <VaultFormSubmit
        :disabled="!canSubmit"
        :loading="isSubmitting || isPreparing"
        @click="prepare"
      >
        Review Borrow
      </VaultFormSubmit>
    </form>
  </div>
</template>
