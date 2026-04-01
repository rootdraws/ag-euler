<script setup lang="ts">
import { type MenuItem, getMenuItems } from '~/entities/menu'

const { enableEarnPage, enableLendPage, enableExplorePage, enableLoopZapPage, enableCorkBorrowPage } = useDeployConfig()
const menuItems = getMenuItems(enableEarnPage, enableLendPage, enableExplorePage, enableLoopZapPage, enableCorkBorrowPage)

const route = useRoute()

const getMenuIcon = (item: MenuItem) => {
  return route.name?.toString().startsWith(item.name) ? item.activeIcon : item.icon
}

const isActive = (item: MenuItem) => {
  return route.name?.toString().startsWith(item.name)
}
</script>

<template>
  <div
    class="fixed bottom-0 left-0 right-0 z-[100] laptop:!hidden bg-header backdrop-blur-[20px] border-t border-line-default p-16 justify-center"
  >
    <div
      class="flex w-full h-50 max-w-container"
    >
      <NuxtLink
        v-for="link in menuItems"
        :key="link.name"
        :to="'/' + link.name"
        class="flex flex-col items-center text-center flex-1 text-decoration-none text-[12px] transition-colors"
        :class="isActive(link) ? 'text-content-primary' : 'text-content-secondary'"
      >
        <UiIcon
          class="!w-20 !h-20 mb-10"
          :class="isActive(link) ? 'text-accent-600' : 'text-content-muted'"
          :name="getMenuIcon(link)"
        />
        <span>{{ link.label }}</span>
      </NuxtLink>
    </div>
  </div>
</template>
