import { createRaceGuard } from '~/utils/race-guard'

export function useReactiveMap<T, R>(
  items: Ref<T[]> | ComputedRef<T[]>,
  deps: (Ref<unknown> | ComputedRef<unknown>)[],
  mapFn: (item: T) => Promise<R>,
): Readonly<Ref<R[]>> {
  const results = ref<R[]>([]) as Ref<R[]>
  const guard = createRaceGuard()

  watchEffect(async () => {
    const snapshot = items.value
    for (const dep of deps) void dep.value
    const gen = guard.next()
    const mapped = await Promise.all(snapshot.map(mapFn))
    if (guard.isStale(gen)) return
    results.value = mapped
  })

  return results as Readonly<Ref<R[]>>
}
