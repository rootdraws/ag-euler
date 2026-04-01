<script setup lang="ts">
const { permit2Enabled, setPermit2Enabled } = usePermit2Preference()

const onToggle = (value: boolean | undefined) => {
  setPermit2Enabled(value ?? false)
}
</script>

<template>
  <div class="mb-20 rounded-16 border border-euler-dark-600 bg-euler-dark-500 p-16">
    <div class="flex items-center justify-between">
      <div>
        <div class="text-p2">
          permit2 approvals
        </div>
        <div class="text-p3 text-euler-dark-700">
          Use gasless token approvals
        </div>
      </div>
      <UiSwitch
        :model-value="permit2Enabled"
        @update:model-value="onToggle"
      />
    </div>
  </div>
</template>
