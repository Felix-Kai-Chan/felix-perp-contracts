#!/usr/bin/env bash
# 轮询 TRADERS 的仓位，保证金不足时用 signer(#6) 签价、relayer(#0) 调 escapeLiquidate
set -uo pipefail
cd ~/Desktop/felix-perp-core/felix-perp-contracts
[ -f .env ] && { set -a; . .env; set +a; } || true

RPC="${RPC:-http://127.0.0.1:8545}"
DEX="${DEX_ADDR:-0x98b6c0816ffcf4d3876fc9faf16c59eec5c503e0}"
BASE="${BASE_ADDR:-0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1}"
RELAYER_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SIGNER_KEY="${SIGNER_KEY:-0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564c}"
TRADERS="${TRADERS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"   # 空格分隔，接 indexer 后可改为动态注入
POLL="${POLL:-8}"

MM=$(cast call "$DEX" "MAINTENANCE_MARGIN()(uint256)" --rpc-url "$RPC" | cast to-dec)
echo "🔗 DEX=$DEX  MAINTENANCE_MARGIN=$MM"
echo "👛 relayer=$(cast wallet address --private-key "$RELAYER_KEY")  signer=$(cast wallet address --private-key "$SIGNER_KEY")"
echo "🎯 监控: $TRADERS  base=$BASE  每 ${POLL}s；现价取 env PRICE（生产接 indexer）"

sign_price() {   # 输出 "ts sig"
  local price=$1 now; now=$(date +%s)
  local inner; inner=$(cast keccak "$(printf '0x%064x%064x' "$price" "$now")")
  local sig;   sig=$(cast wallet sign --private-key "$SIGNER_KEY" "$inner")
  echo "$now $sig"
}

while true; do
  CUR="${PRICE:-0}"
  for TRADER in $TRADERS; do
    RAW=$(cast call "$DEX" "positions(address,address)(int256,uint256,int256)" "$TRADER" "$BASE" --rpc-url "$RPC" 2>/dev/null)
    [ -z "$RAW" ] && continue
    SZ=$(echo "$RAW" | awk '{print $1}'); ENTRY=$(echo "$RAW" | awk '{print $2}')
    [ "$SZ" = "0" ] && continue
    if [ "$CUR" = "0" ]; then echo "[$(date +%H:%M:%S)] $TRADER size=$SZ 有仓位，但未设 PRICE，跳过"; continue; fi
    BAL=$(cast call "$DEX" "balances(address)(uint256)" "$TRADER" --rpc-url "$RPC" 2>/dev/null); BAL=${BAL:-0}

    LIQ=$(python3 -c "
sz=$SZ;e=$ENTRY;c=$CUR;bal=$BAL;mm=$MM
pnl=(c-e)*sz//10**18; eq=bal+pnl
abs=sz if sz>=0 else -sz; nt=(abs*c//10**18) or 1
print(1 if (eq<=0 or eq*10**18//nt < mm) else 0)")
    [ "$LIQ" = "1" ] || { echo "[$(date +%H:%M:%S)] $TRADER 健康"; continue; }

    read -r NOW SIG <<<"$(sign_price "$CUR")"
    echo "[$(date +%H:%M:%S)] ⚠️ 爆仓 $TRADER  price=$CUR ts=$NOW"
    cast send "$DEX" "escapeLiquidate(address,address,(uint256,uint256,bytes))" \
      "$TRADER" "$BASE" "($CUR,$NOW,$SIG)" \
      --private-key "$RELAYER_KEY" --rpc-url "$RPC"
  done
  sleep "$POLL"
done
