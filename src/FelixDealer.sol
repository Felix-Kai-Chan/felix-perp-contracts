// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ==========================================
// 1. 数据类型库 
// ==========================================
library Types {
    // 订单结构体
    struct Order {
        address maker;      // 订单发起者（也是签名者）
        address taker;      // 对手方地址 (如果是挂单，可为 address(0))
        address baseToken;  // 合约标的 (如 BTC)
        address quoteToken; // 计价货币 (如 USDT)
        bool isLong;        // true=做多 / false=做空
        uint256 price;      // 价格
        uint256 qty;        // 数量
        uint256 nonce;      // 防重放随机数
        uint256 expiry;     // 过期时间
        uint256 feeRate;    // 手续费率
    }

    // 成交明细
    struct Fill {
        uint256 price; // 成交价
        uint256 qty;   // 成交量
    }

    // 用户仓位
    struct Position {
        int256 size;         // 仓位数量 (正数多单，负数空单)
        uint256 entryPrice;  // 开仓均价
        uint256 lastFunding; // 上次结算资金费率时的累积值
    }

    // 资金费率状态
    struct FundingState {
        int256 cumulativeRate; // 累积资金费率
        uint256 lastUpdate;    // 上次更新时间
    }
}

interface IMockOracle {
    function verifyPrice(uint256 price, uint256 timestamp, bytes memory signature) external view returns (bool);
}

