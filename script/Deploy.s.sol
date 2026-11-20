// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";

contract DeployScript is Script {
    bytes32 public constant DEX_SALT    = bytes32(0);
    bytes32 public constant USDT_SALT   = bytes32(uint256(1));
    bytes32 public constant ORACLE_SALT = bytes32(uint256(2));
    bytes32 public constant MARK_SALT   = bytes32(uint256(3));

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("RELAYER");
        address keeper = vm.envAddress("KEEPER");
        bool isLocal = vm.envOr("IS_LOCAL", false);

        address quoteToken;
        address oracleAddr;
        address markOracleAddr;

        vm.startBroadcast(deployerPk);

        if (isLocal) {
            console.log("=== Local deploy (anvil) ===");

            address signer = vm.envAddress("ORACLE_SIGNER");
            uint256 maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));

            MockERC20 usdt = new MockERC20{salt: USDT_SALT}();
            MockOracle oracle = new MockOracle{salt: ORACLE_SALT}(signer, maxPriceAge);

            MarkPriceOracle markOracle = new MarkPriceOracle{salt: MARK_SALT}();
            console.log("MarkPriceOracle:", address(markOracle));

            quoteToken = address(usdt);
            oracleAddr = address(oracle);
            markOracleAddr = address(markOracle);

            console.log("MockERC20 (quoteToken):", quoteToken);
            console.log("MockOracle:", oracleAddr);
            console.log("  signer:", signer);
            console.log("  maxPriceAge:", maxPriceAge);
        } else {
            console.log("=== Testnet/Mainnet deploy ===");

            quoteToken = vm.envAddress("QUOTE_TOKEN");
            oracleAddr = vm.envAddress("ORACLE");
            markOracleAddr = vm.envAddress("MARK_ORACLE");

            console.log("quoteToken:", quoteToken);
            console.log("oracle:", oracleAddr);
            console.log("markOracle:", markOracleAddr);
        }

        FelixPerpDEX dex = new FelixPerpDEX{salt: DEX_SALT}(
            relayer,
            keeper,
            quoteToken,
            oracleAddr,
            markOracleAddr
        );

        console.log("FelixPerpDEX:", address(dex));

        if (isLocal) {
            _setupLocalAccounts(dex, quoteToken);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deploy Summary ===");
        console.log("FelixPerpDEX:", address(dex));
        console.log("quoteToken:", quoteToken);
        console.log("oracle:", oracleAddr);
        console.log("markOracle:", markOracleAddr);
        console.log("relayer:", relayer);
        console.log("keeper:", keeper);

        if (isLocal) {
            console.log("");
            console.log("=== Next steps ===");
            console.log("1. Copy DEX_ADDR + MARK_ORACLE to .env");
            console.log("2. Run: forge test");
        }
    }

    function _setupLocalAccounts(FelixPerpDEX dex, address usdtAddr) internal {
        MockERC20 usdt = MockERC20(usdtAddr);

        address[5] memory users = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
        ];

        for (uint256 i = 0; i < users.length; i++) {
            usdt.mint(users[i], 1_000_000e18);
        }

        console.log("Minted 1,000,000 USDT to 5 anvil accounts");
    }
}