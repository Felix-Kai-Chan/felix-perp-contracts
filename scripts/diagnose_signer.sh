#!/usr/bin/env bash
set -uo pipefail
cd ~/Desktop/felix-perp-core/felix-perp-contracts
set -a; . .env; set +a
RPC="http://127.0.0.1:8545"
ORACLE="0xb1E0EABe42Ec504E839Df7eE245dFCEeE67b5ce0"

echo "===== [A] MockOracle: hashPrice / getEthSignedHash / verifyPrice 函数体 ====="
# 行号 38/42/47 已知，直接打这段
sed -n '36,95p' src/MockOracle.sol

echo ""
echo "===== [B] oracle.signer() + maxPriceAge ====="
echo "signer      = $(cast call "$ORACLE" 'signer()(address)' --rpc-url "$RPC" 2>&1)"
echo "maxPriceAge = $(cast call "$ORACLE" 'maxPriceAge()(uint256)' --rpc-url "$RPC" 2>&1)"

echo ""
echo "===== [C] .env 里各私钥对应地址（看 signer 命中哪把） ====="
for var in PRIVATE_KEY RELAYER_PRIVATE_KEY ORACLE_PRIVATE_KEY SIGNER_PRIVATE_KEY ORACLE_KEY EK_PRIVATE_KEY KEEPER_PRIVATE_KEY; do
  val=$(printenv "$var"); [ -z "$val" ] && continue
  echo "  $var -> $(cast wallet address --private-key "$val" 2>&1)"
done

echo ""
echo "===== [D] anvil 默认账户 #0~#9（signer 多半是其中之一） ====="
for i in 0 1 2 3 4 5 6 7 8 9; do
  echo "  #$i $(cast wallet address --mnemonic 'test test test test test test test test test test test junk' --mnemonic-index $i 2>&1)"
done
