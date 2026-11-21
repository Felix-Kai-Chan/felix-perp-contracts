// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {Types} from "../src/Types.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";
import {FelixHandler} from "./handlers/FelixHandler.sol";

contract LedgerInvariantTest is Test {
    FelixPerpDEX dex;
    MockOracle oracle;
    MockERC20 usdt;
    MarkPriceOracle markOracle;
    FelixHandler handler;

    uint256 constant PK_RELAYER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK_KEEPER  = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK_ALICE   = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant PK_BOB     = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant PK_SIGNER  = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;

    address owner;
    address relayer;
    address keeper;
    address signer;
    address alice;
    address bob;
    address baseA;
    address baseB;

    address[] users;

    function setUp() public {
        owner   = makeAddr("owner");
        relayer = vm.addr(PK_RELAYER);
        keeper  = vm.addr(PK_KEEPER);
        signer  = vm.addr(PK_SIGNER);
        alice   = vm.addr(PK_ALICE);
        bob     = vm.addr(PK_BOB);
        baseA   = makeAddr("baseA");
        baseB   = makeAddr("baseB");

        vm.startPrank(owner);
        usdt   = new MockERC20();
        oracle = new MockOracle(signer, 3600);
        markOracle = new MarkPriceOracle();
        dex    = new FelixPerpDEX(relayer, keeper, address(usdt), address(oracle), address(markOracle));
        vm.stopPrank();

        users.push(alice);
        users.push(bob);
        users.push(keeper);

        for (uint256 i = 0; i < users.length; i++) {
            usdt.mint(users[i], 1_000_000e18);
            vm.prank(users[i]);
            usdt.approve(address(dex), type(uint256).max);
        }

        vm.prank(alice); dex.deposit(100_000e18);
        vm.prank(bob);   dex.deposit(100_000e18);

        handler = new FelixHandler(
            dex, usdt, relayer, keeper, baseA, baseB, alice, bob,
            PK_ALICE, PK_BOB, PK_KEEPER, PK_SIGNER
        );
        targetContract(address(handler));

        bytes4[] memory sels = new bytes4[](4);
        sels[0] = FelixHandler.deposit.selector;
        sels[1] = FelixHandler.withdraw.selector;
        sels[2] = FelixHandler.trade.selector;
        sels[3] = FelixHandler.liquidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_LedgerConserved() public view {
        uint256 sum = dex.insuranceFund() + dex.fundingPool();
        for (uint256 i = 0; i < users.length; i++) {
            sum += dex.balances(users[i]);
        }
        assertLe(sum, usdt.balanceOf(address(dex)) + 1, "ledger inflated out of thin air");
    }

    function invariant_ContractSolvent() public view {
        assertGe(
            usdt.balanceOf(address(dex)),
            dex.insuranceFund() + dex.fundingPool(),
            "contract insolvent vs pools"
        );
    }
}