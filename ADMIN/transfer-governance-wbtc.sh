#!/usr/bin/env bash
# Retry: transfer eWBTC-16 governance only (eUSDC-127 already done).
set -e
source contracts/mainnet-contracts/.env
cast send 0x915104922E6a55B00B7245d56EE950cd591782C2 "setGovernorAdmin(address)" 0x4f894Bfc9481110278C356adE1473eBe2127Fd3C --rpc-url "$RPC_URL_MAINNET" --account dev
echo
echo "verify:"
cast call 0x915104922E6a55B00B7245d56EE950cd591782C2 "governorAdmin()(address)" --rpc-url "$RPC_URL_MAINNET"
