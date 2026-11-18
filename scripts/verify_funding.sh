#!/usr/bin/env bash
set -euo pipefail

# ========== 配置 ==========
DEX_ADDR="${DEX_ADDR}"
BASE_ADDR="0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1"
RPC_URL="${RPC_URL:-http://localhost:8545}"
WAIT_SEC="${FUNDING_INTERVAL_SEC:-60}"
# ==========================

# 1. 校验环境
if [ -z "$DEX_ADDR" ]; then
  echo "❌ 错误: DEX_ADDR 未设置，请先在 contracts 目录执行: set -a; . ./.env; set +a"
  exit 1
fi

echo "📌 DEX      = $DEX_ADDR"
echo "📌 Base     = $BASE_ADDR"
echo "📌 RPC      = $RPC_URL"
echo "📌 间隔     = ${WAIT_SEC}s"
echo ""

# 2. 第一次查询
echo "⏱️  第 1 次查询 fundingStates..."
OUT1=$(cast call "$DEX_ADDR" "fundingStates(address)(int256,uint256)" "$BASE_ADDR" --rpc-url "$RPC_URL" 2>&1)
echo "   结果: $OUT1"

# 解析两个值
RATE1=$(echo "$OUT1" | awk '{print $1}')
TS1=$(echo "$OUT1" | awk '{print $2}')
echo "   cumulativeRate = $RATE1"
echo "   lastUpdate     = $TS1"
echo ""

# 3. 等待
echo "⏳ 等待 ${WAIT_SEC} 秒，让 daemon 跑一个周期..."
sleep "$WAIT_SEC"
echo ""

# 4. 第二次查询
echo "⏱️  第 2 次查询 fundingStates..."
OUT2=$(cast call "$DEX_ADDR" "fundingStates(address)(int256,uint256)" "$BASE_ADDR" --rpc-url "$RPC_URL" 2>&1)
echo "   结果: $OUT2"

RATE2=$(echo "$OUT2" | awk '{print $1}')
TS2=$(echo "$OUT2" | awk '{print $2}')
echo "   cumulativeRate = $RATE2"
echo "   lastUpdate     = $TS2"
echo ""

# 5. 对比
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$TS1" != "$TS2" ]; then
  echo "✅ lastUpdate 已更新: $TS1 → $TS2（daemon 正常工作）"
else
  echo "❌ lastUpdate 未变化，daemon 可能没在跑"
fi

if [ "$RATE1" != "$RATE2" ]; then
  echo "✅ cumulativeRate 在累积: $RATE1 → $RATE2（费率生效）"
else
  echo "⚠️  cumulativeRate 未变化（可能 ratePerSec=0，属正常）"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SCRIPT

chmod +x scripts/verify_funding.sh
echo "✅ 脚本已创建: scripts/verify_funding.sh"