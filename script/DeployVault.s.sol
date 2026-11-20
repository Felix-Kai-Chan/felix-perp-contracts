// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PerpetualVault} from "../src/PerpetualVault.sol";

contract DeployVault is Script {
    function run() public {
        uint256 pk = vm.envUint("RELAYER_PK");
        vm.startBroadcast(pk);
        PerpetualVault vault = new PerpetualVault();
        vm.stopBroadcast();
        console.log("chainId:", block.chainid);
        console.log("PerpetualVault deployed at:", address(vault));
        console.log("operator:", vault.operator());
    }
}