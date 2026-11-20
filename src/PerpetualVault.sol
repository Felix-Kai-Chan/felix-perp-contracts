// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PerpetualVault — FelixPerp 最简链上结算合约（userId 版）
/// @notice 只做成交记账 + 仓位累计，不含保证金/预言机/强平。测试网验证链路用。
contract PerpetualVault {
    struct Position {
        int128 qty;      // 正=多，负=空（单位：最小精度）
        uint128 avgPrice;
    }

    address public operator;                  // settler 的热钱包地址
    mapping(bytes32 => bool) public settled;  // orderId => 是否已结算（幂等）
    mapping(uint256 => Position) public positions; // userId => 仓位

    event TradeSettled(
        bytes32 indexed orderId,
        uint256 indexed makerId,
        uint256 indexed takerId,
        uint256 price,
        uint256 qty
    );

    error NotOperator();
    error AlreadySettled();

    constructor() {
        operator = msg.sender;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice settler 调用：把一笔链下成交上链定盘
    /// @param orderId 成交唯一 ID（用 fill_id 的 bytes32）
    /// @param makerId maker 的 user_id
    /// @param takerId taker 的 user_id
    function settleTrade(
        bytes32 orderId,
        uint256 makerId,
        uint256 takerId,
        uint256 price,
        uint256 qty
    ) external onlyOperator {
        if (settled[orderId]) revert AlreadySettled();
        settled[orderId] = true;

        // maker 与 taker 方向相反，仓位对称累加
        _applyPosition(makerId, int128(uint128(qty)), price);
        _applyPosition(takerId, -int128(uint128(qty)), price);

        emit TradeSettled(orderId, makerId, takerId, price, qty);
    }

    function _applyPosition(uint256 user, int128 delta, uint256 price) internal {
        Position storage p = positions[user];
        p.avgPrice = uint128(price);
        p.qty += delta;
    }

    function setOperator(address op) external onlyOperator {
        operator = op;
    }
}