<script setup lang="ts">
import { getDefaultPageRoute } from '~/entities/menu'

const { enableEarnPage, enableLendPage, enableExplorePage } = useDeployConfig()
const defaultPageRoute = getDefaultPageRoute(enableEarnPage, enableLendPage, enableExplorePage)

const route = useRoute()
await navigateTo(
  { name: defaultPageRoute, query: route.query, hash: route.hash },
  { replace: true },
)
</script>

<template>
  <div />
</template>
