#!/usr/bin/env bash
# track-fees.sh — snapshot AG fee accrual across Euler V2 vaults
#
# Usage:    ./track-fees.sh
# Config:   vaults.tsv (chain, rpc_var, vault, symbol, asset_symbol, decimals, cluster)
# Output:   snapshots/<UTC-date>.tsv  (raw, for diffing)  + pretty stdout summary
# RPCs:     export RPC_BASE=... before running (or other rpc_var listed in vaults.tsv)
#
# How fees split:
#   * vaultStorage.feeReceiver == 0x0  → protocolFeeShare() returns 1e4 (100%) → all fees go to Euler protocol
#   * vaultStorage.feeReceiver != 0x0  → protocolFeeShare() returns ProtocolConfig's share for that vault
#                                        AG's share = (1e4 - protocolFeeShare) / 1e4
#
# AG's lifetime accrual on a vault (in asset units) =
#   accumulatedFeesAssets * AG_share          (still on vault, unconverted)
# + balanceOf(SAFE) → convertToAssets         (already minted as shares to the Safe)

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/vaults.tsv"
SAFE=0x4f894Bfc9481110278C356adE1473eBe2127Fd3C  # AG Safe (governorAdmin)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT="$DIR/snapshots/$(date -u +%Y-%m-%d).tsv"
mkdir -p "$DIR/snapshots"

if [[ ! -f "$CONFIG" ]]; then
  echo "missing $CONFIG" >&2; exit 1
fi

# pretty-print uint with N decimals
fmt() { python3 -c "import sys; v=int(sys.argv[1]); d=int(sys.argv[2]); print(f'{v/10**d:,.4f}')" "$1" "$2"; }

printf "timestamp\tchain\tcluster\tvault\tsymbol\tasset\tdecimals\tunconverted_fees_assets\tsafe_shares\tsafe_shares_in_assets\tag_share_bps\tprotocol_fee_share_bps\tinterest_fee_bps\tfee_receiver\ttotal_borrows\n" > "$OUT"

printf "\n=== AG vault-fee snapshot — %s ===\n\n" "$TS"
printf "%-12s %-26s %-22s %12s %12s %12s %s\n" "cluster" "symbol" "asset" "unconv(AG)" "shares→assets" "AG total" "feeReceiver"
printf "%-12s %-26s %-22s %12s %12s %12s %s\n" "-------" "------" "-----" "----------" "-------------" "--------" "-----------"

while IFS=$'\t' read -r chain rpc_var vault symbol asset decimals cluster; do
  [[ "$chain" == "chain" ]] && continue
  rpc="${!rpc_var:-}"
  if [[ -z "$rpc" ]]; then
    echo "skip $vault: env var $rpc_var not set" >&2; continue
  fi

  unconv=$(cast call "$vault" "accumulatedFeesAssets()(uint256)" --rpc-url "$rpc" | awk '{print $1}')
  shares=$(cast call "$vault" "balanceOf(address)(uint256)" "$SAFE" --rpc-url "$rpc" | awk '{print $1}')
  if [[ "$shares" == "0" ]]; then sa=0; else
    sa=$(cast call "$vault" "convertToAssets(uint256)(uint256)" "$shares" --rpc-url "$rpc" | awk '{print $1}')
  fi
  fee_bps=$(cast call "$vault" "interestFee()(uint16)" --rpc-url "$rpc" | awk '{print $1}')
  prot_bps=$(cast call "$vault" "protocolFeeShare()(uint256)" --rpc-url "$rpc" | awk '{print $1}')
  receiver=$(cast call "$vault" "feeReceiver()(address)" --rpc-url "$rpc")
  borrows=$(cast call "$vault" "totalBorrows()(uint256)" --rpc-url "$rpc" | awk '{print $1}')
  ag_bps=$((10000 - prot_bps))
  unconv_ag=$(python3 -c "print(int($unconv) * $ag_bps // 10000)")
  total_ag=$((unconv_ag + sa))

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$TS" "$chain" "$cluster" "$vault" "$symbol" "$asset" "$decimals" "$unconv" "$shares" "$sa" "$ag_bps" "$prot_bps" "$fee_bps" "$receiver" "$borrows" >> "$OUT"

  printf "%-12s %-26s %-22s %12s %12s %12s %s\n" \
    "$cluster" "$symbol" "$asset" "$(fmt "$unconv_ag" "$decimals")" "$(fmt "$sa" "$decimals")" "$(fmt "$total_ag" "$decimals")" "$receiver"
done < "$CONFIG"

echo
echo "snapshot: $OUT"

# diff vs prior snapshot — print AG total deltas per vault
prior=$(ls -1 "$DIR/snapshots"/*.tsv 2>/dev/null | grep -v "$(basename "$OUT")" | tail -n 1 || true)
if [[ -n "$prior" ]]; then
  echo
  echo "=== delta vs $(basename "$prior") ==="
  python3 - "$prior" "$OUT" <<'PY'
import sys, csv
def load(p):
    out = {}
    with open(p) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            ag = int(row["unconverted_fees_assets"]) * int(row["ag_share_bps"]) // 10000 + int(row["safe_shares_in_assets"])
            out[row["vault"]] = (row["symbol"], int(row["decimals"]), ag, row["asset"])
    return out
old = load(sys.argv[1]); new = load(sys.argv[2])
for v, (sym, dec, ag_new, asset) in new.items():
    ag_old = old.get(v, (None, dec, 0, asset))[2]
    delta = ag_new - ag_old
    sign = "+" if delta >= 0 else ""
    print(f"  {sym:<26} {asset:<8} {sign}{delta/10**dec:>14,.4f}")
PY
fi
