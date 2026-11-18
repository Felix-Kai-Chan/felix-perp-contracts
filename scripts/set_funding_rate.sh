#!/usr/bin/env bash
set -uo pipefail

BASE_ADDR="0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1"
RPC="http://127.0.0.1:8545"

# 默认 ratePerSec = 1e9（按 FUNDING_PRECISION 的精度，通常是 1e18）
RATE="${1:-1000000000}"

cd ~/Desktop/felix-perp-core/felix-perp-contracts
set -a; . .env; set +a

echo "📌 DEX=$DEX_ADDR  base=$BASE_ADDR  ratePerSec=$RATE"
echo ""

# 1) 调用 updateFundingRate
echo "⚙️  设置费率..."
cast send "$DEX_ADDR" \
  "updateFundingRate(address,int256)" \
  "$BASE_ADDR" "$RATE" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC"

echo ""

# 2) 读回验证
echo "📊 fundingStates (cumulativeRate, lastUpdate):"
cast call "$DEX_ADDR" "fundingStates(address)(int256,uint256)" \
  "$BASE_ADDR" --rpc-url "$RPC"

echo ""
echo "✅ 费率已设置。重启 daemon 后 cumulativeRate 会开始累积。"
