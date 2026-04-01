export type RaceGuard = {
  next: () => number
  current: () => number
  isStale: (captured: number) => boolean
}

export function createRaceGuard(): RaceGuard {
  let generation = 0
  return {
    next: () => ++generation,
    current: () => generation,
    isStale: (captured: number) => captured !== generation,
  }
}
