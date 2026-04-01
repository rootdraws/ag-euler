#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Cork Protected Loop — Liquidation Bot
#
# Polls the sUSDe vault for underwater borrowers and liquidates them through
# the CorkProtectedLoopLiquidator contract via an EVC batch.
#
# Usage:  ./run.sh              (foreground, Ctrl-C to stop)
#         nohup ./run.sh &      (background on Digital Ocean)
#
# Requires: foundry (cast), bc, jq
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

BOT=$(cast wallet address "$BOT_PRIVATE_KEY")
MAX_UINT="0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
notify() {
    log "$*"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -s -H "Content-Type: application/json" \
             -d "{\"content\":\"[Cork Liquidator] $*\"}" \
             "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

# ── Discover borrowers from Borrow events ────────────────────────────────────
discover_borrowers() {
    log "Scanning Borrow events from block $SCAN_FROM_BLOCK..."
    local raw
    raw=$(cast logs \
        --from-block "$SCAN_FROM_BLOCK" \
        --address "$SUSDE_VAULT" \
        "Borrow(address,uint256)" \
        --rpc-url "$RPC_URL" --json 2>/dev/null || echo "[]")

    if [[ "$raw" == "[]" ]] || [[ -z "$raw" ]]; then
        echo ""
        return
    fi

    echo "$raw" \
        | jq -r '.[].topics[1]' \
        | sed 's/^0x000000000000000000000000/0x/' \
        | sort -u
}

# ── Check if an account is liquidatable ──────────────────────────────────────
# Returns "maxRepay maxYield" or "0 0" if not liquidatable.
check_liquidation() {
    local violator="$1"
    local result
    result=$(cast call "$SUSDE_VAULT" \
        "checkLiquidation(address,address,address)(uint256,uint256)" \
        "$CORK_LIQUIDATOR" "$violator" "$VBUSDC_VAULT" \
        --rpc-url "$RPC_URL" 2>/dev/null || echo "0 0")
    echo "$result"
}

# ── Execute liquidation via EVC batch ────────────────────────────────────────
# The batch:
#   1. liquidator.liquidate(bot, sUsdeVault, violator, vbUsdcVault, maxUint, 0)
#      → seizes cST + vbUSDC, exercises in Cork pool, sends sUSDe to bot,
#        pulls debt to bot
#   2. sUsdeVault.repay(maxUint, bot)
#      → repays the pulled debt using sUSDe received from step 1
execute_liquidation() {
    local violator="$1"
    local max_repay="$2"

    log "Executing liquidation of $violator (maxRepay: $max_repay)..."

    local liq_calldata
    liq_calldata=$(cast calldata \
        "liquidate(address,address,address,address,uint256,uint256)" \
        "$BOT" "$SUSDE_VAULT" "$violator" "$VBUSDC_VAULT" "$MAX_UINT" "0")

    local repay_calldata
    repay_calldata=$(cast calldata \
        "repay(uint256,address)" \
        "$MAX_UINT" "$BOT")

    local tx_output
    tx_output=$(cast send --private-key "$BOT_PRIVATE_KEY" --rpc-url "$RPC_URL" \
        "$EVC" "batch((address,address,uint256,bytes)[])" \
        "[($CORK_LIQUIDATOR,$BOT,0,$liq_calldata),($SUSDE_VAULT,$BOT,0,$repay_calldata)]" \
        --gas-limit 3000000 2>&1)

    local status
    status=$(echo "$tx_output" | grep "^status" | awk '{print $2}')

    if [[ "$status" == "1" ]]; then
        local tx_hash gas_used sUSDe_bal
        tx_hash=$(echo "$tx_output" | grep "^transactionHash" | awk '{print $2}')
        gas_used=$(echo "$tx_output" | grep "^gasUsed" | awk '{print $2}')
        sUSDe_bal=$(cast call "$SUSDE_TOKEN" "balanceOf(address)(uint256)" "$BOT" --rpc-url "$RPC_URL")
        notify "LIQUIDATED $violator | tx=$tx_hash | gas=$gas_used | sUSDe balance=$sUSDe_bal"
        return 0
    else
        local tx_hash
        tx_hash=$(echo "$tx_output" | grep "^transactionHash" | awk '{print $2}')
        notify "REVERTED liquidation of $violator | tx=${tx_hash:-unknown}"
        log "Full output: $tx_output"
        return 1
    fi
}

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
    log "╔══════════════════════════════════════════════════╗"
    log "║   Cork Protected Loop — Liquidation Bot         ║"
    log "╚══════════════════════════════════════════════════╝"
    log "Bot:         $BOT"
    log "sUSDe Vault: $SUSDE_VAULT"
    log "vbUSDC Vault:$VBUSDC_VAULT"
    log "cST Vault:   $CST_VAULT"
    log "Liquidator:  $CORK_LIQUIDATOR"
    log "Poll:        every ${POLL_INTERVAL}s"
    log ""

    # One-time borrower discovery from historical events
    local -a BORROWERS=()
    local discovered
    discovered=$(discover_borrowers)
    if [[ -n "$discovered" ]]; then
        while IFS= read -r addr; do
            BORROWERS+=("$addr")
        done <<< "$discovered"
    fi
    log "Found ${#BORROWERS[@]} historical borrower(s)"

    if [[ ${#BORROWERS[@]} -eq 0 ]]; then
        log "No borrowers found. Will re-scan every 10 cycles."
    fi

    local cycle=0
    while true; do
        cycle=$((cycle + 1))

        # Re-discover borrowers every 10 cycles to catch new ones
        if [[ $((cycle % 10)) -eq 0 ]]; then
            discovered=$(discover_borrowers)
            if [[ -n "$discovered" ]]; then
                BORROWERS=()
                while IFS= read -r addr; do
                    BORROWERS+=("$addr")
                done <<< "$discovered"
            fi
            log "Refreshed: ${#BORROWERS[@]} borrower(s) tracked"
        fi

        for borrower in "${BORROWERS[@]+"${BORROWERS[@]}"}"; do
            [[ -z "$borrower" ]] && continue

            local debt debt_raw
            debt_raw=$(cast call "$SUSDE_VAULT" "debtOf(address)(uint256)" "$borrower" \
                --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
            debt=$(echo "$debt_raw" | awk '{print $1}')

            if [[ "$debt" == "0" ]]; then
                continue
            fi

            local liq_result max_repay max_yield
            liq_result=$(check_liquidation "$borrower")
            # cast returns e.g. "6000000068903729570288 [6e21]\n7697614928 [7.697e9]"
            max_repay=$(echo "$liq_result" | head -1 | awk '{print $1}')
            max_yield=$(echo "$liq_result" | tail -1 | awk '{print $1}')

            if [[ "$max_repay" != "0" ]] && [[ -n "$max_repay" ]] && [[ "$max_repay" != "00" ]]; then
                notify "UNDERWATER: $borrower | debt=$debt | maxRepay=$max_repay | maxYield=$max_yield"
                execute_liquidation "$borrower" "$max_repay" || true
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
