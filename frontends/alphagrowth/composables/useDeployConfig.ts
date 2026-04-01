export interface ArmAdapterEntry {
  armContract: string
}

function parseArmAdapterConfig(raw: unknown): Record<string, ArmAdapterEntry> {
  if (!raw) return {}
  if (typeof raw === 'object' && typeof raw !== 'string') return raw as Record<string, ArmAdapterEntry>
  if (typeof raw !== 'string') return {}
  try {
    return JSON.parse(raw.trim())
  }
  catch {
    return {}
  }
}

export interface BptAdapterEntry {
  adapter: string
  tokenIndex: number
  pool?: string
  wrapper?: string
  numTokens?: number
}

function parseBptAdapterConfig(raw: unknown): Record<string, BptAdapterEntry> {
  if (!raw) return {}
  if (typeof raw === 'object') return raw as Record<string, BptAdapterEntry>
  if (typeof raw !== 'string') return {}
  try {
    return JSON.parse(raw.trim())
  }
  catch {
    return {}
  }
}

export const useDeployConfig = () => {
  const rc = useRuntimeConfig().public
  const envConfig = useEnvConfig()

  const isEnabled = (val: unknown) => {
    const s = String(val)
    return s !== 'false' && s !== '0'
  }
  const isExplicitlyEnabled = (val: unknown) => {
    const s = String(val)
    return s === 'true' || s === '1'
  }

  return {
    // URLs (empty string = not configured, hide UI element)
    docsUrl: rc.configDocsUrl,
    tosUrl: rc.configTosUrl || 'https://www.euler.finance/terms',
    tosMdUrl: rc.configTosMdUrl,
    xUrl: rc.configXUrl,
    discordUrl: rc.configDiscordUrl,
    telegramUrl: rc.configTelegramUrl,
    githubUrl: rc.configGithubUrl,

    // Branding (from useEnvConfig, not runtimeConfig)
    appTitle: envConfig.appTitle,
    appDescription: envConfig.appDescription,

    // Repos
    labelsRepo: rc.configLabelsRepo || 'euler-xyz/euler-labels',
    labelsRepoBranch: rc.configLabelsRepoBranch || 'master',
    oracleChecksRepo: rc.configOracleChecksRepo || 'euler-xyz/oracle-checks',
    isCustomLabelsRepo: computed(() => {
      const repo = rc.configLabelsRepo || 'euler-xyz/euler-labels'
      const branch = rc.configLabelsRepoBranch || 'master'
      return repo !== 'euler-xyz/euler-labels' || branch !== 'master'
    }),

    // Feature flags: all enabled by default, set env var to 'false' to disable
    enableTosSignature: !!rc.configTosMdUrl,
    enableEntityBranding: isEnabled(rc.configEnableEntityBranding),
    enableVaultType: isEnabled(rc.configEnableVaultType),
    enableEarnPage: isEnabled(rc.configEnableEarnPage),
    enableLendPage: isEnabled(rc.configEnableLendPage),
    enableExplorePage: isEnabled(rc.configEnableExplorePage),
    enableSwapDeposit: isExplicitlyEnabled(rc.configEnableSwapDeposit),
    enableEnsoMultiply: isExplicitlyEnabled(rc.configEnableEnsoMultiply),
    enableLoopZapPage: isExplicitlyEnabled(rc.configEnableLoopZapPage),
    enableCorkBorrowPage: isExplicitlyEnabled(rc.configEnableCorkBorrowPage),

    // BPT adapter config: JSON map of collateral vault address → { adapter, tokenIndex, pool, wrapper, numTokens }
    // Example: {"0x175831aF...":{"adapter":"0xABC...","tokenIndex":1}}
    bptAdapterConfig: parseBptAdapterConfig(rc.configBptAdapterConfig),

    // ARM adapter config (Origin ARM multiply): JSON map of collateral vault → { armContract }
    armAdapterConfig: parseArmAdapterConfig(rc.configArmAdapterConfig),

    // Chains (derived from env vars at runtime via useChainConfig)
    ...useChainConfig(),
  }
}
