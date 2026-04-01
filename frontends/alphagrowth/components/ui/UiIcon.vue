<template>
  <svg
    :class="icon.class"
  >
    <title v-if="title">{{ title }}</title>
    <desc v-if="desc">{{ desc }}</desc>
    <use :href="icon.url" />
  </svg>
</template>

<script setup lang="ts">
const props = defineProps({
  name: {
    type: String,
    required: true,
  },
  title: {
    type: String,
    default: null,
  },
  desc: {
    type: String,
    default: null,
  },
})

const icon = ref({
  url: '',
  class: '',
})

icon.value = await useSprite(props.name)

watch(() => props.name, async (name) => {
  icon.value = await useSprite(name)
})
</script>
