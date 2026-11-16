# FelixPerpDEX

链下撮合（CEX 风格订单簿）+ 链上结算的永续合约协议。Relayer 批量推送签名订单到链上，合约负责验签、仓位更新、资金费率、清算与结算，event 供 keeper / indexer 同步链下状态。


## 架构
```
┌─────────────┐ 签名订单 ┌──────────────┐ settle(txs) ┌──────────────┐
│ CEX 订单簿  │ ─────────▶│   Relayer   │ ────────────▶│ FelixPerpDEX │
│ (链下撮合)  │           │ (批量打包)  │             │ (链上结算)   │
└─────────────┘           └──────────────┘             └──────┬───────┘
                                                             │ events
                                                             ▼
                                                    ┌──────────────┐
                                                    │ Event Keeper │
                                                    │   + Indexer  │
                                                    └──────────────┘
```

链下：CEX 风格订单簿撮合，生成 maker/taker 订单 + EIP-712 签名
Relayer：批量调用 settle ()，一次提交多笔 fill
链上：验签 → 更新仓位 → 结算 PnL → 检查保证金 → 发 event
链下同步：keeper 监听 Liquidated / Deposit / Withdraw 等 event，indexer 重建状态

## 快速开始

```
# 安装依赖
forge install
# 编译
forge build
# 跑全部测试
forge test
# 跑 CI 配置（更多 fuzz runs）
forge test --profile ci
# 看 gas 报告
forge test --gas-report
```

## 测试与安全

完整的测试体系、已修复的高危问题、已知未覆盖项，见 docs/SECURITY_REVIEW.md。

速览：

- 19 个测试（16 定向 + 2 invariant + 1 重入），全部通过
- 12800 次随机调用，0 revert，总账守恒 + 偿付能力 invariant 真覆盖
- 5 个高危问题已修复（P0 × 3，P1 × 2），全部有定向测试闭环验证

## 目录结构

```
src/
  FelixDealer.sol      # 核心合约：仓位 / 清算 / 资金费率 / 结算
  Types.sol            # 数据结构定义
  MockOracle.sol       # 价格签名验证（测试用）
  MockERC20.sol        # 测试用 ERC20
  IMockOracle.sol      # Oracle 接口

test/
  FelixDealer.t.sol    # 16 个定向测试
  Invariant.t.sol      # 2 个 invariant（总账守恒 + 偿付能力）
  Reentrancy.t.sol     # 重入测试（恶意 ERC20）
  handlers/
    FelixHandler.sol   # 有界 fuzzing handler（双 base）

docs/
  SECURITY_REVIEW.md   # 测试与安全说明（审计入口）
```

## 关键参数

表格

| 参数 | 值 | 说明 |
| --- | --- | --- |
| MAINTENANCE_MARGIN | 5% | 维持保证金率，低于此可清算 |
| TARGET_MARGIN | 10% | 清算后目标保证金率 |
| LIQUIDATION_FEE | 1% | 清算罚金 |
| KEEPER_SHARE | 0.5% | 给清算人的赏金（占名义价值） |

## 开发命令

```
forge build      # 编译
forge test       # 跑测试
forge fmt        # 格式化
forge snapshot   # gas 快照
anvil            # 本地节点
cast             # 链上交互
```

更多 Foundry 用法见 Foundry Book。

许可 MIT