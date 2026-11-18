// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract DeployScript is Script {
    // ===== 固定 CREATE2 salt，一旦确定就不要再改 =====
    bytes32 public constant DEX_SALT    = bytes32(0);
    // ===== 新增：Mock 也必须用固定 salt =====
    // 否则本地重部署时 Mock 地址随 deployer nonce 漂移 -> DEX 构造参数变
    // -> initcode 变 -> 即使 DEX_SALT 固定，DEX 地址照样变
    bytes32 public constant USDT_SALT   = bytes32(uint256(1));
    bytes32 public constant ORACLE_SALT = bytes32(uint256(2));
    // =================================================

    function run() external {
        // ===== 1. 读环境变量 =====
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("RELAYER");
        address keeper = vm.envAddress("KEEPER");
        bool isLocal = vm.envOr("IS_LOCAL", false);

        address quoteToken;
        address oracleAddr;

        vm.startBroadcast(deployerPk);

        if (isLocal) {
            // ===== 本地 anvil：部署 MockERC20 + MockOracle =====
            console.log("=== Local deploy (anvil) ===");

            address signer = vm.envAddress("ORACLE_SIGNER");
            uint256 maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));

            MockERC20 usdt = new MockERC20{salt: USDT_SALT}();
            MockOracle oracle = new MockOracle{salt: ORACLE_SALT}(signer, maxPriceAge);

            quoteToken = address(usdt);
            oracleAddr = address(oracle);

            console.log("MockERC20 (quoteToken):", quoteToken);
            console.log("MockOracle:", oracleAddr);
            console.log("  signer:", signer);
            console.log("  maxPriceAge:", maxPriceAge);
        } else {
            // ===== 测试网/主网：读真实地址 =====
            console.log("=== Testnet/Mainnet deploy ===");

            quoteToken = vm.envAddress("QUOTE_TOKEN");
            oracleAddr = vm.envAddress("ORACLE");

            console.log("quoteToken:", quoteToken);
            console.log("oracle:", oracleAddr);
        }

        // ===== 2. 用 CREATE2 部署 FelixPerpDEX（固定地址）=====
        FelixPerpDEX dex = new FelixPerpDEX{salt: DEX_SALT}(
            relayer,
            keeper,
            quoteToken,
            oracleAddr
        );

        console.log("FelixPerpDEX:", address(dex));

        // ===== 3. 本地部署：给测试账户 mint =====
        if (isLocal) {
            _setupLocalAccounts(FelixPerpDEX(dex), quoteToken);
        }

        vm.stopBroadcast();

        // ===== 4. 打印部署总结 =====
        console.log("\n=== Deploy Summary ===");
        console.log("FelixPerpDEX:", address(dex));
        console.log("quoteToken:", quoteToken);
        console.log("oracle:", oracleAddr);
        console.log("relayer:", relayer);
        console.log("keeper:", keeper);

        if (isLocal) {
            console.log("\n=== Next steps ===");
            console.log("1. Copy DEX_ADDR to .env in both contracts/ and engine/");
            console.log("2. Run tests: forge test");
            console.log("3. Interact: cast call <dex> 'balances(address)' <user> --rpc-url http://localhost:8545");
        }
    }

    /// @notice 本地部署后，给 anvil 默认账户 mint 测试 USDT
    function _setupLocalAccounts(FelixPerpDEX dex, address usdtAddr) internal {
        MockERC20 usdt = MockERC20(usdtAddr);

        // anvil 默认前 5 个账户
        address[5] memory users = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,  // 0
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,  // 1
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,  // 2
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,  // 3
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   // 4
        ];

        for (uint256 i = 0; i < users.length; i++) {
            usdt.mint(users[i], 1_000_000e18);
        }

        console.log("Minted 1,000,000 USDT to 5 anvil accounts");
        console.log("Users need to call usdt.approve(dex, max) manually");
    }
}