
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./Types.sol";
import "./IMockOracle.sol";

// ==========================================
// 2. 核心引擎合约
// ==========================================
contract FelixPerpDEX is EIP712 {
    // ---------- 权限与核心资产 ----------
    address public owner;
    address public relayer;
    address public escapeKeeper;
    address public quoteToken;
    IMockOracle public oracle;

    // ---------- 账本 ----------
    mapping(bytes32 => uint8) public orderStatus;
    mapping(address => mapping(address => Types.Position)) public positions;
    mapping(address => uint256) public balances;

    // ===== P0 FIX 1: 新增映射，记录用户参与过的 baseToken =====
    mapping(address => address[]) public userBases;
    mapping(address => mapping(address => bool)) public hasBase;
    // ==========================================================

    // ---------- 保险基金 ----------
    uint256 public insuranceFund;
    uint256 public fundingPool;

    // ---------- 参数配置 (均为 1e18 精度) ----------
    uint256 public constant MAINTENANCE_MARGIN = 5e16;
    uint256 public constant TARGET_MARGIN = 1e17;
    uint256 public constant LIQUIDATION_FEE = 1e16;
    uint256 public constant KEEPER_SHARE = 5e15;
    uint256 public constant FUNDING_PRECISION = 1e18;

    mapping(address => Types.FundingState) public fundingStates;

    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address baseToken,address quoteToken,bool isLong,uint256 price,uint256 qty,uint256 nonce,uint256 expiry,uint256 feeRate)"
    );

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 liquidatedQty, uint256 penalty, uint256 keeperReward);
    event Cancelled(bytes32 indexed orderHash, address indexed maker);

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

        // ===== P0 FIX 3: 有未平仓位时禁止提款 =====
        _requireNoOpenPositions(msg.sender);
        // ==========================================

        balances[msg.sender] -= amount;
        bool success = IERC20(quoteToken).transfer(msg.sender, amount);
        require(success, "transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    function _requireNoOpenPositions(address user) internal view {
        address[] storage bs = userBases[user];
        for (uint256 i = 0; i < bs.length; i++) {
            Types.Position storage p = positions[user][bs[i]];
            require(p.size == 0, "close positions first");
        }
    }

    // ==========================================
    // 4. 仓位更新
    // ==========================================
    function _updatePosition(address user, address base, bool isLong, uint256 price, uint256 qty) internal {
        // ===== P0 FIX 2: 登记用户参与过的 baseToken =====
        if (!hasBase[user][base]) {
            hasBase[user][base] = true;
            userBases[user].push(base);
        }
        // ==============================================

        Types.Position storage p = positions[user][base];
        _settleFunding(user, base);

        int256 signedQty = isLong ? int256(qty) : -int256(qty);

        if (p.size == 0 || (p.size > 0) == isLong) {
            uint256 oldAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
            uint256 newAbs = oldAbs + qty;
            p.entryPrice = (p.entryPrice * oldAbs + price * qty) / newAbs;
            p.size += signedQty;
        } else {
            uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);

            if (qty <= posAbs) {
                int256 pnl;
                if (p.size > 0) {
                    pnl = int256(price * qty / 1e18) - int256(p.entryPrice * qty / 1e18);
                } else {
                    pnl = int256(p.entryPrice * qty / 1e18) - int256(price * qty / 1e18);
                }
                if (pnl > 0) {
                    balances[user] += uint256(pnl);
                } else {
                    balances[user] -= uint256(-pnl);
                }
                p.size += signedQty;
                if (p.size == 0) p.entryPrice = 0;
            } else {
                int256 pnl;
                if (p.size > 0) {
                    pnl = int256(price * posAbs / 1e18) - int256(p.entryPrice * posAbs / 1e18);
                } else {
                    pnl = int256(p.entryPrice * posAbs / 1e18) - int256(price * posAbs / 1e18);
                }
                if (pnl > 0) balances[user] += uint256(pnl);
                else balances[user] -= uint256(-pnl);

                uint256 remainQty = qty - posAbs;
                p.size = isLong ? int256(remainQty) : -int256(remainQty);
                p.entryPrice = price;
            }
        }
    }

    // ==========================================
    // 5. 清算引擎
    // ==========================================
    function escapeLiquidate(address user, address base, Types.PriceData calldata priceData) external {
        require(msg.sender == escapeKeeper || msg.sender == relayer, "only EK or relayer");
        require(oracle.verifyPrice(priceData.price, priceData.timestamp, priceData.signature), "Invalid Oracle Sig");

        uint256 currentPrice = priceData.price;
        Types.Position storage p = positions[user][base];
        require(p.size != 0, "no position");

        uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
        int256 pnl = _calcPnl(p.size, p.entryPrice, posAbs, currentPrice);
        int256 equity = int256(balances[user]) + pnl;

        uint256 currentNotional = posAbs * currentPrice / 1e18;
        if (currentNotional == 0) currentNotional = 1;

        require(equity <= 0 || (uint256(equity) * 1e18 / currentNotional < MAINTENANCE_MARGIN), "still safe, cannot liquidate");

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

        uint256 liquidateQty = _calcLiquidateQty(posAbs, uint256(equity), currentPrice);

        int256 liqPnl;
        if (p.size > 0) {
            liqPnl = int256(currentPrice * liquidateQty / 1e18) - int256(p.entryPrice * liquidateQty / 1e18);
        } else {
            liqPnl = int256(p.entryPrice * liquidateQty / 1e18) - int256(currentPrice * liquidateQty / 1e18);
        }
        if (liqPnl < 0) {
            uint256 loss = uint256(-liqPnl);
            if (balances[user] >= loss) {
                balances[user] -= loss;
            } else {
                balances[user] = 0;
            }
        } else {
            balances[user] += uint256(liqPnl);
        }

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

    // ===== P1-1 FIX: 用 TARGET_MARGIN 常量表达，语义清晰 =====
    function _calcLiquidateQty(uint256 posAbs, uint256 equity, uint256 currentPrice) internal pure returns (uint256) {
        if (currentPrice == 0) return posAbs;
        // 目标：清算后剩余仓位保证金率 = TARGET_MARGIN（10%）
        // targetNotional = equity / TARGET_MARGIN = equity * 1e18 / 1e17 = equity * 10
        uint256 targetNotional = equity * 1e18 / TARGET_MARGIN;
        uint256 targetPosAbs = targetNotional * 1e18 / currentPrice;
        uint256 liquidateQty = posAbs > targetPosAbs ? posAbs - targetPosAbs : posAbs;

        if (liquidateQty == 0 && posAbs > 0) {
            return posAbs;
        }
        return liquidateQty > posAbs ? posAbs : liquidateQty;
    }
    // ======================================================

    // ===== P1-4 FIX: 余额不足时不得凭空给 keeper/保险基金加钱 =====
    function _applyLiquidationPenalty(address user, uint256 liquidateQty, uint256 currentPrice) internal {
        uint256 liquidatedNotional = liquidateQty * currentPrice / 1e18;
        uint256 penalty = liquidatedNotional * LIQUIDATION_FEE / 1e18;
        uint256 keeperReward = liquidatedNotional * KEEPER_SHARE / 1e18;

        if (balances[user] >= penalty) {
            balances[user] -= penalty;
            balances[msg.sender] += keeperReward;
            insuranceFund += (penalty - keeperReward);
        } else {
            // 用户余额不足：全额没收，不进 keeper/保险基金，避免凭空造币
            balances[user] = 0;
        }
    }
    // ==========================================================

    // ==========================================
    // 6. 撮合结算
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
        // ===== P1-3 FIX: taker 数组长度对齐校验 =====
        require(takers.length == takerSigs.length, "taker arrays mismatch");
        // ==========================================

        for (uint256 i = 0; i < fills.length; i++) {
            Types.Order calldata m = makers[i];

            require(m.maker != address(0), "invalid maker");
            bytes32 mh = _hashOrder(m);
            require(orderStatus[mh] == 0, "maker order used");
            require(_verifyOrder(m, makerSigs[i]), "bad maker sig");
            orderStatus[mh] = 2;

            if (takers.length > i && takers[i].maker != address(0)) {
                Types.Order calldata t = takers[i];

                require(m.maker != t.maker, "self trade not allowed");
                require(m.isLong != t.isLong, "maker and taker must be opposite sides");

                bytes32 th = _hashOrder(t);
                require(orderStatus[th] == 0, "taker order used");
                require(_verifyOrder(t, takerSigs[i]), "bad taker sig");
                orderStatus[th] = 2;
            }

            _updatePosition(m.maker, m.baseToken, m.isLong, fills[i].price, fills[i].qty);
            _isAllSafe(m.maker, m.baseToken, fills[i].price);

            if (takers.length > i && takers[i].maker != address(0)) {
                Types.Order calldata t = takers[i];
                _updatePosition(t.maker, t.baseToken, t.isLong, fills[i].price, fills[i].qty);
                _isAllSafe(t.maker, t.baseToken, fills[i].price);
            }
        }
    }

    // ==========================================
    // 6.5 撤单（纯新增，settle 本体零改动）
    // ==========================================
    // orderStatus 取值约定：0 = 未使用 / 2 = 已被撮合 / 3 = 已撤单(本函数写入)
    // settle 原本就有 require(orderStatus[mh] == 0, "maker order used")
    //            和      require(orderStatus[th] == 0, "taker order used")
    // 所以 status 一旦置为 3，这张订单在 maker 侧与 taker 侧都永久无法再被结算。
    function cancelOrder(Types.Order calldata o) external {
        require(o.maker == msg.sender, "only maker can cancel");
        bytes32 h = _hashOrder(o);
        require(orderStatus[h] == 0, "order used");
        orderStatus[h] = 3;
        emit Cancelled(h, o.maker);
    }

    function _isAllSafe(address user, address base, uint256 currentPrice) public view {
        Types.Position storage p = positions[user][base];
        if (p.size == 0) return;
        uint256 posAbs = p.size >= 0 ? uint256(p.size) : uint256(-p.size);
        uint256 notional = posAbs * currentPrice / 1e18;
        if (notional == 0) return;

        int256 pnl = _calcPnl(p.size, p.entryPrice, posAbs, currentPrice);
        int256 equity = int256(balances[user]) + pnl;

        require(equity > 0, "account bankrupt");
        require(uint256(equity) * 1e18 / notional >= MAINTENANCE_MARGIN, "unsafe position: liquidatable");
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
        (address recovered, ECDSA.RecoverError err) = ECDSA.tryRecover(h, sig);
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

        // ===== P1-2 FIX: lastFunding 已是 int256，直接相减，不再强转 =====
        int256 rateDelta = fs.cumulativeRate - p.lastFunding;
        int256 fundingDebt = rateDelta * p.size / 1e18;

        if (fundingDebt > 0) {
            uint256 amount = uint256(fundingDebt);
            if (balances[user] >= amount) {
                balances[user] -= amount;
                fundingPool += amount;
            } else {
                fundingPool += balances[user];
                balances[user] = 0;
            }
        } else if (fundingDebt < 0) {
            uint256 amount = uint256(-fundingDebt);
            if (fundingPool >= amount) {
                fundingPool -= amount;
                balances[user] += amount;
            } else {
                balances[user] += fundingPool;
                fundingPool = 0;
            }
        }
        // ===== P1-2 FIX: 直接赋 int256，不再 uint256() 强转（负数不会 panic）=====
        p.lastFunding = fs.cumulativeRate;
        // ======================================================================
    }
}