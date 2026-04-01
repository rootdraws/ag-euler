<script setup lang="ts">
import type { BorrowVaultPair, EarnVault, SecuritizeVault, Vault } from '~/entities/vault'
import { VaultOverviewModal } from '#components'
import { useModal } from '~/components/ui/composables/useModal'
import type { AccountBorrowPosition } from '~/entities/account'

const { vault, pair, earnVault, extraVault } = defineProps<{ vault?: Vault | SecuritizeVault, pair?: BorrowVaultPair | AccountBorrowPosition, earnVault?: EarnVault, extraVault?: Vault, disabled?: boolean }>()
const modal = useModal()

const isSecuritize = (v: Vault | SecuritizeVault | undefined): v is SecuritizeVault =>
  !!v && 'type' in v && v.type === 'securitize'

const onClick = () => {
  modal.open(VaultOverviewModal, {
    props: {
      pair: pair,
      vault: isSecuritize(vault) ? undefined : vault,
      securitizeVault: isSecuritize(vault) ? vault : undefined,
      earnVault: earnVault,
      extraVault,
    },
  })
}
</script>

<template>
  <UiButton
    size="large"
    variant="primary-stroke"
    :disabled="disabled"
    @click="onClick"
  >
    {{ pair ? 'Pair information' : 'Vault information' }}
  </UiButton>
</template>
