export const getRelativeTimeBetweenDates = (from: Date, to: Date) => {
  const secondsDiff = Math.round((+to - +from) / 1000)
  const unitsInSec = [60, 3600, 86400, 86400 * 7, 86400 * 30, 86400 * 365, Infinity]
  const unitStrings = ['second', 'minute', 'hour', 'day', 'week', 'month', 'year']
  const unitIndex = unitsInSec.findIndex(cutoff => cutoff > Math.abs(secondsDiff))
  const divisor = unitIndex ? unitsInSec[unitIndex - 1] : 1
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })
  return rtf.format(Math.floor(secondsDiff / divisor), unitStrings[unitIndex] as Intl.RelativeTimeFormatUnit)
}
