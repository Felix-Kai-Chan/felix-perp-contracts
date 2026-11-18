#!/usr/bin/env bash
set -uo pipefail

DEX_ADDR="${DEX_ADDR}"
BASE_ADDR="0xB7A5bd0345EF1Cc730D2dCbD26f610E8B3b4B7A1"
RPC="http://127.0.0.1:8545"

echo "🔍 DEX_ADDR = $DEX_ADDR"
echo ""

# 1) 找 ABI 文件
echo "=== 1. 查找 FelixPerpDEX ABI ==="
ABI_FILE=$(find out -name "FelixPerpDEX.json" -type f 2>/dev/null | head -1)
if [ -z "$ABI_FILE" ]; then
  echo "❌ 未找到 FelixPerpDEX.json，先跑一次 forge build"
  echo "   执行: cd ~/Desktop/felix-perp-core/felix-perp-contracts && forge build"
else
  echo "✅ ABI: $ABI_FILE"
  echo ""
  echo "=== 2. 合约中的 funding 相关函数 ==="
  python3 -c "
import json,sys
abi=json.load(open('$ABI_FILE'))['abi']
for f in abi:
    if f.get('type')!='function': continue
    name=f['name']
    ins=','.join(i['type'] for i in f.get('inputs',[]))
    outs=','.join(o['type'] for o in f.get('outputs',[]))
    sm=f.get('stateMutability','')
    if 'fund' in name.lower() or 'rate' in name.lower() or 'param' in name.lower():
        print(f'{name}({ins}) -> ({outs})   [{sm}]')
"
fi
echo ""

# 3) 直接读链上 selector，确认哪些函数真实存在
echo "=== 3. 链上 selector 探测 ==="
for sig in \
  "setFundingParams(address,uint256,uint256,uint256)" \
  "setFundingParams(address,uint256,uint256)" \
  "setFundingRate(address,uint256)" \
  "setFundingRate(uint256)" \
  "updateFunding(address)" \
  "updateFunding()" \
  "fundingParams(address)" \
  "fundingStates(address)" \
  "fundingRate(address)" \
  "ratePerSec(address)"; do
  sel=$(cast calldata "$sig" 2>/dev/null)
  code=$(cast call "$DEX_ADDR" "$sel" --rpc-url "$RPC" 2>&1)
  if echo "$code" | grep -q "reverted"; then
    status="❌ revert"
  else
    status="✅ 存在: $code"
  fi
  echo "  $sig  →  $status"
done
echo ""

# 4) 看合约 owner / relayer 是谁
echo "=== 4. 权限检查 ==="
for sig in "owner()" "relayer()" "RELAYER()"; do
  val=$(cast call "$DEX_ADDR" "$sig" --rpc-url "$RPC" 2>&1)
  echo "  $sig = $val"
done
echo "  当前钱包 = $(cast wallet address --private-key "$PRIVATE_KEY")"
SCRIPT