<script setup lang="ts">
import type { NuxtError } from '#app'

const props = defineProps({
  error: {
    type: Object as () => NuxtError<Record<string, any>>,
    default: () => ({}),
  },
})

const router = useRouter()

const errorText = computed(() => {
  return props.error?.message || 'Something went wrong'
})
</script>

<template>
  <NuxtLayout>
    <div class="flex justify-center min-h-[100dvh] py-16">
      <div class="container flex flex-col justify-between">
        <div
          class="flex flex-col justify-center items-center h-full flex-1"
        >
          <div class="text-p2 text-center px-16">
            Error:
            {{ errorText }}
          </div>
        </div>
        <UiButton
          variant="primary-stroke"
          size="large"
          rounded
          @click="router.replace('/')"
        >
          Go to Main Page
        </UiButton>
      </div>
    </div>
  </NuxtLayout>
</template>
