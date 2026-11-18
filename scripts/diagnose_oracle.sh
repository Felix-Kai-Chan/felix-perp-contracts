#!/usr/bin/env bash
set -uo pipefail
cd ~/Desktop/felix-perp-core/felix-perp-contracts
set -a; . .env; set +a
RPC="http://127.0.0.1:8545"

echo "===== [0] 地址确认 ====="
echo "DEX_ADDR = $DEX_ADDR"
echo "钱包     = $(cast wallet address --private-key "$PRIVATE_KEY")"
echo ""

echo "===== [1] oracle / escapeKeeper 地址 ====="
echo "oracle       = $(cast call "$DEX_ADDR" "oracle()(address)" --rpc-url "$RPC" 2>&1)"
echo "escapeKeeper = $(cast call "$DEX_ADDR" "escapeKeeper()(address)" --rpc-url "$RPC" 2>&1)"
echo "relayer      = $(cast call "$DEX_ADDR" "relayer()(address)" --rpc-url "$RPC" 2>&1)"
echo ""

echo "===== [2] Oracle 合约源码：验签逻辑 ====="
# 找到 Oracle 源文件，打印 verifyPrice / signer / recover / 签名打包相关行
ORACLE_FILE=$(grep -rln "function verifyPrice" src/ | head -1)
echo "Oracle 文件 = $ORACLE_FILE"
echo "--- verifyPrice 完整函数体 ---"
grep -n "function verifyPrice" "$ORACLE_FILE" 2>/dev/null
awk '/function verifyPrice/{f=1} f{print} f&&/^    }/{exit}' "$ORACLE_FILE" 2>/dev/null
echo ""
echo "--- signer / 信任地址 / ecrecover 相关 ---"
grep -nE "signer|Signer|trusted|ecrecover|recover|admin|owner" "$ORACLE_FILE" 2>/dev/null
echo ""
echo "--- 签名消息如何打包（0x19 / Eth Signed / keccak / abi.encode） ---"
grep -nE "0x19|Eth|Signed Message|keccak256|abi.encode|toEthSignedMessage|TextHash" "$ORACLE_FILE" 2>/dev/null
echo ""

echo "===== [3] 如果 oracle 有 sign/submit 函数，看签名入口 ====="
grep -rnE "function.*[Ss]ign|function.*[Pp]rice|submitPrice|updatePrice|postPrice" src/ 2>/dev/null | head -20
echo ""

echo "===== [4] engine 里出价格签名的 Go 代码 ====="
cd ~/Desktop/felix-perp-core/felix-perp-engine 2>/dev/null && \
grep -rniE "func.*[Ss]ign|crypto.Sign|TextHash|PriceData|Signature|0x19|VerifyPrice" --include=*.go . | head -40 || echo "(engine 目录未找到，单独贴 funding_updater 签价格那段)"
