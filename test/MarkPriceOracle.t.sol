// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";

contract MarkPriceOracleTest is Test {
    MarkPriceOracle o;
    address owner;
    address operator;
    address alice;

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        vm.prank(owner);
        o = new MarkPriceOracle();
        vm.prank(owner);
        o.setOperator(operator);
    }

    // ---- update: 正向 premium，EMA 收敛，band = ±0.5% ----
    function test_Update_PositivePremium() public {
        vm.prank(operator);
        o.update(100_000e8, 100_500e8); // last > index → premium 正
        (uint256 mark, bool valid) = o.getMarkPriceSafe();
        assertTrue(valid);
        assertGt(mark, 100_000e8); // 正 premium → mark 高于 index
        uint256 band = mark * 50 / 10000;
        assertEq(o.getMarkMax(), mark + band);
        assertEq(o.getMarkMin(), mark - band);
    }

    // ---- update: 负向 premium ----
    function test_Update_NegativePremium() public {
        vm.prank(operator);
        o.update(100_000e8, 99_500e8);
        uint256 mark = o.getMarkPrice();
        assertLt(mark, 100_000e8);
    }

    // ---- update: markInt<=0 兜底分支（mark 退化为 index/10）----
    function test_Update_MarkFloorGuard() public {
        // last 远小于 index，多次 update 把 EMA 拉成巨大负数，使 index+ema<=0
        // 直接构造：第一次把 EMA 拉负，第二次 index 很小触发兜底
        vm.prank(operator);
        o.update(1_000_000e8, 1);          // premium 巨负
        vm.prank(operator);
        o.update(1_000e8, 1);              // index 很小 + 负 EMA → markInt<=0
        uint256 mark = o.getMarkPrice();
        // 兜底：markInt<=0 时 mark = index/10
        assertGt(mark, 0);
    }

    // ---- update: 极小值走 _min = 1 分支 ----
    function test_Update_MinFloorOne() public {
        vm.prank(operator);
        o.update(150, 150); // mark=150, band=150*50/10000=0 → _min = _mark-0
        // band==0 时 _min = _mark (因为 band<_mark 成立 0<150)
        assertEq(o.getMarkMin(), o.getMarkPrice());
    }

    // ---- require: zero index / zero last ----
    function test_Update_RevertZero() public {
        vm.prank(operator);
        vm.expectRevert(bytes("zero index"));
        o.update(0, 100);
        vm.prank(operator);
        vm.expectRevert(bytes("zero last"));
        o.update(100, 0);
    }

    // ---- require: onlyOperator ----
    function test_Update_RevertNotOperator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        o.update(100_000e8, 100_000e8);
    }

    // ---- getMarkPrice* 未初始化 revert ----
    function test_View_RevertNotInit() public {
        vm.expectRevert(bytes("not init"));
        o.getMarkPrice();
        vm.expectRevert(bytes("not init"));
        o.getMarkMax();
        vm.expectRevert(bytes("not init"));
        o.getMarkMin();
    }

    // ---- getMarkPrice 过期 revert ----
    function test_View_RevertStale() public {
        vm.prank(operator);
        o.update(100_000e8, 100_000e8);
        vm.warp(block.timestamp + o.maxAge() + 1);
        vm.expectRevert(bytes("stale"));
        o.getMarkPrice();
    }

    // ---- getMarkPriceSafe: 三态 (0,false) / (mark,false) / (mark,true) ----
    function test_Safe_ThreeStates() public {
        (uint256 p0, bool v0) = o.getMarkPriceSafe();
        assertEq(p0, 0); assertFalse(v0);          // 未初始化

        vm.prank(operator);
        o.update(100_000e8, 100_000e8);
        (, bool v1) = o.getMarkPriceSafe();
        assertTrue(v1);                             // 有效

        vm.warp(block.timestamp + o.maxAge() + 1);
        (uint256 p2, bool v2) = o.getMarkPriceSafe();
        assertGt(p2, 0); assertFalse(v2);           // 过期但返回旧值
    }

    // ---- setMaxAge 边界 ----
    function test_SetMaxAge_Bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("range")); o.setMaxAge(0);
        vm.expectRevert(bytes("range")); o.setMaxAge(601);
        o.setMaxAge(600);
        assertEq(o.maxAge(), 600);
        vm.stopPrank();
    }

    // ---- 权限 ----
    function test_AccessControl() public {
        vm.prank(alice); vm.expectRevert(bytes("not owner")); o.setOperator(alice);
        vm.prank(alice); vm.expectRevert(bytes("not owner")); o.setMaxAge(100);
        vm.prank(alice); vm.expectRevert(bytes("not owner")); o.transferOwnership(alice);
        vm.prank(owner); vm.expectRevert(bytes("zero")); o.setOperator(address(0));
        vm.prank(owner); vm.expectRevert(bytes("zero")); o.transferOwnership(address(0));
    }
}