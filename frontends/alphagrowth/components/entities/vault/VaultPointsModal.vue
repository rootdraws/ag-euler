<script setup lang="ts">
import { getEulerLabelEntityLogo } from '~/entities/euler/labels'

defineEmits(['close'])
const { pointName, pointLogo } = defineProps<{
  pointName: string
  pointLogo: string
}>()

const onLogoError = (event: Event) => {
  const img = event.target as HTMLImageElement
  if (!img.dataset.triedFallback) {
    img.dataset.triedFallback = 'true'
    img.src = getEulerLabelEntityLogo(pointLogo)
  }
}

const escapeHtml = (unsafe: string): string => {
  return unsafe
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;')
}

const isValidUrl = (url: string): boolean => {
  try {
    const urlObj = new URL(url)
    return urlObj.protocol === 'http:' || urlObj.protocol === 'https:'
  }
  catch {
    return false
  }
}

const convertMarkdownLinks = (text: string): string => {
  const markdownLinkRegex = /\[([^\]]+)\]\(([^)]+)\)/g
  let lastIndex = 0
  let result = ''
  let match

  while ((match = markdownLinkRegex.exec(text)) !== null) {
    result += escapeHtml(text.substring(lastIndex, match.index))
    const linkText = match[1]
    const url = match[2]
    if (isValidUrl(url)) {
      const safeUrl = escapeHtml(url)
      const safeText = escapeHtml(linkText)
      result += `<a href="${safeUrl}" target="_blank" rel="noopener noreferrer" class="text-accent-600 hover:underline">${safeText}</a>`
    }
    else {
      result += escapeHtml(linkText)
    }
    lastIndex = markdownLinkRegex.lastIndex
  }
  result += escapeHtml(text.substring(lastIndex))
  return result
}

const formattedPointName = computed(() => convertMarkdownLinks(pointName))
</script>

<template>
  <BaseModalWrapper
    title="Points"
    @close="$emit('close')"
  >
    <div class="flex items-center gap-12">
      <span class="text-p2">Deposit earns</span>
      <img
        :src="`/entities/${pointLogo}`"
        alt="Point logo"
        class="w-20 h-20 rounded-full"
        @error="onLogoError"
      >
      <!-- eslint-disable-next-line vue/no-v-html -->
      <span
        class="text-p2"
        v-html="formattedPointName"
      />
    </div>
  </BaseModalWrapper>
</template>
