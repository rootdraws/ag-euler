import uiTextFit from '~/components/ui/directives/text-fit'

export default defineNuxtPlugin((nuxtApp) => {
  nuxtApp.vueApp.directive('text-fit', uiTextFit)
})
