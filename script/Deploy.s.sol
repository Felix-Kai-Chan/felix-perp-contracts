// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FelixPerpDEX} from "../src/FelixDealer.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MarkPriceOracle} from "../src/MarkPriceOracle.sol";

contract DeployScript is Script {
    bytes32 internal constant DEX_SALT    = bytes32(uint256(0xa11ce));
    bytes32 internal constant USDT_SALT   = bytes32(uint256(0xa11ce1));
    bytes32 internal constant ORACLE_SALT = bytes32(uint256(0xa11ce2));
    bytes32 internal constant MARK_SALT   = bytes32(uint256(0xa11ce3));

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address relayer = vm.envAddress("RELAYER");
        address keeper = vm.envAddress("KEEPER");
        bool isLocal = _readBool("IS_LOCAL", false);

        uint256 chainId = block.chainid;
        console.logString(string.concat("Chain ID: ", vm.toString(chainId)));
        console.logString(string.concat("Deployer: ", vm.toString(deployer)));
        console.logString(string.concat("Deployer ETH balance: ", vm.toString(deployer.balance)));

        require(relayer != address(0), "RELAYER is zero");
        require(keeper != address(0), "KEEPER is zero");

        // 方案A：预言机签名者（独立私钥对应的地址，Sepolia/本地都要）
        address oracleSigner = vm.envAddress("ORACLE_SIGNER");
        require(oracleSigner != address(0), "ORACLE_SIGNER is zero");
        uint256 maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));

        // QUOTE_TOKEN: 填了用现成合约；没填(zero/未设)则自动部署 MockERC20
        address quoteInput = vm.envOr("QUOTE_TOKEN", address(0));

        address quoteToken;
        address oracleAddr;
        address markOracleAddr;

        vm.startBroadcast(deployerPk);

        // 无论本地还是 Sepolia，预言机都自部署（方案A）
        MockOracle oracle = new MockOracle{salt: _salt(ORACLE_SALT, isLocal, chainId, deployer)}(oracleSigner, maxPriceAge);
        oracleAddr = address(oracle);

        MarkPriceOracle markOracle = new MarkPriceOracle{salt: _salt(MARK_SALT, isLocal, chainId, deployer)}();
        markOracleAddr = address(markOracle);

        if (quoteInput == address(0)) {
            MockERC20 usdt = new MockERC20{salt: _salt(USDT_SALT, isLocal, chainId, deployer)}();
            quoteToken = address(usdt);
            console.logString(string.concat("MockERC20 (self-deployed): ", vm.toString(quoteToken)));
        } else {
            quoteToken = quoteInput;
            console.logString(string.concat("quoteToken (external): ", vm.toString(quoteToken)));
        }

        console.logString(string.concat("MockOracle: ", vm.toString(oracleAddr)));
        console.logString(string.concat("MarkPriceOracle: ", vm.toString(markOracleAddr)));

        FelixPerpDEX dex = new FelixPerpDEX{salt: _salt(DEX_SALT, isLocal, chainId, deployer)}(
            relayer,
            keeper,
            quoteToken,
            oracleAddr,
            markOracleAddr
        );

        vm.stopBroadcast();

        console.logString("");
        console.logString("=== Deploy Summary ===");
        console.logString(string.concat("FelixPerpDEX: ", vm.toString(address(dex))));
        console.logString(string.concat("quoteToken: ", vm.toString(quoteToken)));
        console.logString(string.concat("oracle: ", vm.toString(oracleAddr)));
        console.logString(string.concat("markOracle: ", vm.toString(markOracleAddr)));
        console.logString(string.concat("oracleSigner: ", vm.toString(oracleSigner)));
        console.logString(string.concat("relayer: ", vm.toString(relayer)));
        console.logString(string.concat("keeper: ", vm.toString(keeper)));

        // 本地给 5 个 anvil 账户打钱（仅本地；Sepolia 上 quoteToken 多半不是可 mint 的 MockERC20）
        if (isLocal && quoteInput == address(0)) {
            MockERC20 usdt = MockERC20(quoteToken);
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
            console.logString("Minted 1,000,000 USDT to 5 anvil accounts");
        }

        if (!isLocal) {
            console.logString("");
            console.logString(string.concat(
                "Verify: forge verify-contract ", vm.toString(address(dex)),
                " --chain ", vm.toString(chainId), " src/FelixDealer.sol:FelixPerpDEX"
            ));
        }
    }

    // 本地用固定 salt；测试网/主网用 (chainId, deployer, base) 派生唯一 salt，避免 CREATE2 冲突
    function _salt(bytes32 base, bool isLocal, uint256 chainId, address deployer) internal pure returns (bytes32) {
        if (isLocal) return base;
        return keccak256(abi.encodePacked("felix-perp", chainId, deployer, base));
    }

    function _readBool(string memory key, bool defaultVal) internal view returns (bool) {
        try vm.envString(key) returns (string memory val) {
            bytes memory b = bytes(val);
            if (b.length == 0) return defaultVal;
            if (keccak256(b) == keccak256("true") || keccak256(b) == keccak256("1") || keccak256(b) == keccak256("yes")) {
                return true;
            }
            if (keccak256(b) == keccak256("false") || keccak256(b) == keccak256("0") || keccak256(b) == keccak256("no")) {
                return false;
            }
            revert("IS_LOCAL must be true/false");
        } catch {
            return defaultVal;
        }
    }
}