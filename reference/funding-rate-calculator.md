# Hyperliquid Funding Rate Calculator

Analyzes historical funding rates for any perp on Hyperliquid. Used to inform IRM kink parameters for Euler borrow markets where the delta-neutral strategy is: long perp on HL (collect negative funding) + borrow/short spot on Euler.

## Quick Run

Replace `COIN` and `DAYS` and run:

```bash
python3 -c "
import json, urllib.request, time
from datetime import datetime, timedelta
from collections import defaultdict

COIN = 'VVV'
DAYS = 30

def fetch(coin, start_ms, end_ms):
    payload = json.dumps({'type': 'fundingHistory', 'coin': coin, 'startTime': start_ms, 'endTime': end_ms}).encode()
    req = urllib.request.Request('https://api.hyperliquid.xyz/info', data=payload, headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req).read())

end = int(time.time() * 1000)
start = int((time.time() - DAYS * 86400) * 1000)

# API caps at 500 results; paginate in ~20-day windows
entries = []
seen = set()
cursor = start
while cursor < end:
    window_end = min(cursor + 20 * 24 * 3600 * 1000, end)
    batch = fetch(COIN, cursor, window_end)
    for e in batch:
        if e['time'] not in seen:
            seen.add(e['time'])
            entries.append(e)
    if not batch:
        break
    cursor = max(e['time'] for e in batch) + 1
entries.sort(key=lambda x: x['time'])

all_rates = [float(e['fundingRate']) for e in entries]
neg_rates = [r for r in all_rates if r < 0]
pos_rates = [r for r in all_rates if r >= 0]

ts_first = datetime.fromtimestamp(entries[0]['time']/1000)
ts_last = datetime.fromtimestamp(entries[-1]['time']/1000)

print(f'=== {COIN} Funding Rate -- {ts_first.strftime(\"%Y-%m-%d\")} to {ts_last.strftime(\"%Y-%m-%d\")} ({DAYS}d) ===')
print(f'Total hourly entries:     {len(entries)}')
print(f'Negative funding hours:   {len(neg_rates)} ({100*len(neg_rates)/len(entries):.1f}%)')
print(f'Positive funding hours:   {len(pos_rates)} ({100*len(pos_rates)/len(entries):.1f}%)')
overall_avg = sum(all_rates) / len(all_rates)
print(f'Overall avg (all hours):  {overall_avg*100:.4f}%/hr  =  {overall_avg*8760*100:.1f}% ann.')
print(f'Cumulative {DAYS}d funding:   {sum(all_rates)*100:.4f}%')

if neg_rates:
    avg_neg = sum(neg_rates) / len(neg_rates)
    print(f'')
    print(f'=== Negative Funding Analysis ===')
    print(f'Avg negative (per hr):   {avg_neg*100:.4f}%')
    print(f'Avg negative (per day):  {avg_neg*24*100:.4f}%')
    print(f'Avg negative annualized: {avg_neg*8760*100:.1f}%')
    print()
    neg_sorted = sorted(neg_rates)
    for p in [10, 25, 50, 75, 90]:
        idx = int(len(neg_sorted) * p / 100)
        val = neg_sorted[idx]
        print(f'  P{p:<3} negative rate:     {val*100:.4f}%/hr  =  {val*8760*100:.1f}% ann.')
    print()
    print(f'=== Negative Rate Distribution (annualized) ===')
    bands = [(0, 10), (10, 25), (25, 50), (50, 100), (100, 200), (200, 999)]
    for lo, hi in bands:
        count = sum(1 for r in neg_rates if lo <= abs(r)*8760*100 < hi)
        pct = 100*count/len(neg_rates)
        label = f'{lo}%-{hi}%' if hi < 999 else f'{lo}%+'
        print(f'  {label:<12} {count:>4} hours  ({pct:.1f}%)')

# Daily summary
daily = defaultdict(list)
for e in entries:
    ts = datetime.fromtimestamp(e['time'] / 1000)
    daily[ts.strftime('%Y-%m-%d')].append(float(e['fundingRate']))

print(f'')
print(f'=== Daily Summary ===')
print(f'{\"Date\":<12} {\"Hrs\":>4} {\"Neg\":>4} {\"Pos\":>4} {\"Avg Rate\":>10} {\"Min Rate\":>10} {\"Max Rate\":>10} {\"Ann. Avg\":>10}')
print('-' * 80)
for day in sorted(daily.keys()):
    rates = daily[day]
    neg = sum(1 for r in rates if r < 0)
    pos = sum(1 for r in rates if r >= 0)
    avg = sum(rates) / len(rates)
    mn, mx = min(rates), max(rates)
    annual = avg * 8760 * 100
    marker = ' <<<' if neg > pos else ''
    print(f'{day}  {len(rates):>4} {neg:>4} {pos:>4}   {avg*100:>8.4f}%  {mn*100:>8.4f}%  {mx*100:>8.4f}%  {annual:>8.1f}%{marker}')

print()
print(f'=== IRM Kink Guidance ===')
if neg_rates:
    neg_sorted = sorted(neg_rates)
    p50 = neg_sorted[len(neg_sorted)//2]
    p75 = neg_sorted[int(len(neg_sorted)*0.75)]
    print(f'Suggested kink range: {abs(p75)*8760*100:.0f}% - {abs(p50)*8760*100:.0f}% APR')
    print(f'  (P75 to P50 of negative funding, profitable 50-75% of negative hours)')
    print(f'  Negative hours are {100*len(neg_rates)/len(entries):.0f}% of all hours')
"
```

## API Notes

- **Endpoint:** `POST https://api.hyperliquid.xyz/info`
- **Payload:** `{"type": "fundingHistory", "coin": "<SYMBOL>", "startTime": <ms>, "endTime": <ms>}`
- **Funding settles hourly** on Hyperliquid (24 entries/day)
- **Annualization:** hourly rate * 8760
- **Max 500 results per request** -- the script paginates automatically
- **Rate field:** `fundingRate` is a decimal (e.g., `-0.0001` = -0.01%/hr)

## Interpreting for IRM Kinks

The delta-neutral trade: long VVV perp on HL + borrow VVV on Euler and sell spot.

- When HL funding is negative, longs get paid. The arber profits as long as: **HL funding income > Euler borrow cost**.
- The IRM kink should sit where the borrow rate becomes expensive enough to discourage marginal borrowers but still profitable for the arb during typical negative funding.
- **P75-P50 of negative funding** is a reasonable kink range -- profitable 50-75% of the time funding is actually negative.
- The steep portion above kink captures extreme episodes without letting utilization run away.

## Reference Results (2026-03-02 to 2026-04-01)

| Metric | VVV | ZRO |
|---|---|---|
| Negative hours | 43% | 52% |
| Avg negative ann. | -153% | -36% |
| Median negative (P50) | -118% | -31% |
| P75 negative | -43% | -15% |
| Worst hour | -0.102% (-894% ann.) | -0.019% (-163% ann.) |
| Cumulative 30d | -4.87% | -1.13% |
| **Suggested kink range** | **40-80%** | **15-30%** |
