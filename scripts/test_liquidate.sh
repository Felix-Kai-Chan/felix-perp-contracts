#!/usr/bin/env bash
# 给一个已存在的仓位，喂一个被砸到爆仓线的合法签名价，验证 escapeLiquidate 成功。
set -uo pipefail
cd ~/Desktop/felix-perp-core/felix-perp-contracts
[ -f .env ] && { set -a; . .env; set +a; } || true
RPC="${RPC:-http://127.0.0.1:8545}"
DEX="${DEX_ADDR:-0x98b6c0816ffcf4d3876fc9faf16c59eec5c503e0}"
BASE="${BASE_ADDR:-0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1}"
RELAYER_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SIGNER_KEY="${SIGNER_KEY:-0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564c}"
TRADER="${1:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

RAW=$(cast call "$DEX" "positions(address,address)(int256,uint256,int256)" "$TRADER" "$BASE" --rpc-url "$RPC")
SZ=$(echo "$RAW" | awk '{print $1}'); ENTRY=$(echo "$RAW" | awk '{print $2}')
if [ "$SZ" = "0" ]; then echo "❌ $TRADER 当前无仓位，先在链上开一笔仓位再跑本脚本"; exit 1; fi
echo "📦 $TRADER size=$SZ entry=$ENTRY"

# 自动选砸价方向：多头把价砸到 1 wei，空头把价拉到 entry*100
if [ "$SZ" -gt 0 ]; then CUR=1; else CUR=$(( ENTRY * 100 )); fi
NOW=$(date +%s)
INNER=$(cast keccak "$(printf '0x%064x%064x' "$CUR" "$NOW")")
SIG=$(cast wallet sign --private-key "$SIGNER_KEY" "$INNER")
echo "💥 砸价 price=$CUR ts=$NOW  (EIP-191 inner=$INNER)"

cast send "$DEX" "escapeLiquidate(address,address,(uint256,uint256,bytes))" \
  "$TRADER" "$BASE" "($CUR,$NOW,$SIG)" \
  --private-key "$RELAYER_KEY" --rpc-url "$RPC"

AFTER=$(cast call "$DEX" "positions(address,address)(int256,uint256,int256)" "$TRADER" "$BASE" --rpc-url "$RPC" | awk '{print $1}')
if [ "$AFTER" = "0" ]; then echo "✅ 清算成功：size 已归零"; else echo "❌ 未清算：size=$AFTER（看上面 tx 是否 revert）"; fi
