// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarkPriceOracle - 标记价格预言机接口
interface IMarkPriceOracle {
    function getMarkPrice() external view returns (uint256);
    function getMarkMax() external view returns (uint256);
    function getMarkMin() external view returns (uint256);
    /// 安全版：未初始化/过期时不 revert，返回 (0, false)
    function getMarkPriceSafe() external view returns (uint256 price, bool valid);
}

/// @title MarkPriceOracle - 标记价格预言机 (EMA Premium Index)
/// @notice 标记价格 = 指数价格 + EMA(基差)，带宽保护 +/-0.5%
/// @dev    price-service 每 10 秒调用 update()
contract MarkPriceOracle is IMarkPriceOracle {
    address public owner;
    address public operator;
    uint256 public maxAge = 30;
    uint256 private _emaN = 10;

    uint256 private _mark;
    uint256 private _max;
    uint256 private _min;
    uint256 private _updatedAt;
    int256  private _ema;

    event PriceUpdated(uint256 mark, uint256 max, uint256 min, uint256 indexed ts);
    event OperatorUpdated(address indexed oldOp, address indexed newOp);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier onlyOperator() { require(msg.sender == operator, "not operator"); _; }

    constructor() {
        owner = msg.sender;
        operator = msg.sender;
    }

    function update(uint256 index, uint256 last) external onlyOperator {
        require(index > 0, "zero index");
        require(last > 0, "zero last");

        int256 premium = int256(last) - int256(index);
        _ema = (_ema * int256(_emaN - 1) + premium) / int256(_emaN);

        int256 markInt = int256(index) + _ema;
        if (markInt <= 0) { markInt = int256(index / 10); }
        _mark = uint256(markInt);

        uint256 band = _mark * 50 / 10000;
        _max = _mark + band;
        _min = band < _mark ? _mark - band : 1;

        _updatedAt = block.timestamp;
        emit PriceUpdated(_mark, _max, _min, block.timestamp);
    }

    function getMarkPrice() external view returns (uint256) { _check(); return _mark; }
    function getMarkMax()   external view returns (uint256) { _check(); return _max; }
    function getMarkMin()   external view returns (uint256) { _check(); return _min; }

    function getMarkPriceSafe() external view returns (uint256 price, bool valid) {
        if (_mark == 0) return (0, false);
        if (block.timestamp - _updatedAt > maxAge) return (_mark, false);
        return (_mark, true);
    }

    function setOperator(address op) external onlyOwner {
        require(op != address(0), "zero"); emit OperatorUpdated(operator, op); operator = op;
    }
    function setMaxAge(uint256 age) external onlyOwner {
        require(age > 0 && age <= 600, "range"); maxAge = age;
    }
    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "zero"); owner = n;
    }

    function _check() private view {
        require(_mark > 0, "not init");
        require(block.timestamp - _updatedAt <= maxAge, "stale");
    }
}