// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";

/// @notice 恶意 ERC20：transfer 时回调 dex.withdraw，试图重入
contract MaliciousToken is ERC20 {
    FelixPerpDEX public dex;
    bool public attacking;
    bool public attackAttempted;

    constructor() ERC20("Malicious USDT", "mUSDT") {}

    function setDex(address _dex) external {
        dex = FelixPerpDEX(_dex);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!attacking && address(dex) != address(0)) {
            attacking = true;
            attackAttempted = true;
            // 重入 withdraw：在余额扣减前再次提款
            // 如果合约有重入漏洞，balances 会被扣两次
            try dex.withdraw(amount) {
                // 重入成功 = 有漏洞
            } catch {
                // 重入失败 = 安全
            }
            attacking = false;
        }
        return super.transfer(to, amount);
    }
}

contract ReentrancyTest is Test {
    FelixPerpDEX dex;
    MockOracle oracle;
    MaliciousToken malToken;
    MarkPriceOracle markOracle;

    uint256 constant PK_RELAYER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK_KEEPER  = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK_ALICE   = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant PK_SIGNER  = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;

    address owner;
    address relayer;
    address keeper;
    address signer;
    address alice;

    function setUp() public {
        owner   = makeAddr("owner");
        relayer = vm.addr(PK_RELAYER);
        keeper  = vm.addr(PK_KEEPER);
        signer  = vm.addr(PK_SIGNER);
        alice   = vm.addr(PK_ALICE);

        vm.startPrank(owner);
        malToken = new MaliciousToken();
        oracle   = new MockOracle(signer, 3600);
        markOracle = new MarkPriceOracle();
        dex      = new FelixPerpDEX(relayer, keeper, address(malToken), address(oracle), address(markOracle));
        malToken.setDex(address(dex));
        vm.stopPrank();

        malToken.mint(alice, 1_000_000e18);
        vm.prank(alice);
        malToken.approve(address(dex), type(uint256).max);
    }

    function test_Reentrancy_WithdrawBlocked() public {
        // alice 存入 1000
        vm.prank(alice);
        dex.deposit(1_000e18);
        assertEq(dex.balances(alice), 1_000e18);

        // alice 提款 400
        // 如果 withdraw 有重入漏洞，恶意 token 的 transfer 会回调 withdraw(400)
        // 导致 balances 被扣两次 → balances 变成 200（错误）
        vm.prank(alice);
        dex.withdraw(400e18);

        // CEI 模式下，先扣余额再转账，重入时余额已扣 → 二次 withdraw 会因余额不足 revert
        // 所以最终 balances 应该是 600，不是 200
        assertEq(dex.balances(alice), 600e18, "reentrancy should not double-deduct");

        // 恶意 token 的 transfer 被调用时，重入确实被触发了
        // 但因为 CEI，重入的 withdraw 因余额不足而 revert
        assertTrue(malToken.attackAttempted(), "attack should have been attempted");
    }
}