// ==========================================
// 2. 核心引擎合约
// ==========================================
contract FelixPerpDEX is EIP712 {
    // ---------- 权限与核心资产 ----------
    address public owner;
    address public relayer;      // 链下撮合引擎的打包地址
    address public escapeKeeper; // 逃生舱/清算机器人
    address public quoteToken;   // 结算代币 (如 USDT)
    IMockOracle public oracle;   // 预言机

    // ---------- 账本 ----------
    // 记录订单状态: 0=未使用, 2=已成交
    mapping(bytes32 => uint8) public orderStatus;
    // 用户各币种的仓位: user => baseToken => Position
    mapping(address => mapping(address => Types.Position)) public positions;
    // 用户余额: user => amount
    mapping(address => uint256) public balances;

    // ---------- 保险基金 ----------
    uint256 public insuranceFund;

    // ---------- 参数配置 (均为 1e18 精度) ----------
    uint256 public constant MAINTENANCE_MARGIN = 5e16; // 维持保证金率 5%
    uint256 public constant TARGET_MARGIN = 1e17;      // 目标保证金率 10%
    uint256 public constant LIQUIDATION_FEE = 1e16;     // 清算罚金 1%
    uint256 public constant KEEPER_SHARE = 5e15;        // 给清算人的赏金 0.5%
    uint256 public constant FUNDING_PRECISION = 1e18;

    mapping(address => Types.FundingState) public fundingStates;

    // EIP-712 的 TypeHash 声明
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address baseToken,address quoteToken,bool isLong,uint256 price,uint256 qty,uint256 nonce,uint256 expiry,uint256 feeRate)"
    );

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        bytes signature;
    }

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 liquidatedQty, uint256 penalty, uint256 keeperReward);

    constructor(address _relayer, address _ek, address _quoteToken, address _oracleAddress) EIP712("FelixPerpDEX", "1") {
        owner = msg.sender;
        relayer = _relayer;
        escapeKeeper = _ek;
        quoteToken = _quoteToken;
        oracle = IMockOracle(_oracleAddress);
    }

    // ==========================================
    // 3. 资金操作
    // ==========================================
    function deposit(uint256 amount) external {
        require(amount > 0, "amount must > 0");
        bool success = IERC20(quoteToken).transferFrom(msg.sender, address(this), amount);
        require(success, "transferFrom failed");
        balances[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "amount must > 0");
        require(balances[msg.sender] >= amount, "insufficient balance");
        // Checks-Effects-Interactions 模式，防止重入攻击
        balances[msg.sender] -= amount;
        bool success = IERC20(quoteToken).transfer(msg.sender, amount);
        require(success, "transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    // ==========================================
    // 4. 仓位更新 (核心数学逻辑)
    // ==========================================
    function _updatePosition(address user, address base, bool isLong, uint256 price, uint256 qty) internal {
        Types.Position storage p = positions[user][base];
        _settleFunding(user, base);

        int256 signedQty = isLong ? int256(qty) : -int256(qty);

        // 情况 A: 空仓或者同向加仓 (例如原本就是多单，继续买多)
        if (p.size == 0 || (p.size > 0) == isLong) {
            uint256 oldAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
            uint256 newAbs = oldAbs + qty;
            // 摊薄开仓均价: (旧均价 * 旧数量 + 新价格 * 新数量) / 总数量
            p.entryPrice = (p.entryPrice * oldAbs + price * qty) / newAbs;
            p.size += signedQty;
        } 
        // 情况 B: 反向减仓或反手 (例如原本是多单，现在卖出)
        else {
            uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);

            if (qty <= posAbs) {
                // B1: 部分或全部平仓，结算已实现盈亏 (PnL)
                int256 pnl;
                if (p.size > 0) {
                    // 多单平仓: (卖出价 - 开仓价) * 数量
                    pnl = int256(price * qty / 1e18) - int256(p.entryPrice * qty / 1e18);
                } else {
                    // 空单平仓: (开仓价 - 买入价) * 数量
                    pnl = int256(p.entryPrice * qty / 1e18) - int256(price * qty / 1e18);
                }
                // 更新余额
                if (pnl > 0) {
                    balances[user] += uint256(pnl);
                } else {
                    balances[user] -= uint256(-pnl);
                }
                p.size += signedQty;
                if (p.size == 0) p.entryPrice = 0; // 平仓后清空均价
            } else {
                // B2: 穿仓反手 (例如原本有多单 1 个，现在卖空 2 个)
                // 先结算原有 1 个多单的盈亏
                int256 pnl;
                if (p.size > 0) {
                    pnl = int256(price * posAbs / 1e18) - int256(p.entryPrice * posAbs / 1e18);
                } else {
                    pnl = int256(p.entryPrice * posAbs / 1e18) - int256(price * posAbs / 1e18);
                }
                if (pnl > 0) balances[user] += uint256(pnl);
                else balances[user] -= uint256(-pnl);

                // 剩下的数量建立反向新仓位
                uint256 remainQty = qty - posAbs;
                p.size = isLong ? int256(remainQty) : -int256(remainQty);
                p.entryPrice = price; // 新仓位的均价就是当前成交价
            }
        }
    }

    // ==========================================
    // 5. 清算引擎 (Keeper 触发)
    // ==========================================
    function escapeLiquidate(address user, address base, PriceData calldata priceData) external {
        require(msg.sender == escapeKeeper || msg.sender == relayer, "only EK or relayer");
        require(oracle.verifyPrice(priceData.price, priceData.timestamp, priceData.signature), "Invalid Oracle Sig");
        
        uint256 currentPrice = priceData.price;
        Types.Position storage p = positions[user][base];
        require(p.size != 0, "no position");

        uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
        int256 pnl = _calcPnl(p.size, p.entryPrice, posAbs, currentPrice);
        int256 equity = int256(balances[user]) + pnl; // 账户权益 = 余额 + 未实现盈亏
        
        uint256 currentNotional = posAbs * currentPrice / 1e18;
        if (currentNotional == 0) currentNotional = 1; // 防止除零

        // 核心判断：权益 <= 0 或者 保证金率 < 维持保证金率，则允许强平
        require(equity <= 0 || (uint256(equity) * 1e18 / currentNotional < MAINTENANCE_MARGIN), "still safe, cannot liquidate");

        // 如果资不抵债，直接穿仓，由保险基金兜底
        if (equity <= 0) {
            uint256 deficit = uint256(-equity);
            if (insuranceFund >= deficit) {
                insuranceFund -= deficit;
            } else {
                insuranceFund = 0; 
            }
            balances[user] = 0;
            p.size = 0;
            p.entryPrice = 0;
            emit Liquidated(user, posAbs, 0, 0);
            return;
        }

        // 部分强平计算
        uint256 liquidateQty = _calcLiquidateQty(posAbs, uint256(equity), currentPrice);
        _applyLiquidationPenalty(user, liquidateQty, currentPrice);

        if (p.size > 0) {
            p.size -= int256(liquidateQty);
        } else {
            p.size += int256(liquidateQty);
        }
        if (p.size == 0) p.entryPrice = 0;

        emit Liquidated(user, liquidateQty, 0, 0);
    }

    function _calcPnl(int256 size, uint256 entryPrice, uint256 posAbs, uint256 currentPrice) internal pure returns (int256) {
        if (size > 0) {
            return int256(currentPrice * posAbs / 1e18) - int256(entryPrice * posAbs / 1e18);
        } else {
            return int256(entryPrice * posAbs / 1e18) - int256(currentPrice * posAbs / 1e18);
        }
    }

    function _calcLiquidateQty(uint256 posAbs, uint256 equity, uint256 currentPrice) internal pure returns (uint256) {
        if (currentPrice == 0) return posAbs;
        // 目标保证金率 10%，即权益是名义价值的 10%，反推目标名义价值
        uint256 targetNotional = equity * 10;
        uint256 targetPosAbs = targetNotional * 1e18 / currentPrice;
        uint256 liquidateQty = posAbs > targetPosAbs ? posAbs - targetPosAbs : posAbs;
        return liquidateQty > posAbs ? posAbs : liquidateQty;
    }

    function _applyLiquidationPenalty(address user, uint256 liquidateQty, uint256 currentPrice) internal {
        uint256 liquidatedNotional = liquidateQty * currentPrice / 1e18;
        uint256 penalty = liquidatedNotional * LIQUIDATION_FEE / 1e18;
        uint256 keeperReward = liquidatedNotional * KEEPER_SHARE / 1e18;

        balances[user] -= penalty; // 扣除用户罚金
        balances[msg.sender] += keeperReward; // 给清算人赏金
        insuranceFund += (penalty - keeperReward); // 剩余进保险基金
    }

    // ==========================================
    // 6. 撮合结算 (Relayer 调用，核心验签入口)
    // ==========================================
    function settle(
        Types.Order[] calldata makers,
        bytes[] calldata makerSigs,
        Types.Order[] calldata takers,
        bytes[] calldata takerSigs,
        Types.Fill[] calldata fills
    ) external {
        require(msg.sender == relayer, "only relayer");
        require(makers.length == fills.length, "length mismatch");

        for (uint256 i = 0; i < fills.length; i++) {
            Types.Order calldata m = makers[i];
            
            // 1. 校验 Maker
            require(m.maker != address(0), "invalid maker");
            bytes32 mh = _hashOrder(m);
            require(orderStatus[mh] == 0, "maker order used");
            require(_verifyOrder(m, makerSigs[i]), "bad maker sig");
            orderStatus[mh] = 2; // 标记已用

            // 2. 校验 Taker (如果存在)
            if (takers.length > i && takers[i].maker != address(0)) {
                Types.Order calldata t = takers[i];
                
                // 【修复 BUG】：检查是否自成交
                require(m.maker != t.maker, "self trade not allowed");
                
                // 【修复 BUG】：检查方向是否相反（一买一卖）
                require(m.isLong != t.isLong, "maker and taker must be opposite sides");
                
                bytes32 th = _hashOrder(t);
                require(orderStatus[th] == 0, "taker order used");
                require(_verifyOrder(t, takerSigs[i]), "bad taker sig");
                orderStatus[th] = 2;

                // 更新 Taker 仓位
                _updatePosition(t.maker, t.baseToken, t.isLong, fills[i].price, fills[i].qty);
                _isAllSafe(t.maker, t.baseToken);
            }

            // 更新 Maker 仓位
            _updatePosition(m.maker, m.baseToken, m.isLong, fills[i].price, fills[i].qty);
            _isAllSafe(m.maker, m.baseToken);
        }
    }

    function _isAllSafe(address user, address base) public view {
        Types.Position storage p = positions[user][base];
        if (p.size == 0) return;
        uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
        uint256 notional = posAbs * p.entryPrice / 1e18; 
        if (notional == 0) return;
        uint256 equity = balances[user];
        require(equity * 1e18 / notional >= MAINTENANCE_MARGIN, "unsafe position: liquidatable");
    }

    // ==========================================
    // 7. EIP-712 验签与资金费率
    // ==========================================
    function _hashOrder(Types.Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.maker, o.taker, o.baseToken, o.quoteToken,
            o.isLong, o.price, o.qty, o.nonce, o.expiry, o.feeRate
        )));
    }

    function _verifyOrder(Types.Order calldata o, bytes calldata sig) internal view returns (bool) {
        if (block.timestamp > o.expiry) return false;
        bytes32 h = _hashOrder(o);
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(h, sig);
        return err == ECDSA.RecoverError.NoError && recovered == o.maker;
    }

    function updateFundingRate(address base, int256 ratePerSec) external {
        require(msg.sender == relayer, "only relayer");
        Types.FundingState storage fs = fundingStates[base];
        if (fs.lastUpdate > 0) {
            uint256 timeElapsed = block.timestamp - fs.lastUpdate;
            fs.cumulativeRate += ratePerSec * int256(timeElapsed);
        }
        fs.lastUpdate = block.timestamp;
    }

    function _settleFunding(address user, address base) internal {
        Types.FundingState storage fs = fundingStates[base];
        Types.Position storage p = positions[user][base];
        if (p.size == 0 || fs.lastUpdate == 0) return;

        int256 rateDelta = fs.cumulativeRate - int256(p.lastFunding);
        int256 fundingDebt = rateDelta * p.size / 1e18;

        if (fundingDebt > 0) {
            balances[user] -= uint256(fundingDebt);
        } else if (fundingDebt < 0) {
            balances[user] += uint256(-fundingDebt);
        }
        p.lastFunding = uint256(fs.cumulativeRate);
    }
}