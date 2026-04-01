#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Cork Protected Loop — Liquidation Bot Setup (run once per bot wallet)
#
# Prerequisites:
#   - foundry (cast) installed
#   - .env filled with correct values
#   - Bot wallet funded with ETH
#
# This script:
#   1. Derives the bot address from the private key
#   2. Enables the sUSDe vault as the bot's EVC controller
#   3. Registers the liquidator contract as an EVC operator for the bot
#   4. Approves the sUSDe vault to spend the bot's sUSDe (for repayment)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"

BOT_ADDRESS=$(cast wallet address "$BOT_PRIVATE_KEY")
echo "Bot address: $BOT_ADDRESS"
echo "RPC:         $RPC_URL"
echo ""

ETH_BAL=$(cast balance "$BOT_ADDRESS" --rpc-url "$RPC_URL" --ether)
echo "ETH balance: $ETH_BAL"
if [ "$(echo "$ETH_BAL < 0.01" | bc -l)" -eq 1 ]; then
    echo "ERROR: Bot needs at least 0.01 ETH for gas. Fund $BOT_ADDRESS first."
    exit 1
fi

echo ""
echo "=== Step 1/3: Enable sUSDe vault as controller ==="
CONTROLLERS=$(cast call "$EVC" "getControllers(address)(address[])" "$BOT_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "[]")
if echo "$CONTROLLERS" | grep -qi "$SUSDE_VAULT"; then
    echo "Already enabled. Skipping."
else
    cast send --private-key "$BOT_PRIVATE_KEY" --rpc-url "$RPC_URL" \
        "$EVC" "enableController(address,address)" "$BOT_ADDRESS" "$SUSDE_VAULT"
    echo "Done."
fi

echo ""
echo "=== Step 2/3: Set liquidator as EVC operator ==="
cast send --private-key "$BOT_PRIVATE_KEY" --rpc-url "$RPC_URL" \
    "$EVC" "setAccountOperator(address,address,bool)" "$BOT_ADDRESS" "$CORK_LIQUIDATOR" true
echo "Done."

echo ""
echo "=== Step 3/3: Approve sUSDe for vault repayment ==="
MAX_UINT="0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
cast send --private-key "$BOT_PRIVATE_KEY" --rpc-url "$RPC_URL" \
    "$SUSDE_TOKEN" "approve(address,uint256)" "$SUSDE_VAULT" "$MAX_UINT"
echo "Done."

echo ""
echo "══════════════════════════════════════════════════"
echo "  Setup complete. Run ./run.sh to start the bot."
echo "══════════════════════════════════════════════════"
