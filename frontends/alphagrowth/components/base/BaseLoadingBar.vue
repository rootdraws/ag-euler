<script setup lang="ts">

</script>

<template>
  <div class="absolute top-0 left-0 right-0 h-[3px] bg-[rgba(200,200,200,0.1)] rounded-t-8 after:content-[''] after:absolute after:top-0 after:left-[-50%] after:w-[40%] after:h-[3px] after:bg-euler-dark-700 after:rounded-tl-8 after:animate-[loading_1.5s_linear_infinite]" />
</template>

<style>
@keyframes loading {
  0% {
    left: -50%;
  }
  100% {
    left: 100%;
  }
}
</style>
