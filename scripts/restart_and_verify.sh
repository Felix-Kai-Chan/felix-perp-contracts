#!/usr/bin/env bash
set -uo pipefail

ROOT=~/Desktop/felix-perp-core
CONTRACTS=$ROOT/felix-perp-contracts
ENGINE=$ROOT/felix-perp-engine
BASE_ADDR="0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FelixPerp  Funding 一键重启+验证"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. 杀旧 daemon ──
echo "🔪 停止旧 funding_updater..."
pkill -f funding_updater 2>/dev/null || true
sleep 2
LEFT=$(pgrep -f funding_updater | wc -l)
if [ "$LEFT" -gt 0 ]; then
  echo "⚠️  还有进程残留，强制杀..."
  pkill -9 -f funding_updater 2>/dev/null || true
  sleep 1
fi
echo "   已清理"
echo ""

# ── 2. 校验地址 ──
echo "🔍 校验 DEX_ADDR..."
cd "$CONTRACTS"
set -a; . .env; set +a

if [ -z "$DEX_ADDR" ]; then
  echo "❌ DEX_ADDR 为空"; exit 1
fi
if [ "${#DEX_ADDR}" -ne 42 ]; then
  echo "❌ DEX_ADDR 长度=${#DEX_ADDR}（应为42）: $DEX_ADDR"
  echo "   请从 broadcast/Deploy.s.sol/31337/run-latest.json 取 FelixPerpDEX 地址回填 .env"
  exit 1
fi
echo "   DEX_ADDR=$DEX_ADDR  ✅"

# 确认合约已部署
CODE=$(cast get-code "$DEX_ADDR" --rpc-url http://127.0.0.1:8545 2>&1)
if [ "$CODE" = "0x" ]; then
  echo "❌ 该地址无合约代码，地址可能不对或 anvil 未启动"
  exit 1
fi
echo "   合约代码存在 ✅"
echo ""

# ── 3. 重启 daemon ──
echo "🚀 启动 funding_updater..."
cd "$ENGINE"
set -a; . .env; set +a

if [ "$DEX_ADDR" != "$(cd "$CONTRACTS" && set -a; . .env >/dev/null 2>&1; set +a; echo "$DEX_ADDR")" ]; then
  echo "⚠️  engine/.env 与 contracts/.env 的 DEX_ADDR 不一致，以 engine 为准"
fi

# 后台跑，日志写文件，避免卡住
nohup go run ./cmd/funding_updater > /tmp/funding_updater.log 2>&1 &
DAEMON_PID=$!
echo "   PID=$DAEMON_PID"
echo "   日志: /tmp/funding_updater.log"

# 等 daemon 起来
echo "   等待 daemon 启动..."
for i in $(seq 1 10); do
  if grep -q "started" /tmp/funding_updater.log 2>/dev/null; then
    echo "   daemon 已就绪 ✅"
    break
  fi
  sleep 1
done
echo ""

# ── 4. 等一个 funding 周期 ──
WAIT=${FUNDING_INTERVAL_SEC:-60}
echo "⏳ 等待 ${WAIT}s，让 daemon 跑一个 tick..."
sleep "$WAIT"
echo ""

# ── 5. 验证 ──
echo "📊 查询 fundingStates（两次，间隔 5 秒）..."
cd "$CONTRACTS"
set -a; . .env; set +a

query() {
  local raw
  raw=$(cast call "$DEX_ADDR" "fundingStates(address)(int256,uint256)" "$BASE_ADDR" --rpc-url http://127.0.0.1:8545 2>&1) || { echo "❌ cast 失败: $raw"; exit 1; }
  local rate ts
  rate=$(echo "$raw" | tr '\n' ' ' | awk '{print $1}')
  ts=$(echo "$raw"   | tr '\n' ' ' | awk '{print $2}')
  echo "$rate $ts"
}

read R1 T1 <<< "$(query)"
echo "   T0: cumulativeRate=$R1  lastUpdate=$T1"
sleep 5
read R2 T2 <<< "$(query)"
echo "   T5: cumulativeRate=$R2  lastUpdate=$T2"
echo ""

# ── 6. 报告 ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$T1" != "$T2" ] && [ -n "$T1" ] && [ -n "$T2" ]; then
  echo "✅ lastUpdate 已更新: $T1 → $T2"
  echo "   funding daemon 正常工作"
else
  echo "❌ lastUpdate 未变化 ($T1 → $T2)"
  echo "   请检查 daemon 日志: tail -20 /tmp/funding_updater.log"
fi

if [ "$R1" != "$R2" ]; then
  echo "✅ cumulativeRate 在累积: $R1 → $R2"
else
  echo "⚠️  cumulativeRate 未变（ratePerSec=0 时正常）"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 附上 daemon 日志最后 10 行
echo ""
echo "📄 daemon 最新日志:"
tail -10 /tmp/funding_updater.log 2>/dev/null || echo "   (无日志)"
