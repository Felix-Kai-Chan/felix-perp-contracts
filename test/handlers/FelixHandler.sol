// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FelixPerpDEX} from "../../src/FelixDealer.sol";
import {Types} from "../../src/Types.sol";
import {MockERC20} from "../../src/MockERC20.sol";

contract FelixHandler is Test {
    FelixPerpDEX public dex;
    MockERC20 public usdt;

    address public relayer;
    address public keeper;
    address public baseA;
    address public baseB;
    address public alice;
    address public bob;

    uint256 internal pkAlice;
    uint256 internal pkBob;
    uint256 internal pkKeeper;
    uint256 internal pkPriceSigner;

    uint256 public nonceCounter;
    uint256 internal pkSigner;

    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address baseToken,address quoteToken,bool isLong,uint256 price,uint256 qty,uint256 nonce,uint256 expiry,uint256 feeRate)"
    );

    constructor(
        FelixPerpDEX _dex,
        MockERC20 _usdt,
        address _relayer,
        address _keeper,
        address _baseA,
        address _baseB,
        address _alice,
        address _bob,
        uint256 _pkAlice,
        uint256 _pkBob,
        uint256 _pkKeeper,
        uint256 _pkPriceSigner
    ) {
        dex = _dex;
        usdt = _usdt;
        relayer = _relayer;
        keeper = _keeper;
        baseA = _baseA;
        baseB = _baseB;
        alice = _alice;
        bob = _bob;
        pkAlice = _pkAlice;
        pkBob = _pkBob;
        pkKeeper = _pkKeeper;
        pkSigner = _pkPriceSigner;
        nonceCounter = 1;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000e18);
        address u = _pickUser();
        vm.startPrank(u);
        usdt.approve(address(dex), amount);
        dex.deposit(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 amount, bool useBaseA) external {
        address u = _pickUser();
        address b = useBaseA ? baseA : baseB;

        // 该 user 在 b 上有仓位则跳过（源码已禁止提款）
        (int256 size,,) = dex.positions(u, b);
        if (size != 0) return;

        // 检查该 user 是否在其他 base 上也有仓位，有就跳过
        address other = useBaseA ? baseB : baseA;
        (int256 otherSize,,) = dex.positions(u, other);
        if (otherSize != 0) return;

        uint256 bal = dex.balances(u);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(u);
        dex.withdraw(amount);
    }

    function trade(uint256 qty, bool aliceLong, bool useBaseA) external {
        qty = bound(qty, 1e18, 5e18);
        uint256 price = 50_000e18;
        address b = useBaseA ? baseA : baseB;

        address mk = aliceLong ? alice : bob;
        address tk = aliceLong ? bob : alice;

        Types.Order memory m = Types.Order({
            maker: mk,
            taker: tk,
            baseToken: b,
            quoteToken: address(usdt),
            isLong: aliceLong,
            price: price,
            qty: qty,
            nonce: nonceCounter++,
            expiry: block.timestamp + 3600,
            feeRate: 0
        });
        Types.Order memory t = Types.Order({
            maker: tk,
            taker: address(0),
            baseToken: b,
            quoteToken: address(usdt),
            isLong: !aliceLong,
            price: price,
            qty: qty,
            nonce: nonceCounter++,
            expiry: block.timestamp + 3600,
            feeRate: 0
        });

        bytes memory msig = _signOrder(m, mk == alice ? pkAlice : pkBob);
        bytes memory tsig = _signOrder(t, tk == alice ? pkAlice : pkBob);

        Types.Order[] memory makers = new Types.Order[](1);
        Types.Order[] memory takers = new Types.Order[](1);
        bytes[] memory msigs = new bytes[](1);
        bytes[] memory tsigs = new bytes[](1);
        Types.Fill[] memory fills = new Types.Fill[](1);

        makers[0] = m;
        takers[0] = t;
        msigs[0] = msig;
        tsigs[0] = tsig;
        fills[0] = Types.Fill(price, qty);

        vm.prank(relayer);
        try dex.settle(makers, msigs, takers, tsigs, fills) {
        } catch {
        }
    }

    function liquidate(uint256 newPriceRaw, bool useBaseA) external {
        address b = useBaseA ? baseA : baseB;
        (int256 size,,) = dex.positions(alice, b);
        if (size == 0) return;

        uint256 newPrice = bound(newPriceRaw, 1_000e18, 100_000e18);
        bytes memory sig = _signPrice(newPrice, block.timestamp);
        Types.PriceData memory pd = Types.PriceData({
            price: newPrice,
            timestamp: block.timestamp,
            signature: sig
        });

        vm.prank(keeper);
        try dex.escapeLiquidate(alice, b, pd) {
        } catch {
        }
    }

    function updateFunding(int256 ratePerSec, bool useBaseA) external {
        address b = useBaseA ? baseA : baseB;
        int256 r = bound(ratePerSec, -1e16, 1e16);
        vm.prank(relayer);
        dex.updateFundingRate(b, r);
    }

    function _pickUser() internal view returns (address) {
        return uint256(keccak256(abi.encode(block.timestamp, gasleft()))) % 2 == 0 ? alice : bob;
    }

    function _signOrder(Types.Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.maker, o.taker, o.baseToken, o.quoteToken,
            o.isLong, o.price, o.qty, o.nonce, o.expiry, o.feeRate
        ));
        bytes32 domainSep = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("FelixPerpDEX"),
            keccak256("1"),
            block.chainid,
            address(dex)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPrice(uint256 price, uint256 ts) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encodePacked(price, ts));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkSigner, digest);
        return abi.encodePacked(r, s, v);
    }
}