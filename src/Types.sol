// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Types {
    struct Order {
        address maker;
        address taker;
        address baseToken;
        address quoteToken;
        bool isLong;
        uint256 price;
        uint256 qty;
        uint256 nonce;
        uint256 expiry;
        uint256 feeRate;
    }

    struct Fill {
        uint256 price;
        uint256 qty;
    }

    struct Position {
        int256 size;
        uint256 entryPrice;
        // ===== P1-2 FIX: uint256 → int256，支持负资金费率累积 =====
        int256 lastFunding;
        // ==========================================================
    }

    struct FundingState {
        int256 cumulativeRate;
        uint256 lastUpdate;
    }

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        bytes signature;
    }
}