// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {Types} from "../src/Types.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol"; 

contract FelixPerpDEXTest is Test {
    FelixPerpDEX dex;
    MockOracle oracle;
     MarkPriceOracle markOracle;
    MockERC20 usdt;

    uint256 constant PK_OWNER   = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PK_RELAYER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK_KEEPER  = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK_ALICE   = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant PK_BOB     = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant PK_CAROL   = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 constant PK_SIGNER  = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;

    address owner;
    address relayer;
    address keeper;
    address alice;
    address bob;
    address carol;
    address priceSigner;

    uint256 constant ONE = 1e18;
    uint256 constant BTC_PRICE = 50_000 * ONE;
    uint256 internal nonceCounter;

    bytes32 constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address baseToken,address quoteToken,bool isLong,uint256 price,uint256 qty,uint256 nonce,uint256 expiry,uint256 feeRate)"
    );

    function setUp() public {
        owner       = vm.addr(PK_OWNER);
        relayer     = vm.addr(PK_RELAYER);
        keeper      = vm.addr(PK_KEEPER);
        alice       = vm.addr(PK_ALICE);
        bob         = vm.addr(PK_BOB);
        carol       = vm.addr(PK_CAROL);
        priceSigner = vm.addr(PK_SIGNER);

        vm.startPrank(owner);
        usdt   = new MockERC20();
        oracle = new MockOracle(priceSigner, 3600);
        markOracle = new MarkPriceOracle();
        dex    = new FelixPerpDEX(relayer, keeper, address(usdt), address(oracle), address(markOracle));
        vm.stopPrank();

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            usdt.mint(users[i], 1_000_000 * ONE);
            vm.prank(users[i]);
            usdt.approve(address(dex), type(uint256).max);
        }
        nonceCounter = 1;
    }

    function _getSignerPk(address user) internal pure returns (uint256) {
        if (user == vm.addr(PK_ALICE)) return PK_ALICE;
        if (user == vm.addr(PK_BOB)) return PK_BOB;
        return PK_SIGNER;
    }

    function _signOrder(
        address maker, address taker, address base, bool isLong, uint256 price, uint256 qty, uint256 nonce, uint256 expiry, uint256 feeRate
    ) internal view returns (bytes memory) {
        Types.Order memory o = Types.Order({
            maker: maker, taker: taker, baseToken: base, quoteToken: address(usdt),
            isLong: isLong, price: price, qty: qty, nonce: nonce, expiry: expiry, feeRate: feeRate
        });
        bytes32 structHash = keccak256(abi.encode(ORDER_TYPEHASH, o.maker, o.taker, o.baseToken, o.quoteToken, o.isLong, o.price, o.qty, o.nonce, o.expiry, o.feeRate));
        bytes32 domainSep = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("FelixPerpDEX"), keccak256("1"), block.chainid, address(dex)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_getSignerPk(maker), keccak256(abi.encodePacked("\x19\x01", domainSep, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signPrice(uint256 price, uint256 ts) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encodePacked(price, ts));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_SIGNER, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Deposit_Withdraw() public {
        vm.startPrank(alice);
        dex.deposit(1000 * ONE);
        dex.withdraw(400 * ONE);
        assertEq(dex.balances(alice), 600 * ONE);
        vm.expectRevert("insufficient balance");
        dex.withdraw(1000 * ONE);
        vm.expectRevert("amount must > 0");
        dex.deposit(0);
        vm.stopPrank();
    }

    function test_Position_Lifecycle_And_Reverse() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        (int256 size, uint256 ep, ) = dex.positions(alice, base);
        assertEq(size, int256(1 * ONE));
        assertEq(ep, 50_000 * ONE);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 60_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 60_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 60_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 60_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(60_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        (size, ep, ) = dex.positions(alice, base);
        assertEq(size, int256(2 * ONE));
        assertEq(ep, 55_000 * ONE);

        uint256 beforeBal = dex.balances(alice);
        makers[0] = Types.Order(alice, bob, base, address(usdt), false, 60_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), true, 60_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, false, 60_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, true, 60_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(60_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        assertEq(dex.balances(alice), beforeBal + 5000 * ONE);

        makers[0] = Types.Order(alice, bob, base, address(usdt), false, 60_000 * ONE, 3 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), true, 60_000 * ONE, 3 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, false, 60_000 * ONE, 3 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, true, 60_000 * ONE, 3 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(60_000 * ONE, 3 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        (size, ep, ) = dex.positions(alice, base);
        assertEq(size, -int256(2 * ONE));
    }

    function test_Funding_Pool_Balance() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        vm.prank(relayer); dex.updateFundingRate(base, int256(1e16));
        vm.warp(block.timestamp + 1000);
        vm.prank(relayer); dex.updateFundingRate(base, int256(1e16));

        uint256 aliceBalBefore = dex.balances(alice);
        uint256 bobBalBefore = dex.balances(bob);
        uint256 poolBefore = dex.fundingPool();

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        assertLt(dex.balances(alice), aliceBalBefore, "Alice should pay funding");
        assertEq(dex.fundingPool(), poolBefore, "Funding pool should balance");
        assertGt(dex.balances(bob), bobBalBefore, "Bob should receive funding");
    }

    function test_Liquidation_UsingMarketPrice() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 4 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 4 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 4 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 4 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 4 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        uint256 price1 = 26_000 * ONE;
        bytes memory sig1 = _signPrice(price1, block.timestamp);
        Types.PriceData memory pd1 = Types.PriceData({price: price1, timestamp: block.timestamp, signature: sig1});
        
        uint256 keeperBalBefore = dex.balances(keeper);
        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd1);
        
        (int256 size1, , ) = dex.positions(alice, base);
        assertLt(size1, int256(4 * ONE), "Should liquidate partially");
        assertGt(size1, int256(0), "Should not be fully liquidated");
        assertGt(dex.balances(keeper), keeperBalBefore, "Keeper should receive reward");

        uint256 price2 = 20_000 * ONE;
        bytes memory sig2 = _signPrice(price2, block.timestamp);
        Types.PriceData memory pd2 = Types.PriceData({price: price2, timestamp: block.timestamp, signature: sig2});
        
        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd2);
        
        (int256 size2, , ) = dex.positions(alice, base);
        assertEq(size2, 0, "Position should be cleared on bankruptcy");
        assertEq(dex.balances(alice), 0, "Balance should be zeroed out");
    }

    function test_Settle_All_Reverts() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = Types.Order(alice, alice, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(alice, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, alice, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(alice, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 1 * ONE);
        vm.prank(relayer); vm.expectRevert("self trade not allowed"); dex.settle(makers, msigs, takers, tsigs, fills);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, true, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        vm.prank(relayer); vm.expectRevert("maker and taker must be opposite sides"); dex.settle(makers, msigs, takers, tsigs, fills);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(50_000 * ONE, 1 * ONE);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);
        vm.prank(relayer); vm.expectRevert("maker order used"); dex.settle(makers, msigs, takers, tsigs, fills);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, 50_000 * ONE, 1 * ONE, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, 50_000 * ONE, 1 * ONE, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, 50_000 * ONE, 1 * ONE, takers[0].nonce, takers[0].expiry, 0);
        vm.warp(block.timestamp + 4000);
        vm.prank(relayer); vm.expectRevert("bad maker sig"); dex.settle(makers, msigs, takers, tsigs, fills);
    }

    function testFuzz_Position_Open_Close(uint96 openPriceRaw, uint96 closePriceRaw, uint96 qtyRaw) public {
        uint256 openPrice = uint256(openPriceRaw) % 50_000 + 1_000;
        uint256 closePrice = uint256(closePriceRaw) % 50_000 + 1_000;
        uint256 qty = (uint256(qtyRaw) % 100 + 1) * ONE / 1000;

        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(1_000_000 * ONE);
        vm.prank(bob);   dex.deposit(1_000_000 * ONE);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = Types.Order(alice, bob, base, address(usdt), true, openPrice * ONE, qty, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, openPrice * ONE, qty, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, true, openPrice * ONE, qty, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, false, openPrice * ONE, qty, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(openPrice * ONE, qty);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        makers[0] = Types.Order(alice, bob, base, address(usdt), false, closePrice * ONE, qty, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(bob, address(0), base, address(usdt), true, closePrice * ONE, qty, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(alice, bob, base, false, closePrice * ONE, qty, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(bob, address(0), base, true, closePrice * ONE, qty, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(closePrice * ONE, qty);
        vm.prank(relayer); dex.settle(makers, msigs, takers, tsigs, fills);

        (int256 size, , ) = dex.positions(alice, base);
        assertEq(size, 0);
    }

    function test_Revert_AccessControl() public {
        address base = makeAddr("base");
        Types.PriceData memory pd = Types.PriceData({
            price: 50_000 * ONE, timestamp: block.timestamp, signature: _signPrice(50_000 * ONE, block.timestamp)
        });

        vm.prank(alice);
        vm.expectRevert("only EK or relayer");
        dex.escapeLiquidate(alice, base, pd);

        vm.prank(alice);
        vm.expectRevert("only relayer");
        dex.updateFundingRate(base, int256(1e16));

        Types.Order[] memory m = new Types.Order[](1);
        bytes[] memory ms = new bytes[](1);
        Types.Order[] memory t = new Types.Order[](1);
        bytes[] memory ts = new bytes[](1);
        Types.Fill[] memory f = new Types.Fill[](1);
        vm.prank(alice);
        vm.expectRevert("only relayer");
        dex.settle(m, ms, t, ts, f);
    }

    function test_Revert_LengthMismatch() public {
        Types.Order[] memory m = new Types.Order[](2);
        bytes[] memory ms = new bytes[](2);
        Types.Order[] memory t = new Types.Order[](1);
        bytes[] memory ts = new bytes[](1);
        Types.Fill[] memory f = new Types.Fill[](2);

        vm.prank(relayer);
        vm.expectRevert();
        dex.settle(m, ms, t, ts, f);
    }

    function test_NegativeFundingRate_NoRevert() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        _openPair(base, alice, bob, true, 50_000 * ONE, 1 * ONE);

        vm.prank(relayer); dex.updateFundingRate(base, -int256(1e16));
        vm.warp(block.timestamp + 1000);
        vm.prank(relayer); dex.updateFundingRate(base, -int256(1e16));

        _openPair(base, alice, bob, true, 50_000 * ONE, 1 * ONE);
    }

    function test_Liquidation_LeavesPositionSafe() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        _openPair(base, alice, bob, true, 50_000 * ONE, 4 * ONE);

        uint256 price1 = 26_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: price1, timestamp: block.timestamp, signature: _signPrice(price1, block.timestamp)
        });
        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd);

        (int256 size,,) = dex.positions(alice, base);
        if (size != 0) {
            dex._isAllSafe(alice, base, price1);
        }
    }

    // ==========================================
    // E. 穿仓 + 保险基金不足（FIX：参数改合理）
    // ==========================================
    function test_Bankruptcy_InsuranceFundInsufficient() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);
        // ===== FIX: 仓位从 1 改成 5（名义 250,000，跌到 10,000 时 equity = -100,000，穿仓）=====
        _openPair(base, alice, bob, true, 50_000 * ONE, 5 * ONE);

        // ===== FIX: 价格从 1,000 改成 10,000（刚好让 equity 负）=====
        uint256 crash = 10_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: crash, timestamp: block.timestamp, signature: _signPrice(crash, block.timestamp)
        });
        uint256 fundBefore = dex.insuranceFund();
        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd);

        (int256 size,,) = dex.positions(alice, base);
        assertEq(size, 0);
        assertEq(dex.balances(alice), 0);
        assertLe(dex.insuranceFund(), fundBefore, "fund drained or unchanged");
    }

    function test_Invariant_TotalLedger() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);
        _openPair(base, alice, bob, true, 50_000 * ONE, 4 * ONE);

        uint256 crash = 25_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: crash, timestamp: block.timestamp, signature: _signPrice(crash, block.timestamp)
        });
        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd);

        uint256 total = dex.balances(alice) + dex.balances(bob)
                      + dex.balances(keeper) + dex.insuranceFund() + dex.fundingPool();
        assertLe(total, 200_000 * ONE + 1, "ledger inflated out of thin air");
    }

    function testFuzz_Deposit_Withdraw(uint96 amount) public {
        uint256 amt = uint256(amount) % (500_000 * ONE) + 1;
        vm.startPrank(alice);
        dex.deposit(amt);
        assertEq(dex.balances(alice), amt);
        dex.withdraw(amt);
        assertEq(dex.balances(alice), 0);
        vm.stopPrank();
    }

    function test_Event_Deposit() public {
        vm.expectEmit(true, false, false, true, address(dex));
        emit FelixPerpDEX.Deposit(alice, 123 * ONE);
        vm.prank(alice); dex.deposit(123 * ONE);
    }

    function _openPair(address base, address a, address b, bool aLong, uint256 price, uint256 qty) internal {
        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);
        makers[0] = Types.Order(a, b, base, address(usdt), aLong, price, qty, nonceCounter++, block.timestamp + 3600, 0);
        takers[0] = Types.Order(b, address(0), base, address(usdt), !aLong, price, qty, nonceCounter++, block.timestamp + 3600, 0);
        msigs[0] = _signOrder(a, b, base, aLong, price, qty, makers[0].nonce, makers[0].expiry, 0);
        tsigs[0] = _signOrder(b, address(0), base, !aLong, price, qty, takers[0].nonce, takers[0].expiry, 0);
        fills[0] = Types.Fill(price, qty);
        vm.prank(relayer);
        dex.settle(makers, msigs, takers, tsigs, fills);
    }

        // ==========================================
    // I. P1-4 验证：清算罚金余额不足时不得凭空造币
    // ==========================================
    function test_LiquidationPenalty_NoPhantomMint() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);
        _openPair(base, alice, bob, true, 50_000 * ONE, 4 * ONE);

        // 让 alice 余额刚好低于 penalty：
        // 先手动把 alice 的余额"借走"大部分，模拟余额不足
        // 用 bob 的平仓操作 + 大额 PnL 让 alice 余额降到很低
        // 更直接：价格暴跌使 alice 大幅亏损后再触发部分清算
        uint256 price1 = 26_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: price1, timestamp: block.timestamp, signature: _signPrice(price1, block.timestamp)
        });

        // 记录清算前总账（含 keeper）
        uint256 totalBefore = dex.balances(alice) + dex.balances(bob)
                            + dex.balances(keeper) + dex.insuranceFund() + dex.fundingPool();

        vm.prank(keeper); dex.escapeLiquidate(alice, base, pd);

        uint256 totalAfter = dex.balances(alice) + dex.balances(bob)
                           + dex.balances(keeper) + dex.insuranceFund() + dex.fundingPool();

        // 总账不能凭空增加
        assertLe(totalAfter, totalBefore, "phantom mint on liquidation penalty");
    }

    // ==========================================
    // J. 多 base 隔离：baseA 清算不影响 baseB
    // ==========================================
    function test_MultiBase_Isolation() public {
        address baseA = makeAddr("baseA");
        address baseB = makeAddr("baseB");

        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        // ===== FIX: baseA 仓位从 1 改成 5（名义 250,000，跌到 25,000 时 equity = -25,000，穿仓）=====
        _openPair(baseA, alice, bob, true, 50_000 * ONE, 5 * ONE);
        // baseB 保持 2 个（不受影响即可）
        _openPair(baseB, alice, bob, true, 50_000 * ONE, 2 * ONE);

        // 验证两个 base 的仓位独立
        (int256 aA,,) = dex.positions(alice, baseA);
        (int256 aB,,) = dex.positions(alice, baseB);
        assertEq(aA, int256(5 * ONE), "baseA position wrong");
        assertEq(aB, int256(2 * ONE), "baseB position wrong");

        // 价格跌到 25,000，触发 baseA 上 alice 的穿仓
        uint256 crash = 25_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: crash, timestamp: block.timestamp, signature: _signPrice(crash, block.timestamp)
        });
        vm.prank(keeper); dex.escapeLiquidate(alice, baseA, pd);

        // 断言：baseA 被清算（仓位清零），baseB 完全不受影响
        (aA,,) = dex.positions(alice, baseA);
        (aB,,) = dex.positions(alice, baseB);
        assertEq(aA, 0, "baseA should be liquidated");
        assertEq(aB, int256(2 * ONE), "baseB should be unaffected");   // ← 关键断言
    }

    // ==========================================
    // K. 撤单：cancelOrder 正确性 + 撤单后 settle 必须失效
    // ==========================================
    function test_Cancel() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        uint256 price = 50_000 * ONE;
        uint256 qty   = 1 * ONE;
        uint256 nM = nonceCounter++;
        uint256 expM = block.timestamp + 3600;
        uint256 nT = nonceCounter++;
        uint256 expT = block.timestamp + 3600;

        Types.Order memory m = Types.Order(alice, bob, base, address(usdt), true, price, qty, nM, expM, 0);
        bytes memory mSig = _signOrder(alice, bob, base, true, price, qty, nM, expM, 0);

        bytes32 h = dex._hashOrder(m);
        assertEq(dex.orderStatus(h), 0, "fresh order should be unused");

        // 1. 非 maker 不能撤（taker 也不行）
        vm.prank(bob);
        vm.expectRevert("only maker can cancel");
        dex.cancelOrder(m);
        assertEq(dex.orderStatus(h), 0, "status must stay 0 after failed cancel");

        // 2. maker 撤单成功：status 置 3，事件发出
        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(dex));
        emit FelixPerpDEX.Cancelled(h, alice);
        dex.cancelOrder(m);
        assertEq(dex.orderStatus(h), 3, "status should be cancelled(3)");

        // 3. 撤单后 settle 必须 revert —— settle 本体没改，靠原本那句 require(status==0) 拦住
        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = m;
        msigs[0]  = mSig;
        takers[0] = Types.Order(bob, address(0), base, address(usdt), false, price, qty, nT, expT, 0);
        tsigs[0]  = _signOrder(bob, address(0), base, false, price, qty, nT, expT, 0);
        fills[0]  = Types.Fill(price, qty);

        vm.prank(relayer);
        vm.expectRevert("maker order used");
        dex.settle(makers, msigs, takers, tsigs, fills);

        // 仓位与余额都没被动过
        (int256 size,,) = dex.positions(alice, base);
        assertEq(size, 0, "cancelled order must not open any position");
        assertEq(dex.balances(alice), 100_000 * ONE, "balance must be untouched");

        // 4. 重复撤单 revert
        vm.prank(alice);
        vm.expectRevert("order used");
        dex.cancelOrder(m);
    }

    // 撤单后换 nonce 重签一张新单，仍可正常撮合
    function test_Cancel_Then_NewOrder_Settles() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        uint256 price = 50_000 * ONE;
        uint256 qty   = 1 * ONE;

        uint256 n0 = nonceCounter++;
        Types.Order memory dead = Types.Order(alice, bob, base, address(usdt), true, price, qty, n0, block.timestamp + 3600, 0);
        vm.prank(alice); dex.cancelOrder(dead);
        assertEq(dex.orderStatus(dex._hashOrder(dead)), 3);

        _openPair(base, alice, bob, true, price, qty);
        (int256 size,,) = dex.positions(alice, base);
        assertEq(size, int256(qty), "new order after cancel should settle normally");
    }

    // 已被撮合(status=2)的订单不能再去撤
    function test_Cancel_AfterFill_Reverts() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);

        uint256 price = 50_000 * ONE;
        uint256 qty   = 1 * ONE;
        uint256 n = nonceCounter;
        uint256 exp = block.timestamp + 3600;

        _openPair(base, alice, bob, true, price, qty);

        // 复原那张已被撮合的 maker 单（_openPair 里 makers[0] 用的就是当时的 nonceCounter）
        Types.Order memory filled = Types.Order(alice, bob, base, address(usdt), true, price, qty, n, exp, 0);
        bytes32 h = dex._hashOrder(filled);
        assertEq(dex.orderStatus(h), 2, "should already be filled(2)");

        vm.prank(alice);
        vm.expectRevert("order used");
        dex.cancelOrder(filled);
    }

    // ============================================================
    //  补充：分支覆盖（本轮新增，全部基于已确认的 require 文本/已知 API）
    //  这些测试只打你源码里明确存在的 revert 分支，不依赖未知常量
    // ============================================================

    // setMarkOracle：仅 owner 可调，且地址非零
    function test_SetMarkOracle_AccessControl() public {
        address newOracle = makeAddr("newOracle");
        // 非 owner -> only owner
        vm.prank(alice);
        vm.expectRevert("only owner");
        dex.setMarkOracle(newOracle);
        // owner 传零地址 -> zero addr
        vm.prank(owner);
        vm.expectRevert("zero addr");
        dex.setMarkOracle(address(0));
        // owner 传有效地址 -> 成功，不 revert
        vm.prank(owner);
        dex.setMarkOracle(newOracle);
    }

    // 有未平仓位时禁止 withdraw -> close positions first
    function test_Withdraw_ClosePositionsFirst() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);
        _openPair(base, alice, bob, true, 50_000 * ONE, 1 * ONE);

        vm.prank(alice);
        vm.expectRevert("close positions first");
        dex.withdraw(1 * ONE);
    }

    // 对无仓位者清算 -> no position
    // markOracle 在 setUp 里刚 new 出来未初始化 -> mkValid=false 跳过偏离检查，直达 size!=0 校验
    function test_Liquidate_NoPosition() public {
        address base = makeAddr("base");
        uint256 price = 50_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: price, timestamp: block.timestamp, signature: _signPrice(price, block.timestamp)
        });
        vm.prank(keeper);
        vm.expectRevert("no position");
        dex.escapeLiquidate(alice, base, pd);
    }

    // 仓位安全时不能清算 -> stillsafe, cannot liquidate
    function test_Liquidate_StillSafe() public {
        address base = makeAddr("base");
        vm.prank(alice); dex.deposit(100_000 * ONE);
        vm.prank(bob);   dex.deposit(100_000 * ONE);
        _openPair(base, alice, bob, true, 50_000 * ONE, 1 * ONE);

        // 平价喂价，equity 远超维持保证金
        uint256 price = 50_000 * ONE;
        Types.PriceData memory pd = Types.PriceData({
            price: price, timestamp: block.timestamp, signature: _signPrice(price, block.timestamp)
        });
        vm.prank(keeper);
        vm.expectRevert("stillsafe, cannot liquidate");
        dex.escapeLiquidate(alice, base, pd);
    }

    // 错误的预言机签名 -> Invalid Oracle Sig
    function test_Liquidate_BadOracleSig() public {
        address base = makeAddr("base");
        uint256 price = 50_000 * ONE;
        // 故意用错误私钥(PK_ALICE)签价，priceSigner 校验失败
        bytes32 inner = keccak256(abi.encodePacked(price, block.timestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_ALICE, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);
        Types.PriceData memory pd = Types.PriceData({
            price: price, timestamp: block.timestamp, signature: badSig
        });
        vm.prank(keeper);
        vm.expectRevert("Invalid Oracle Sig");
        dex.escapeLiquidate(alice, base, pd);
    }

    // 未授权/无余额用户 deposit -> transfer 失败（空 expectRevert，兼容 revert 或返回 false 两种 mock 行为）
    function test_Deposit_TransferFailed() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        dex.deposit(1 * ONE);
    }

}