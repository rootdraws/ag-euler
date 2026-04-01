/**
 * Lightweight fixed-point arithmetic using native bigint.
 * Drop-in replacement for ethers.FixedNumber used in LTV, health, and price calculations.
 *
 * Internally stores a scaled bigint: value * 10^decimals.
 * All arithmetic maintains precision by scaling to a common base.
 */
export class FixedPoint {
  readonly value: bigint
  readonly decimals: number

  private constructor(value: bigint, decimals: number) {
    this.value = value
    this.decimals = decimals
  }

  private get scale(): bigint {
    return 10n ** BigInt(this.decimals)
  }

  static fromValue(value: bigint | number, decimals: number | bigint = 18): FixedPoint {
    return new FixedPoint(BigInt(value), Number(decimals))
  }

  private alignDecimals(other: FixedPoint): { a: bigint, b: bigint, decimals: number } {
    if (this.decimals === other.decimals) {
      return { a: this.value, b: other.value, decimals: this.decimals }
    }
    if (this.decimals > other.decimals) {
      const diff = BigInt(this.decimals - other.decimals)
      return { a: this.value, b: other.value * (10n ** diff), decimals: this.decimals }
    }
    const diff = BigInt(other.decimals - this.decimals)
    return { a: this.value * (10n ** diff), b: other.value, decimals: other.decimals }
  }

  mul(other: FixedPoint): FixedPoint {
    const result = (this.value * other.value) / other.scale
    return new FixedPoint(result, this.decimals)
  }

  div(other: FixedPoint): FixedPoint {
    if (other.value === 0n) {
      return new FixedPoint(0n, this.decimals)
    }
    const result = (this.value * other.scale) / other.value
    return new FixedPoint(result, this.decimals)
  }

  add(other: FixedPoint): FixedPoint {
    const { a, b, decimals } = this.alignDecimals(other)
    return new FixedPoint(a + b, decimals)
  }

  sub(other: FixedPoint): FixedPoint {
    const { a, b, decimals } = this.alignDecimals(other)
    const result = a - b
    if (result < 0n) {
      return new FixedPoint(0n, decimals)
    }
    return new FixedPoint(result, decimals)
  }

  /** Subtraction without clamping to zero (can return negative values) */
  subUnsafe(other: FixedPoint): FixedPoint {
    const { a, b, decimals } = this.alignDecimals(other)
    return new FixedPoint(a - b, decimals)
  }

  /** Addition that ignores decimal alignment (unsafe, matches ethers behavior) */
  addUnsafe(other: FixedPoint): FixedPoint {
    return new FixedPoint(this.value + other.value, this.decimals)
  }

  isZero(): boolean {
    return this.value === 0n
  }

  isNegative(): boolean {
    return this.value < 0n
  }

  lt(other: FixedPoint): boolean {
    const { a, b } = this.alignDecimals(other)
    return a < b
  }

  lte(other: FixedPoint): boolean {
    const { a, b } = this.alignDecimals(other)
    return a <= b
  }

  gte(other: FixedPoint): boolean {
    const { a, b } = this.alignDecimals(other)
    return a >= b
  }

  round(targetDecimals: number): FixedPoint {
    if (targetDecimals >= this.decimals) {
      const diff = BigInt(targetDecimals - this.decimals)
      return new FixedPoint(this.value * (10n ** diff), targetDecimals)
    }
    const diff = BigInt(this.decimals - targetDecimals)
    const divisor = 10n ** diff
    const half = divisor / 2n
    const isNeg = this.value < 0n
    const abs = isNeg ? -this.value : this.value
    const rounded = (abs + half) / divisor
    return new FixedPoint(isNeg ? -rounded : rounded, targetDecimals)
  }

  toFormat({ decimals }: { decimals: number }): FixedPoint {
    return this.round(decimals)
  }

  toUnsafeFloat(): number {
    if (this.decimals === 0) {
      return Number(this.value)
    }
    const scale = this.scale
    const whole = this.value / scale
    const remainder = this.value % scale
    return Number(whole) + Number(remainder) / Number(scale)
  }

  toString(): string {
    if (this.decimals === 0) {
      return this.value.toString()
    }
    const isNeg = this.value < 0n
    const abs = isNeg ? -this.value : this.value
    const scale = this.scale
    const whole = abs / scale
    const remainder = abs % scale
    const fractional = remainder.toString().padStart(this.decimals, '0')
    const sign = isNeg ? '-' : ''
    return `${sign}${whole}.${fractional}`
  }
}
