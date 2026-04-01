// Sanctioned countries — always blocked for all products
// Commented-out entries can be enabled when needed
export const SANCTIONED_COUNTRIES: readonly string[] = [
  'AF', // Afghanistan
  'BY', // Belarus
  'CF', // Central African Republic
  'CU', // Cuba
  'KP', // North Korea
  'CD', // DR Congo
  'ET', // Ethiopia
  'IR', // Iran
  'IQ', // Iraq
  'LB', // Lebanon
  'LY', // Libya
  'ML', // Mali
  'MM', // Myanmar
  'NI', // Nicaragua
  'RU', // Russia
  'SO', // Somalia
  'SS', // South Sudan
  'SD', // Sudan
  'SY', // Syria
  // 'UA', // Ukraine (Crimea, Donetsk, Luhansk)
  'VE', // Venezuela
  'YE', // Yemen
  'ZW', // Zimbabwe
]

// EU member states (27 countries)
export const EU_COUNTRIES: readonly string[] = [
  'AT', // Austria
  'BE', // Belgium
  'BG', // Bulgaria
  'HR', // Croatia
  'CY', // Cyprus
  'CZ', // Czechia
  'DK', // Denmark
  'EE', // Estonia
  'FI', // Finland
  'FR', // France
  'DE', // Germany
  'GR', // Greece
  'HU', // Hungary
  'IE', // Ireland
  'IT', // Italy
  'LV', // Latvia
  'LT', // Lithuania
  'LU', // Luxembourg
  'MT', // Malta
  'NL', // Netherlands
  'PL', // Poland
  'PT', // Portugal
  'RO', // Romania
  'SK', // Slovakia
  'SI', // Slovenia
  'ES', // Spain
  'SE', // Sweden
]

// EFTA member states (4 countries)
export const EFTA_COUNTRIES: readonly string[] = [
  'IS', // Iceland
  'LI', // Liechtenstein
  'NO', // Norway
  'CH', // Switzerland
]

// EEA = EU + Iceland, Liechtenstein, Norway (not Switzerland)
export const EEA_COUNTRIES: readonly string[] = [
  ...EU_COUNTRIES,
  'IS', // Iceland
  'LI', // Liechtenstein
  'NO', // Norway
]

// Map of group aliases usable in product/earn-vault `block` arrays
export const COUNTRY_GROUPS: Record<string, readonly string[]> = {
  EU: EU_COUNTRIES,
  EEA: EEA_COUNTRIES,
  EFTA: EFTA_COUNTRIES,
}
