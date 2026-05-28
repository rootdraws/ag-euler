#!/usr/bin/env bash
# Transfer governance of two mainnet vaults from dev wallet to AG Safe.
# Run from repo root:  bash ADMIN/transfer-governance.sh

set -e
source contracts/mainnet-contracts/.env

NEW_GOV=0x4f894Bfc9481110278C356adE1473eBe2127Fd3C

echo "→ eUSDC-127"
cast send 0xb639d1B47215d1Bc6E2d33b299b3F386627c0F2b "setGovernorAdmin(address)" $NEW_GOV --rpc-url "$RPC_URL_MAINNET" --account dev

echo "→ eWBTC-16"
cast send 0x915104922E6a55B00B7245d56EE950cd591782C2 "setGovernorAdmin(address)" $NEW_GOV --rpc-url "$RPC_URL_MAINNET" --account dev

echo
echo "verify:"
cast call 0xb639d1B47215d1Bc6E2d33b299b3F386627c0F2b "governorAdmin()(address)" --rpc-url "$RPC_URL_MAINNET"
cast call 0x915104922E6a55B00B7245d56EE950cd591782C2 "governorAdmin()(address)" --rpc-url "$RPC_URL_MAINNET"
